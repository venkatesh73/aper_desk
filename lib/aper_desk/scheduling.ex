defmodule AperDesk.Scheduling do
  @moduledoc """
  Shoots, who is on them, and whether anyone is double-booked.

  Clash detection is enforced by a GiST exclusion constraint in Postgres, not
  by a check-then-insert here. That distinction matters: a read followed by a
  write has a window between them, and two coordinators booking the same
  second shooter at the same moment would both pass the check and both insert.
  The database rejects the loser under any amount of concurrency, and this
  module turns that rejection into `{:error, {:clash, assignments}}` so the UI
  can offer to resolve it.

  Holds are deliberately outside the constraint. A soft hold warns about a
  confirmed shoot rather than being refused — the studio decides whether to
  pencil something in over the top, and the system's job is to tell the truth
  rather than to overrule them.
  """

  import Ecto.Query

  alias AperDesk.Authorization
  alias AperDesk.Repo
  alias AperDesk.Scheduling.{Assignment, AvailabilityRule, BookingSlot, Job, TstzRange}
  alias AperDesk.Scope
  alias AperDesk.Scoped
  alias AperDesk.Visibility
  alias Ecto.Multi

  ## Jobs

  def list_jobs(%Scope{} = scope, opts \\ []) do
    with :ok <- Authorization.authorize(scope, :"job.read") do
      {:ok,
       Job
       |> from(as: :job)
       |> Scoped.for_studio(scope)
       |> Visibility.jobs(scope)
       |> filter_jobs(opts)
       |> order_by([j], asc: j.starts_at)
       |> Repo.all()}
    end
  end

  def fetch_job(%Scope{} = scope, id) do
    with :ok <- Authorization.authorize(scope, :"job.read"),
         {:ok, job} <- Scoped.fetch(Job, scope, id) do
      if Visibility.visible?(scope, job), do: {:ok, job}, else: {:error, :unauthorized}
    end
  end

  @doc """
  Create a shoot and reserve everyone on it in one transaction.

  If any assignment clashes, nothing is written — a job whose crew is only
  half-booked is worse than no job, because it looks scheduled.
  """
  def create_job(%Scope{} = scope, attrs, crew \\ []) do
    with :ok <- Authorization.authorize(scope, :"job.write") do
      Multi.new()
      |> Multi.insert(:job, Job.changeset(%Job{}, Scoped.put_studio(attrs, scope)))
      |> Multi.run(:assignments, fn repo, %{job: job} ->
        assign_crew(repo, scope, job, crew)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{job: job}} -> {:ok, job}
        {:error, :assignments, reason, _} -> {:error, reason}
        {:error, _step, changeset, _} -> {:error, changeset}
      end
    end
  end

  def update_job(%Scope{} = scope, id, attrs) do
    with :ok <- Authorization.authorize(scope, :"job.write"),
         {:ok, job} <- Scoped.fetch(Job, scope, id) do
      job |> Job.changeset(attrs) |> Repo.update()
    end
  end

  @doc """
  Cancel a shoot and release the crew.

  Releasing matters: an assignment left behind keeps blocking those people's
  calendars for a shoot that is not happening, and the studio would have no
  idea why the date shows as unavailable.
  """
  def cancel_job(%Scope{} = scope, id, reason) do
    with :ok <- Authorization.authorize(scope, :"job.write"),
         {:ok, job} <- Scoped.fetch(Job, scope, id) do
      now = DateTime.utc_now()

      Multi.new()
      |> Multi.update(
        :job,
        Job.changeset(job, %{status: "cancelled"})
        |> Ecto.Changeset.put_change(:cancelled_at, now)
        |> Ecto.Changeset.put_change(:cancellation_reason, reason)
      )
      |> Multi.update_all(
        :released,
        from(a in Assignment, where: a.job_id == ^job.id and is_nil(a.released_at)),
        set: [released_at: now, updated_at: now]
      )
      |> Repo.transaction()
      |> case do
        {:ok, %{job: job}} -> {:ok, job}
        {:error, _step, changeset, _} -> {:error, changeset}
      end
    end
  end

  ## Assignments and clashes

  @doc """
  Reserve `user_id` for a window.

  Returns `{:error, {:clash, conflicting}}` when the database refuses, with the
  commitments that caused it already loaded — the UI needs to name them, and
  re-querying after the fact could show a different answer.
  """
  def assign(%Scope{} = scope, attrs) do
    with :ok <- Authorization.authorize(scope, :"assignment.write") do
      %Assignment{}
      |> Assignment.changeset(Scoped.put_studio(attrs, scope))
      |> Repo.insert()
      |> case do
        {:ok, assignment} ->
          {:ok, assignment}

        {:error, changeset} ->
          maybe_clash(scope, changeset, attrs)
      end
    end
  end

  def release(%Scope{} = scope, assignment_id) do
    with :ok <- Authorization.authorize(scope, :"assignment.write"),
         {:ok, assignment} <- Scoped.fetch(Assignment, scope, assignment_id) do
      assignment |> Assignment.release_changeset() |> Repo.update()
    end
  end

  @doc """
  Commitments that overlap `period` for `user_id`, ignoring released ones.

  This is the read-only question the calendar asks. It is *not* what prevents
  a double booking — the constraint is — so a stale answer here is a display
  issue rather than a correctness one.
  """
  def clashes_for(%Scope{} = scope, user_id, {_from, _to} = period, opts \\ []) do
    with :ok <- Authorization.authorize(scope, :"assignment.read") do
      exclude_id = Keyword.get(opts, :exclude)

      Assignment
      |> Scoped.for_studio(scope)
      |> where([a], a.user_id == ^user_id and is_nil(a.released_at))
      |> where([a], fragment("? && ?", a.period, type(^period, TstzRange)))
      |> then(fn q -> if exclude_id, do: where(q, [a], a.id != ^exclude_id), else: q end)
      |> then(fn q ->
        if Keyword.get(opts, :blocking_only, false),
          do: where(q, [a], a.kind != "hold"),
          else: q
      end)
      |> preload(:job)
      |> Repo.all()
    end
  end

  @doc """
  Whether `user_id` can actually be booked for the window.

  Holds are excluded, because the exclusion constraint excludes them: if this
  said "unavailable" where the database would accept the insert, the UI would
  grey out a date the studio is entitled to book. Availability here means
  exactly what the constraint means, and nothing else.

  Use `clashes_for/4` to show soft conflicts — including holds — as warnings.
  """
  def available?(%Scope{} = scope, user_id, period),
    do: clashes_for(scope, user_id, period, blocking_only: true) == []

  @doc """
  Everyone free for `period`, for the "who can shoot this?" picker.

  Runs as one query rather than a clash check per member, because a studio with
  twenty freelancers would otherwise issue twenty round trips to render a
  dropdown.
  """
  def available_users(%Scope{} = scope, {_from, _to} = period) do
    with :ok <- Authorization.authorize(scope, :"assignment.read") do
      # Holds excluded for the same reason as in `available?/3`: this picker must
      # offer exactly the people the database would let you book.
      busy =
        Assignment
        |> Scoped.for_studio(scope)
        |> where([a], is_nil(a.released_at) and a.kind != "hold")
        |> where([a], fragment("? && ?", a.period, type(^period, TstzRange)))
        |> select([a], a.user_id)

      from(m in AperDesk.Accounts.Membership,
        where:
          m.studio_id == ^Scope.studio_id(scope) and m.status == "active" and
            m.user_id not in subquery(busy),
        preload: [:user],
        select: m
      )
      |> Repo.all()
    end
  end

  @doc "Assignments overlapping a window, for the calendar view."
  def calendar(%Scope{} = scope, {_from, _to} = period, opts \\ []) do
    with :ok <- Authorization.authorize(scope, :"assignment.read") do
      query =
        Assignment
        |> Scoped.for_studio(scope)
        |> where([a], is_nil(a.released_at))
        |> where([a], fragment("? && ?", a.period, type(^period, TstzRange)))
        |> preload([:job, :user])

      query =
        case Keyword.get(opts, :user_id) do
          nil -> query
          user_id -> where(query, [a], a.user_id == ^user_id)
        end

      {:ok, Repo.all(query)}
    end
  end

  @doc """
  Pairs of commitments that overlap for the same person in `period`.

  Computed from one loaded set rather than a query per person, so the calendar
  reports exactly what it drew.

  Every pair here involves at least one hold, and that is not an accident: the
  exclusion constraint makes two *blocking* commitments overlapping for one
  person impossible to write, so the only overlap that can survive is one the
  database was told to permit. Those are precisely the ones a human has to
  decide about — confirm the pencilled date, or release it.

  Each pair is returned once, ordered by id, rather than twice from both sides.
  """
  def clashes_in(%Scope{} = scope, {_from, _to} = period, opts \\ []) do
    with {:ok, assignments} <- calendar(scope, period, opts) do
      pairs =
        assignments
        |> Enum.reject(&(not is_nil(&1.released_at)))
        |> Enum.group_by(& &1.user_id)
        |> Enum.flat_map(fn {_user_id, list} ->
          for a <- list,
              b <- list,
              a.id < b.id,
              a.kind == "hold" or b.kind == "hold",
              TstzRange.overlaps?(a.period, b.period),
              do: %{id: a.id, user: a.user, first: a, second: b, starts_at: elem(a.period, 0)}
        end)
        |> Enum.sort_by(& &1.starts_at, DateTime)

      {:ok, pairs}
    end
  end

  @doc "Holds that will lapse within `days`, so a pencilled date is not lost silently."
  def holds_expiring(%Scope{} = scope, days \\ 14) do
    with :ok <- Authorization.authorize(scope, :"assignment.read") do
      now = DateTime.utc_now()
      until = DateTime.add(now, days * 24 * 60 * 60, :second)

      Assignment
      |> Scoped.for_studio(scope)
      |> where([a], a.kind == "hold" and is_nil(a.released_at))
      |> where([a], not is_nil(a.expires_at) and a.expires_at >= ^now and a.expires_at <= ^until)
      |> order_by([a], asc: a.expires_at)
      |> preload([:job, :user])
      |> Repo.all()
    end
  end

  ## Availability and public booking

  def list_availability(%Scope{} = scope) do
    with :ok <- Authorization.authorize(scope, :"assignment.read") do
      AvailabilityRule
      |> Scoped.for_studio(scope)
      |> order_by([r], asc: r.day_of_week, asc: r.starts_at_minute)
      |> Repo.all()
    end
  end

  def set_availability(%Scope{} = scope, attrs) do
    with :ok <- Authorization.authorize(scope, :"assignment.write") do
      %AvailabilityRule{}
      |> AvailabilityRule.changeset(Scoped.put_studio(attrs, scope))
      |> Repo.insert()
    end
  end

  def list_open_slots(studio_id, from, to) do
    Repo.all(
      from s in BookingSlot,
        where:
          s.studio_id == ^studio_id and s.status == "open" and
            s.starts_at >= ^from and s.starts_at < ^to,
        order_by: s.starts_at
    )
  end

  @doc """
  Every open slot for a studio, with the session each one is for.

  Public: no scope, because the person choosing a Saturday afternoon has no
  account. Only `status: "open"` rows are ever returned, so a held or booked
  slot is not merely greyed out on the page — it is not sent to the browser.
  """
  def open_slots_for(studio_id, from, to) do
    Repo.all(
      from s in BookingSlot,
        where:
          s.studio_id == ^studio_id and s.status == "open" and
            s.starts_at >= ^from and s.starts_at < ^to,
        order_by: s.starts_at,
        preload: [:package]
    )
  end

  @doc """
  Take a slot from the public booking page.

  The status guard is in the WHERE clause, so two clients submitting the same
  slot at once cannot both win: the second update matches zero rows and gets
  `{:error, :slot_taken}` rather than silently overwriting the first booking.

  Claiming the slot and creating the lead are one transaction. A slot marked
  booked with no lead behind it is a studio holding a Saturday for nobody, and
  a lead with no slot is a client who thinks they have a time and does not.
  """
  def book_slot(slot_id, attrs) when is_map(attrs) do
    email = attrs["email"] || attrs[:email]

    Repo.transaction(fn ->
      # Preloaded after the claim: `update_all` returns the row without its
      # associations, and reading `slot.package` off that raises rather than
      # returning nil.
      with {:ok, claimed} <- claim_slot(slot_id, email),
           slot <- Repo.preload(claimed, :package),
           studio when not is_nil(studio) <- Repo.get(AperDesk.Accounts.Studio, slot.studio_id),
           scope <- public_scope(studio),
           {:ok, contact} <- contact_for_booking(scope, attrs),
           {:ok, lead} <- lead_for_booking(scope, slot, contact, attrs),
           {:ok, slot} <- link_lead(slot, lead) do
        %{slot: slot, lead: lead, contact: contact}
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
        other -> Repo.rollback(other)
      end
    end)
  end

  def book_slot(slot_id, email) when is_binary(email),
    do: book_slot(slot_id, %{"email" => email})

  defp claim_slot(slot_id, email) do
    now = DateTime.utc_now()

    {count, slots} =
      Repo.update_all(
        from(s in BookingSlot,
          where: s.id == ^slot_id and s.status == "open",
          select: s
        ),
        set: [status: "booked", booked_by_email: email, booked_at: now, updated_at: now]
      )

    case {count, slots} do
      {1, [slot]} -> {:ok, slot}
      _taken -> {:error, :slot_taken}
    end
  end

  # No user, because there is not one: the booking came from a stranger. The
  # contexts accept this shape on their public paths and nowhere else.
  defp public_scope(studio) do
    %Scope{
      studio: studio,
      currency: studio.base_currency || "USD",
      time_zone: studio.time_zone || "Etc/UTC"
    }
  end

  defp contact_for_booking(scope, attrs) do
    AperDesk.Crm.upsert_contact(scope, %{
      "name" => attrs["name"] || attrs["email"] || "Booking",
      "email" => attrs["email"],
      "phone" => attrs["phone"],
      "source" => "booking"
    })
  end

  defp lead_for_booking(scope, slot, contact, attrs) do
    AperDesk.Crm.create_lead(scope, %{
      "contact_id" => contact.id,
      "title" => booking_title(slot, attrs),
      "shoot_type" => (slot.package && slot.package.shoot_type) || "other",
      "source" => "booking",
      "source_detail" => DateTime.to_iso8601(slot.starts_at),
      "desired_date" => DateTime.to_date(slot.starts_at),
      "location" => attrs["location"],
      # `custom_fields` is the studio's own defined schema and drops anything
      # undefined, so this does not go there.
      "notes" => attrs["notes"]
    })
  end

  defp booking_title(slot, attrs) do
    session = attrs["session_name"] || (slot.package && slot.package.name) || "Session"
    "#{session} · #{Calendar.strftime(slot.starts_at, "%-d %b %Y")}"
  end

  defp link_lead(slot, lead) do
    slot |> Ecto.Changeset.change(lead_id: lead.id) |> Repo.update()
  end

  @doc """
  Studio ids with a shoot on `date`, for the public directory's date filter.

  Deliberately only ids and only a yes/no. The directory asks "can this studio
  take a wedding on the 14th", and the honest answer to that does not require
  telling a stranger whose wedding it is, where, or for how much.

  Pencilled counts as busy. A studio holding a date for someone else should not
  be shown to a searcher as free — the hold exists precisely because it might
  become a booking.
  """
  def studios_busy_on(%Date{} = date) do
    {:ok, day_start} = DateTime.new(date, ~T[00:00:00.000000], "Etc/UTC")
    day_end = DateTime.add(day_start, 86_400, :second)

    Repo.all(
      from j in Job,
        where:
          j.status in ["pencilled", "confirmed"] and
            j.starts_at < ^day_end and j.ends_at > ^day_start,
        distinct: true,
        select: j.studio_id
    )
  end

  ## Internals

  defp assign_crew(repo, scope, job, crew) do
    {from, to} = Job.occupied_window(job)

    Enum.reduce_while(crew, {:ok, []}, fn member, {:ok, acc} ->
      attrs =
        member
        |> Map.new(fn {k, v} -> {to_string(k), v} end)
        |> Map.merge(%{
          "studio_id" => job.studio_id,
          "job_id" => job.id,
          "period" => {from, to}
        })

      # `mode: :savepoint` is load-bearing. The exclusion constraint firing
      # aborts the surrounding Postgres transaction, and this insert runs
      # inside one — so without a savepoint the very next statement, including
      # the `clashes_for/4` query that turns the violation into a useful
      # answer, fails with "current transaction is aborted". The clash path
      # would report a driver error instead of the clash.
      case repo.insert(Assignment.changeset(%Assignment{}, attrs), mode: :savepoint) do
        {:ok, assignment} ->
          {:cont, {:ok, [assignment | acc]}}

        {:error, changeset} ->
          {:halt, clash_or_changeset(scope, changeset, attrs)}
      end
    end)
  end

  defp clash_or_changeset(scope, changeset, attrs) do
    case maybe_clash(scope, changeset, attrs) do
      {:error, reason} -> {:error, reason}
      other -> other
    end
  end

  # An exclusion-constraint violation surfaces as an error on :period. Load the
  # commitments that caused it so the caller can name them.
  defp maybe_clash(scope, changeset, attrs) do
    if Keyword.has_key?(changeset.errors, :period) do
      user_id = fetch_attr(attrs, "user_id")
      period = fetch_attr(attrs, "period")

      case {user_id, period} do
        {nil, _} -> {:error, changeset}
        {_, nil} -> {:error, changeset}
        {user_id, period} -> {:error, {:clash, clashes_for(scope, user_id, period)}}
      end
    else
      {:error, changeset}
    end
  end

  defp fetch_attr(attrs, key),
    do: Map.get(attrs, key) || Map.get(attrs, String.to_existing_atom(key))

  defp filter_jobs(query, opts) do
    Enum.reduce(opts, query, fn
      {:status, status}, q -> where(q, [j], j.status == ^status)
      {:from, from}, q -> where(q, [j], j.starts_at >= ^from)
      {:to, to}, q -> where(q, [j], j.starts_at < ^to)
      {:limit, limit}, q -> limit(q, ^limit)
      _, q -> q
    end)
  end
end
