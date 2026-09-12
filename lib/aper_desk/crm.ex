defmodule AperDesk.Crm do
  @moduledoc """
  Contacts, leads and the pipeline they move along.

  Every write that changes a lead's meaning — created, moved, won, lost —
  commits its domain event in the same transaction as the change itself. See
  `AperDesk.Events` for why that is the whole design rather than a detail.

  Creating a lead is guarded by the plan's active-lead cap, and that check
  takes a row lock inside the same transaction as the insert, so two requests
  cannot both slip past a full quota.
  """

  import Ecto.Query

  alias AperDesk.Authorization
  alias AperDesk.Billing.Limits
  alias AperDesk.Crm.{Contact, CustomFieldDefinition, Lead, Tag, Tagging}
  alias AperDesk.Events
  alias AperDesk.Repo
  alias AperDesk.Scope
  alias AperDesk.Scoped
  alias AperDesk.Visibility
  alias Ecto.Multi

  ## Contacts

  def list_contacts(%Scope{} = scope, opts \\ []) do
    with :ok <- Authorization.authorize(scope, :"contact.read") do
      {:ok,
       Contact
       |> Scoped.for_studio(scope)
       |> filter_archived(Keyword.get(opts, :include_archived, false))
       |> search_contacts(opts[:query])
       |> order_by([c], asc: c.name)
       |> Scoped.paginate(opts)
       |> Repo.all()}
    end
  end

  def fetch_contact(%Scope{} = scope, id) do
    with :ok <- Authorization.authorize(scope, :"contact.read") do
      Scoped.fetch(Contact, scope, id)
    end
  end

  def create_contact(%Scope{} = scope, attrs) do
    with :ok <- Authorization.authorize(scope, :"contact.write") do
      %Contact{}
      |> Contact.changeset(Scoped.put_studio(attrs, scope))
      |> Repo.insert()
    end
  end

  def update_contact(%Scope{} = scope, id, attrs) do
    with :ok <- Authorization.authorize(scope, :"contact.write"),
         {:ok, contact} <- Scoped.fetch(Contact, scope, id) do
      contact |> Contact.changeset(attrs) |> Repo.update()
    end
  end

  @doc """
  Archive a contact.

  Never deleted: a contact is referenced by every lead, job and invoice they
  appear on, and removing the row would turn all of that history into a blank.
  """
  def archive_contact(%Scope{} = scope, id) do
    with :ok <- Authorization.authorize(scope, :"contact.write"),
         {:ok, contact} <- Scoped.fetch(Contact, scope, id) do
      contact |> Ecto.Changeset.change(archived_at: DateTime.utc_now()) |> Repo.update()
    end
  end

  def restore_contact(%Scope{} = scope, id) do
    with :ok <- Authorization.authorize(scope, :"contact.write"),
         {:ok, contact} <- Scoped.fetch(Contact, scope, id) do
      contact |> Ecto.Changeset.change(archived_at: nil) |> Repo.update()
    end
  end

  @doc "A blank or populated changeset, for rendering a contact form."
  def change_contact(contact \\ %Contact{}, attrs \\ %{}),
    do: Contact.changeset(contact, attrs)

  @doc "A blank or populated changeset, for rendering a lead form."
  def change_lead(lead \\ %Lead{}, attrs \\ %{}), do: Lead.changeset(lead, attrs)

  @doc "Everything shown on one lead's page, loaded together."
  def fetch_lead_detail(%Scope{} = scope, id) do
    with :ok <- Authorization.authorize(scope, :"lead.read"),
         {:ok, lead} <- Scoped.fetch(Lead, scope, id) do
      {:ok, Repo.preload(lead, [:contact, :owner])}
    end
  end

  @doc """
  Find an existing contact by email or create one.

  Used by the inbound-capture pipeline and the public form, where the same
  person enquiring twice must not become two contacts. Relies on the
  `(studio_id, email)` unique index rather than a read-then-write, so two
  simultaneous enquiries from one address resolve to a single row.
  """
  def upsert_contact(%Scope{} = scope, attrs) do
    with :ok <- authorize_or_system(scope, :"contact.write") do
      attrs = Scoped.put_studio(attrs, scope)
      email = attrs["email"] && String.downcase(String.trim(attrs["email"]))

      case email && Repo.get_by(Contact, studio_id: Scope.studio_id(scope), email: email) do
        %Contact{} = contact ->
          {:ok, contact}

        _ ->
          case %Contact{} |> Contact.changeset(attrs) |> Repo.insert() do
            {:ok, contact} ->
              {:ok, contact}

            {:error, changeset} ->
              # Lost the race: someone else inserted the same address between our
              # lookup and our insert. Their row is as good as ours.
              if email && unique_violation?(changeset, :email) do
                {:ok, Repo.get_by!(Contact, studio_id: Scope.studio_id(scope), email: email)}
              else
                {:error, changeset}
              end
          end
      end
    end
  end

  ## Leads

  def list_leads(%Scope{} = scope, opts \\ []) do
    with :ok <- Authorization.authorize(scope, :"lead.read") do
      {:ok,
       Lead
       |> Scoped.for_studio(scope)
       |> Visibility.leads(scope)
       |> filter_leads(opts)
       |> preload([:contact, :owner])
       |> order_by([l], desc: l.inserted_at)
       |> Scoped.paginate(opts)
       |> Repo.all()}
    end
  end

  def fetch_lead(%Scope{} = scope, id) do
    with :ok <- Authorization.authorize(scope, :"lead.read"),
         {:ok, lead} <- Scoped.fetch(Lead, scope, id) do
      # Refused rather than reported missing. Both end the request, but a
      # photographer looking at a colleague's lead id should be told it is not
      # theirs, not that the studio has no such lead.
      if Visibility.visible?(scope, lead), do: {:ok, lead}, else: {:error, :unauthorized}
    end
  end

  @doc """
  Create a lead.

  The plan check, the insert and the event all share one transaction. If the
  studio is at its cap nothing is written; if the insert fails the event is
  rolled back with it, so automation can never fire for a lead that does not
  exist.
  """
  def create_lead(%Scope{} = scope, attrs) do
    with :ok <- authorize_or_system(scope, :"lead.write") do
      attrs = attrs |> Scoped.put_studio(scope) |> put_response_due(scope)

      Multi.new()
      |> Multi.run(:limit, fn repo, _ ->
        case Limits.ensure_headroom(repo, scope, "active_leads") do
          :ok -> {:ok, :within_limit}
          error -> error
        end
      end)
      |> Multi.run(:custom_fields, fn repo, _ -> validate_custom_fields(repo, scope, attrs) end)
      |> Multi.insert(:lead, fn %{custom_fields: custom_fields} ->
        Lead.changeset(%Lead{}, Map.put(attrs, "custom_fields", custom_fields))
      end)
      |> Events.record(:lead, "lead.created", "Lead created", scope)
      |> Repo.transaction()
      |> unwrap(:lead)
    end
  end

  def update_lead(%Scope{} = scope, id, attrs) do
    with :ok <- Authorization.authorize(scope, :"lead.write"),
         {:ok, lead} <- Scoped.fetch(Lead, scope, id) do
      lead |> Lead.changeset(attrs) |> Repo.update()
    end
  end

  @doc """
  Move a lead along the pipeline.

  The stage change and its event commit together, and the event name is
  specific (`lead.won`, `lead.lost`) so a workflow can trigger on winning
  without also firing on every other move.
  """
  def move_lead(%Scope{} = scope, id, stage, attrs \\ %{}) do
    with :ok <- Authorization.authorize(scope, :"lead.write"),
         {:ok, lead} <- Scoped.fetch(Lead, scope, id) do
      Multi.new()
      |> Multi.update(:lead, Lead.stage_changeset(lead, stage, attrs))
      |> Events.record(
        :lead,
        stage_event(stage),
        "Lead moved to #{String.replace(stage, "_", " ")}",
        scope,
        payload: %{"from" => lead.stage, "to" => stage}
      )
      |> Repo.transaction()
      |> unwrap(:lead)
    end
  end

  @doc """
  Record that a human replied, which stops the SLA clock.

  Idempotent on `first_responded_at` — replying twice must not reset the
  measured first-response time, or the dashboard would flatter the studio.
  """
  def record_reply(%Scope{} = scope, id, at \\ DateTime.utc_now()) do
    with :ok <- Authorization.authorize(scope, :"lead.write") do
      with {:ok, lead} <- Scoped.fetch(Lead, scope, id) do
        lead |> Lead.responded_changeset(at) |> Repo.update()
      end
    end
  end

  @doc "Leads whose reply window has passed with nobody having answered."
  def overdue_leads(%Scope{} = scope, now \\ DateTime.utc_now()) do
    with :ok <- Authorization.authorize(scope, :"lead.read") do
      Lead
      |> Scoped.for_studio(scope)
      |> Visibility.leads(scope)
      |> where([l], is_nil(l.first_responded_at) and l.first_response_due_at < ^now)
      |> where([l], is_nil(l.archived_at) and l.stage not in ^["completed", "lost"])
      |> order_by([l], asc: l.first_response_due_at)
      |> preload([:contact, :owner])
      |> Repo.all()
    end
  end

  @doc "Counts per stage, for the pipeline board headers. One query, not seven."
  def pipeline_summary(%Scope{} = scope) do
    with :ok <- Authorization.authorize(scope, :"lead.read") do
      Lead
      |> Scoped.for_studio(scope)
      |> Visibility.leads(scope)
      |> where([l], is_nil(l.archived_at))
      |> group_by([l], l.stage)
      |> select([l], {l.stage, count(l.id)})
      |> Repo.all()
      |> Map.new()
    end
  end

  # A studio-only scope — no user, no role — is how the system paths identify
  # themselves: a public form submission and an inbound email have a tenant but
  # nobody acting. Those are authorised by reaching them at all (a valid form
  # slug, a connected mailbox), so a permission check would only ever refuse
  # them. A scope with a user in it is a person, and is checked normally.
  defp authorize_or_system(%Scope{user: nil, studio: %{}}, _permission), do: :ok

  defp authorize_or_system(%Scope{} = scope, permission),
    do: Authorization.authorize(scope, permission)

  ## Tags

  def list_tags(%Scope{} = scope) do
    with :ok <- Authorization.authorize(scope, :"lead.read") do
      Tag |> Scoped.for_studio(scope) |> order_by([t], asc: t.name) |> Repo.all()
    end
  end

  def create_tag(%Scope{} = scope, attrs) do
    with :ok <- Authorization.authorize(scope, :"lead.write") do
      %Tag{} |> Tag.changeset(Scoped.put_studio(attrs, scope)) |> Repo.insert()
    end
  end

  @doc "Apply a tag. Re-applying is a no-op rather than an error."
  def tag(%Scope{} = scope, tag_id, subject) do
    with :ok <- Authorization.authorize(scope, :"lead.write"),
         {:ok, _tag} <- Scoped.fetch(Tag, scope, tag_id) do
      %Tagging{}
      |> Tagging.changeset(%{
        tag_id: tag_id,
        taggable_type: Tagging.type_for(subject),
        taggable_id: subject.id
      })
      |> Repo.insert()
      |> case do
        {:ok, tagging} -> {:ok, tagging}
        {:error, changeset} -> if already_tagged?(changeset), do: :ok, else: {:error, changeset}
      end
    end
  end

  def untag(%Scope{} = scope, tag_id, subject) do
    with :ok <- Authorization.authorize(scope, :"lead.write") do
      Repo.delete_all(
        from t in Tagging,
          where:
            t.tag_id == ^tag_id and t.taggable_type == ^Tagging.type_for(subject) and
              t.taggable_id == ^subject.id
      )

      :ok
    end
  end

  def tags_for(%Scope{} = scope, subject) do
    with :ok <- Authorization.authorize(scope, :"lead.read") do
      Repo.all(
        from t in Tag,
          join: g in Tagging,
          on: g.tag_id == t.id,
          where:
            t.studio_id == ^Scope.studio_id(scope) and
              g.taggable_type == ^Tagging.type_for(subject) and g.taggable_id == ^subject.id,
          order_by: t.name
      )
    end
  end

  ## Custom fields

  def list_custom_fields(%Scope{} = scope, entity \\ "lead") do
    with :ok <- Authorization.authorize(scope, :"lead.read") do
      CustomFieldDefinition
      |> Scoped.for_studio(scope)
      |> where([d], d.entity == ^entity)
      |> order_by([d], asc: d.position, asc: d.key)
      |> Repo.all()
    end
  end

  def create_custom_field(%Scope{} = scope, attrs) do
    with :ok <- Authorization.authorize(scope, :"lead.write") do
      %CustomFieldDefinition{}
      |> CustomFieldDefinition.changeset(Scoped.put_studio(attrs, scope))
      |> Repo.insert()
    end
  end

  ## Internals

  defp validate_custom_fields(repo, scope, attrs) do
    case Map.get(attrs, "custom_fields") do
      nil ->
        {:ok, %{}}

      values when is_map(values) ->
        definitions =
          repo.all(
            from d in CustomFieldDefinition,
              where: d.studio_id == ^Scope.studio_id(scope) and d.entity == "lead"
          )

        case CustomFieldDefinition.validate(definitions, values) do
          {:ok, coerced} -> {:ok, coerced}
          {:error, errors} -> {:error, {:invalid_custom_fields, errors}}
        end

      _ ->
        {:error, {:invalid_custom_fields, [{"custom_fields", "must be a map"}]}}
    end
  end

  # The SLA promise the dashboard measures against lives on the studio, so the
  # due time is computed once at creation rather than re-derived on every read.
  defp put_response_due(attrs, %Scope{studio: studio}) do
    minutes = (studio && studio.reply_sla_minutes) || 240
    due = DateTime.add(DateTime.utc_now(), minutes * 60, :second)
    Map.put_new(attrs, "first_response_due_at", due)
  end

  defp stage_event("booked"), do: "lead.won"
  defp stage_event("lost"), do: "lead.lost"
  defp stage_event(_stage), do: "lead.stage_changed"

  defp unwrap({:ok, changes}, key), do: {:ok, Map.fetch!(changes, key)}
  defp unwrap({:error, _step, %Ecto.Changeset{} = changeset, _}, _key), do: {:error, changeset}
  defp unwrap({:error, _step, reason, _}, _key), do: {:error, reason}

  defp already_tagged?(%Ecto.Changeset{errors: errors}),
    do: Enum.any?(errors, fn {field, _} -> field in [:tag_id, :taggable_id] end)

  defp unique_violation?(%Ecto.Changeset{errors: errors}, field) do
    Enum.any?(errors, fn
      {^field, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  # Archived contacts are hidden unless asked for. They are never deleted, so
  # "show archived" has to be able to reach them or the toggle is a lie.
  defp filter_archived(query, true), do: query
  defp filter_archived(query, _false), do: where(query, [c], is_nil(c.archived_at))

  defp search_contacts(query, nil), do: query
  defp search_contacts(query, ""), do: query

  defp search_contacts(query, term) do
    pattern = "%#{term}%"

    where(
      query,
      [c],
      ilike(c.name, ^pattern) or ilike(c.email, ^pattern) or ilike(c.company, ^pattern)
    )
  end

  defp filter_leads(query, opts) do
    Enum.reduce(opts, query, fn
      {:stage, stage}, q -> where(q, [l], l.stage == ^stage)
      {:stages, stages}, q -> where(q, [l], l.stage in ^stages)
      {:owner_id, id}, q -> where(q, [l], l.owner_id == ^id)
      {:shoot_type, type}, q -> where(q, [l], l.shoot_type == ^type)
      {:open, true}, q -> where(q, [l], l.stage in ^Lead.open_stages())
      {:archived, false}, q -> where(q, [l], is_nil(l.archived_at))
      _, q -> q
    end)
  end
end
