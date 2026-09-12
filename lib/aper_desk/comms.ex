defmodule AperDesk.Comms do
  @moduledoc """
  Email in and out, capture forms, and the pipeline that turns an inbound
  enquiry into a lead.

  Nothing is ever sent on a studio's behalf without a person approving it. That
  is enforced here, in `send_captured_reply/2`, rather than left to the UI —
  a rule about a studio's reputation should not be one refactor away from being
  bypassed.

  Inbound capture advances one explicit stage at a time, so a lead built from a
  bad parse can be traced to the stage that got it wrong and re-run from there.
  """

  import Ecto.Query

  alias AperDesk.Authorization
  alias AperDesk.Billing.Limits

  alias AperDesk.Comms.{
    EmailAccount,
    EmailMessage,
    EmailTemplate,
    EmailThread,
    FormSubmission,
    InboundCapture,
    LeadCaptureForm,
    Notification
  }

  alias AperDesk.Crm
  alias AperDesk.Repo
  alias AperDesk.Scope
  alias AperDesk.Scoped
  alias Ecto.Multi

  ## Mailboxes

  def list_accounts(%Scope{} = scope) do
    with :ok <- Authorization.authorize(scope, :"comms.read") do
      EmailAccount |> Scoped.for_studio(scope) |> Repo.all()
    end
  end

  def connect_account(%Scope{} = scope, attrs) do
    with :ok <- Authorization.authorize(scope, :"comms.write") do
      %EmailAccount{}
      |> EmailAccount.changeset(Scoped.put_studio(attrs, scope))
      |> Repo.insert()
    end
  end

  def record_sync(%EmailAccount{} = account, attrs),
    do: account |> EmailAccount.sync_changeset(attrs) |> Repo.update()

  ## Messages

  @doc """
  Store an inbound message, attaching it to its thread.

  The message insert and the thread counter move together, so an unread badge
  can never count a message that was rolled back. Returns
  `{:error, :already_imported}` when the same provider Message-ID arrives twice,
  which is what makes an IMAP re-scan safe.
  """
  def record_inbound(%Scope{} = scope, attrs) do
    attrs =
      attrs
      |> Scoped.put_studio(scope)
      |> Map.put("direction", "inbound")
      |> Map.put_new("received_at", DateTime.utc_now())

    Multi.new()
    |> Multi.run(:thread, fn repo, _ -> find_or_create_thread(repo, scope, attrs) end)
    |> Multi.insert(:message, fn %{thread: thread} ->
      EmailMessage.changeset(%EmailMessage{}, Map.put(attrs, "thread_id", thread.id))
    end)
    |> Multi.update(:thread_counters, fn %{thread: thread, message: message} ->
      EmailThread.message_added_changeset(thread, message)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{message: message}} ->
        {:ok, message}

      {:error, :message, changeset, _} ->
        if duplicate_message?(changeset),
          do: {:error, :already_imported},
          else: {:error, changeset}

      {:error, _step, reason, _} ->
        {:error, reason}
    end
  end

  @doc """
  Queue an outbound message.

  Counted against the plan's per-lead email allowance under a row lock, so a
  runaway workflow cannot blow through the cap by sending concurrently.
  """
  def send_message(%Scope{} = scope, attrs) do
    with :ok <- Authorization.authorize(scope, :"comms.write") do
      attrs =
        attrs
        |> Scoped.put_studio(scope)
        |> Map.put("direction", "outbound")
        |> Map.put_new("state", "queued")

      Multi.new()
      |> Multi.insert(:message, EmailMessage.changeset(%EmailMessage{}, attrs))
      |> Multi.update_all(
        :usage,
        from(u in AperDesk.Billing.StudioUsage, where: u.studio_id == ^Scope.studio_id(scope)),
        inc: [emails_sent_this_period: 1]
      )
      |> Repo.transaction()
      |> case do
        {:ok, %{message: message}} -> {:ok, message}
        {:error, _step, reason, _} -> {:error, reason}
      end
    end
  end

  def list_threads(%Scope{} = scope, opts \\ []) do
    with :ok <- Authorization.authorize(scope, :"comms.read") do
      {:ok,
       EmailThread
       |> Scoped.for_studio(scope)
       |> then(fn q ->
         case opts[:lead_id] do
           nil -> q
           lead_id -> where(q, [t], t.lead_id == ^lead_id)
         end
       end)
       |> order_by([t], desc: t.last_message_at)
       |> Scoped.paginate(opts)
       |> Repo.all()}
    end
  end

  ## Templates

  def list_templates(%Scope{} = scope) do
    with :ok <- Authorization.authorize(scope, :"comms.read") do
      EmailTemplate
      |> Scoped.for_studio(scope)
      |> where([t], is_nil(t.archived_at))
      |> order_by([t], asc: t.name)
      |> Repo.all()
    end
  end

  def create_template(%Scope{} = scope, attrs) do
    with :ok <- Authorization.authorize(scope, :"comms.write") do
      %EmailTemplate{}
      |> EmailTemplate.changeset(Scoped.put_studio(attrs, scope))
      |> Repo.insert()
    end
  end

  def fetch_template(%Scope{} = scope, id) do
    with :ok <- Authorization.authorize(scope, :"comms.read") do
      Scoped.fetch(EmailTemplate, scope, id)
    end
  end

  def update_template(%Scope{} = scope, id, attrs) do
    with :ok <- Authorization.authorize(scope, :"comms.write"),
         {:ok, template} <- Scoped.fetch(EmailTemplate, scope, id) do
      template |> EmailTemplate.changeset(attrs) |> Repo.update()
    end
  end

  @doc """
  Retire a template.

  Archived rather than deleted, because a workflow step references a template by
  id and deleting one would leave that step pointing at nothing — discovered at
  6am when the workflow fires.
  """
  def archive_template(%Scope{} = scope, id) do
    with :ok <- Authorization.authorize(scope, :"comms.write"),
         {:ok, template} <- Scoped.fetch(EmailTemplate, scope, id) do
      template |> Ecto.Changeset.change(archived_at: DateTime.utc_now()) |> Repo.update()
    end
  end

  def change_template(template \\ %EmailTemplate{}, attrs \\ %{}),
    do: EmailTemplate.changeset(template, attrs)

  def fetch_form(%Scope{} = scope, id) do
    with :ok <- Authorization.authorize(scope, :"form.read") do
      Scoped.fetch(LeadCaptureForm, scope, id)
    end
  end

  def update_form(%Scope{} = scope, id, attrs) do
    with :ok <- Authorization.authorize(scope, :"form.write"),
         {:ok, form} <- Scoped.fetch(LeadCaptureForm, scope, id) do
      form |> LeadCaptureForm.changeset(attrs) |> Repo.update()
    end
  end

  def change_form(form \\ %LeadCaptureForm{}, attrs \\ %{}),
    do: LeadCaptureForm.changeset(form, attrs)

  def render_template(%Scope{} = scope, key, assigns) do
    case Repo.get_by(EmailTemplate, studio_id: Scope.studio_id(scope), key: key) do
      nil -> {:error, :not_found}
      template -> {:ok, EmailTemplate.render(template, assigns)}
    end
  end

  ## Inbound capture

  def start_capture(%Scope{} = scope, message_id, raw_source) do
    %InboundCapture{}
    |> InboundCapture.changeset(%{
      studio_id: Scope.studio_id(scope),
      message_id: message_id,
      raw_source: raw_source,
      stage: "received"
    })
    |> Repo.insert()
  end

  def record_parse(%InboundCapture{} = capture, parsed, parser_version, confidence),
    do:
      capture
      |> InboundCapture.parsed_changeset(parsed, parser_version, confidence)
      |> Repo.update()

  @doc """
  Turn a parsed capture into a lead, reusing the contact if we have seen the
  address before.

  Contact, lead and capture all move in one transaction — a capture marked
  `matched` while its lead insert failed would be a dead end nobody could
  re-run.
  """
  def capture_to_lead(%Scope{} = scope, %InboundCapture{} = capture) do
    parsed = capture.parsed || %{}

    Repo.transaction(fn ->
      with {:ok, contact} <- upsert_contact_from(scope, parsed),
           {:ok, lead} <- create_lead_from(scope, capture, contact, parsed),
           {:ok, capture} <- Repo.update(InboundCapture.matched_changeset(capture, lead.id)) do
        %{lead: lead, contact: contact, capture: capture}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def record_draft(%InboundCapture{} = capture, attrs),
    do: capture |> InboundCapture.drafted_changeset(attrs) |> Repo.update()

  @doc """
  Send a drafted reply — only if a person approved it.

  The guard is here rather than in the caller because this is the last point
  before a message goes out under the studio's name.
  """
  def send_captured_reply(%Scope{} = scope, %InboundCapture{} = capture) do
    if InboundCapture.sendable?(capture) do
      send_message(scope, %{
        "lead_id" => capture.lead_id,
        "subject" => capture.draft_subject,
        "body_text" => capture.draft_body,
        "to_addresses" => [InboundCapture.field(capture, "email")] |> Enum.reject(&is_nil/1)
      })
    else
      {:error, :not_approved}
    end
  end

  def approve_capture(%Scope{} = scope, capture_id) do
    with :ok <- Authorization.authorize(scope, :"comms.write"),
         {:ok, capture} <- Scoped.fetch(InboundCapture, scope, capture_id) do
      capture |> InboundCapture.approved_changeset(scope.user) |> Repo.update()
    end
  end

  ## Capture forms

  def list_forms(%Scope{} = scope) do
    with :ok <- Authorization.authorize(scope, :"comms.read") do
      LeadCaptureForm |> Scoped.for_studio(scope) |> order_by([f], asc: f.name) |> Repo.all()
    end
  end

  def create_form(%Scope{} = scope, attrs) do
    with :ok <- Authorization.authorize(scope, :"form.write") do
      Multi.new()
      |> Multi.run(:limit, fn repo, _ ->
        case Limits.ensure_headroom(repo, scope, "forms") do
          :ok -> {:ok, :within_limit}
          error -> error
        end
      end)
      |> Multi.insert(
        :form,
        LeadCaptureForm.changeset(%LeadCaptureForm{}, Scoped.put_studio(attrs, scope))
      )
      |> Repo.transaction()
      |> case do
        {:ok, %{form: form}} -> {:ok, form}
        {:error, _step, reason, _} -> {:error, reason}
      end
    end
  end

  @doc """
  The form a stranger should be sent to when they want to enquire.

  The directory needs one door per studio and has no way to choose between
  four, so it takes the first active one. Returns nil when a studio has not
  published any — the profile then says so rather than linking to a 404.
  """
  def default_public_form(studio_id) do
    Repo.one(
      from f in LeadCaptureForm,
        where: f.studio_id == ^studio_id and f.active,
        order_by: [asc: f.inserted_at],
        limit: 1
    )
  end

  def fetch_public_form(studio_slug, form_slug) do
    query =
      from f in LeadCaptureForm,
        join: s in AperDesk.Accounts.Studio,
        on: s.id == f.studio_id,
        where: s.slug == ^studio_slug and f.slug == ^form_slug and f.active,
        preload: [studio: s]

    case Repo.one(query) do
      nil -> {:error, :not_found}
      form -> {:ok, form}
    end
  end

  @doc """
  Accept a public form submission and create the lead behind it.

  Submission, contact and lead commit together, and the raw answers are kept
  even after mapping so a bad mapping can be diagnosed against what the client
  actually typed.
  """
  def submit_form(%LeadCaptureForm{} = form, answers, meta \\ %{}) do
    scope = %Scope{studio: form.studio, currency: "USD", time_zone: "Etc/UTC"}

    with {:ok, validated} <- LeadCaptureForm.validate_submission(form, answers) do
      Repo.transaction(fn ->
        with {:ok, contact} <- upsert_contact_from(scope, validated),
             {:ok, lead} <- lead_from_submission(scope, form, contact, validated),
             {:ok, submission} <- insert_submission(form, lead, validated, meta),
             {1, _} <- bump_submission_count(form) do
          %{lead: lead, contact: contact, submission: submission}
        else
          {:error, reason} -> Repo.rollback(reason)
          other -> Repo.rollback(other)
        end
      end)
    end
  end

  ## Notifications

  def notify(%Scope{} = scope, user_id, attrs) do
    %Notification{}
    |> Notification.changeset(
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.merge(%{"studio_id" => Scope.studio_id(scope), "user_id" => user_id})
    )
    |> Repo.insert()
  end

  def unread_notifications(%Scope{} = scope) do
    Repo.all(
      from n in Notification,
        where:
          n.studio_id == ^Scope.studio_id(scope) and n.user_id == ^Scope.user_id(scope) and
            is_nil(n.read_at),
        order_by: [desc: n.inserted_at],
        limit: 50
    )
  end

  def mark_read(%Scope{} = scope, notification_id) do
    case Repo.get_by(Notification, id: notification_id, user_id: Scope.user_id(scope)) do
      nil -> {:error, :not_found}
      notification -> notification |> Notification.read_changeset() |> Repo.update()
    end
  end

  ## Internals

  defp find_or_create_thread(repo, scope, attrs) do
    provider_thread_id = attrs["provider_thread_id"]

    existing =
      provider_thread_id &&
        repo.get_by(EmailThread,
          studio_id: Scope.studio_id(scope),
          provider_thread_id: provider_thread_id
        )

    case existing do
      %EmailThread{} = thread ->
        {:ok, thread}

      _ ->
        %EmailThread{}
        |> EmailThread.changeset(%{
          studio_id: Scope.studio_id(scope),
          subject: attrs["subject"],
          provider_thread_id: provider_thread_id,
          lead_id: attrs["lead_id"]
        })
        |> repo.insert()
    end
  end

  defp upsert_contact_from(scope, parsed) do
    Crm.upsert_contact(scope, %{
      "name" => parsed["name"] || parsed["email"] || "Unknown",
      "email" => parsed["email"],
      "phone" => parsed["phone"],
      "source" => "email"
    })
  end

  defp create_lead_from(scope, capture, contact, parsed) do
    Crm.create_lead(scope, %{
      "contact_id" => contact.id,
      "title" => parsed["title"] || parsed["subject"] || "Enquiry",
      "shoot_type" => parsed["shoot_type"] || "other",
      "source" => "email",
      "source_detail" => capture.parser_version
    })
  end

  defp lead_from_submission(scope, form, contact, answers) do
    Crm.create_lead(scope, %{
      "contact_id" => contact.id,
      "owner_id" => form.assign_to_id,
      "title" => answers["title"] || form.name,
      "shoot_type" => answers["shoot_type"] || "other",
      "source" => "form",
      "source_detail" => form.slug
    })
  end

  defp insert_submission(form, lead, answers, meta) do
    %FormSubmission{}
    |> FormSubmission.changeset(%{
      form_id: form.id,
      studio_id: form.studio_id,
      lead_id: lead.id,
      answers: answers,
      ip_address: meta[:ip_address],
      user_agent: meta[:user_agent],
      referrer: meta[:referrer]
    })
    |> Repo.insert()
  end

  defp bump_submission_count(form) do
    Repo.update_all(
      from(f in LeadCaptureForm, where: f.id == ^form.id),
      inc: [submission_count: 1]
    )
  end

  defp duplicate_message?(%Ecto.Changeset{errors: errors}),
    do: Enum.any?(errors, fn {field, _} -> field in [:account_id, :message_id] end)
end
