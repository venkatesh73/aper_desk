defmodule AperDesk.People do
  @moduledoc """
  Leave and onboarding: the two things HR does that the team roster does not
  already cover.

  Approving leave writes a `hold`-kind assignment in the same transaction as
  the decision. That is the whole point of the feature — the calendar, the
  clash check and the availability picker all read `assignments`, so leave that
  did not land there would be a note nobody's booking flow consults. Approve
  and block must therefore succeed or fail together; an approval with no block
  is worse than no approval, because it reads as handled.

  A photographer can raise and cancel their own requests and see nothing else.
  That narrowing lives here rather than in `AperDesk.Visibility` because it is
  about a person rather than about the studio's work — the shape is the same,
  but "my leave" is not the same question as "my shoots".
  """

  import Ecto.Query

  alias AperDesk.Accounts.Membership
  alias AperDesk.Authorization
  alias AperDesk.Events
  alias AperDesk.People.{LeaveRequest, OnboardingTask}
  alias AperDesk.Repo
  alias AperDesk.Scheduling.Assignment
  alias AperDesk.Scope
  alias AperDesk.Scoped
  alias Ecto.Multi

  ## Leave

  @doc """
  Leave requests, newest first.

  Someone who may only see their own gets only their own, rather than an empty
  list or a refusal — asking for time off and then being unable to see whether
  it was granted would be a strange product.
  """
  def list_leave(%Scope{} = scope, opts \\ []) do
    with :ok <- Authorization.authorize(scope, :"leave.read") do
      {:ok,
       LeaveRequest
       |> Scoped.for_studio(scope)
       |> own_leave_only(scope)
       |> then(fn q ->
         case opts[:status] do
           nil -> q
           status -> where(q, [r], r.status == ^status)
         end
       end)
       |> order_by([r], asc: r.starts_on)
       |> preload([:user, :decided_by])
       |> Repo.all()}
    end
  end

  @doc "Requests nobody has decided yet — the HR dashboard's queue."
  def pending_leave(%Scope{} = scope), do: list_leave(scope, status: "pending")

  @doc "Leave that overlaps a window, for the roster and the clash panel."
  def leave_between(%Scope{} = scope, %Date{} = from, %Date{} = to) do
    with :ok <- Authorization.authorize(scope, :"leave.read") do
      {:ok,
       LeaveRequest
       |> Scoped.for_studio(scope)
       |> where([r], r.status in ^LeaveRequest.open_statuses())
       |> where([r], r.starts_on <= ^to and r.ends_on >= ^from)
       |> order_by([r], asc: r.starts_on)
       |> preload([:user])
       |> Repo.all()}
    end
  end

  def request_leave(%Scope{} = scope, attrs) do
    with :ok <- Authorization.authorize(scope, :"leave.write"),
         :ok <- ensure_own_or_approver(scope, attrs) do
      %LeaveRequest{}
      |> LeaveRequest.changeset(Scoped.put_studio(attrs, scope))
      |> Repo.insert()
    end
  end

  @doc """
  Approve leave and block the calendar in one transaction.

  The block is a `hold`, not a `shoot`: the exclusion constraint ignores holds,
  so approving leave over an already-booked shoot warns rather than being
  refused outright. That is the right way round — the studio decides whether to
  move the shoot, and the clash panel shows them the collision.
  """
  def approve_leave(%Scope{} = scope, id, note \\ nil) do
    with :ok <- Authorization.authorize(scope, :"leave.approve"),
         {:ok, request} <- Scoped.fetch(LeaveRequest, scope, id),
         :ok <- ensure_pending(request),
         {:ok, period} <- period_for(scope, request) do
      Multi.new()
      |> Multi.insert(:assignment, fn _ ->
        Assignment.changeset(%Assignment{}, %{
          "studio_id" => Scope.studio_id(scope),
          "user_id" => request.user_id,
          "kind" => "hold",
          "label" => leave_label(request),
          "period" => period,
          "expires_at" => expiry_for(period)
        })
      end)
      |> Multi.update(:request, fn %{assignment: assignment} ->
        request
        |> LeaveRequest.decision_changeset("approved", Scope.user_id(scope), note)
        |> Ecto.Changeset.put_change(:assignment_id, assignment.id)
      end)
      |> Events.record(:request, "leave.approved", "Leave approved", scope)
      |> Repo.transaction()
      |> case do
        {:ok, %{request: request}} -> {:ok, request}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  def decline_leave(%Scope{} = scope, id, note \\ nil) do
    with :ok <- Authorization.authorize(scope, :"leave.approve"),
         {:ok, request} <- Scoped.fetch(LeaveRequest, scope, id),
         :ok <- ensure_pending(request) do
      request
      |> LeaveRequest.decision_changeset("declined", Scope.user_id(scope), note)
      |> Repo.update()
    end
  end

  @doc """
  Withdraw a request.

  Releases the calendar block if there was one — cancelled leave that still
  held the date would quietly make somebody unbookable for a week nobody can
  account for.
  """
  def cancel_leave(%Scope{} = scope, id) do
    with :ok <- Authorization.authorize(scope, :"leave.write"),
         {:ok, request} <- Scoped.fetch(LeaveRequest, scope, id),
         :ok <- ensure_own_or_approver(scope, %{"user_id" => request.user_id}) do
      Multi.new()
      |> Multi.update(:request, LeaveRequest.cancel_changeset(request))
      |> Multi.run(:release, fn repo, _ -> release_block(repo, request) end)
      |> Repo.transaction()
      |> case do
        {:ok, %{request: request}} -> {:ok, request}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  ## Onboarding

  def list_onboarding(%Scope{} = scope, membership_id) do
    with :ok <- Authorization.authorize(scope, :"onboarding.read") do
      {:ok,
       OnboardingTask
       |> Scoped.for_studio(scope)
       |> where([t], t.membership_id == ^membership_id)
       |> order_by([t], asc: t.position, asc: t.inserted_at)
       |> Repo.all()}
    end
  end

  @doc "Everyone still part-way through their checklist."
  def onboarding_in_progress(%Scope{} = scope) do
    with :ok <- Authorization.authorize(scope, :"onboarding.read") do
      tasks =
        OnboardingTask
        |> Scoped.for_studio(scope)
        |> preload(membership: :user)
        |> Repo.all()

      {:ok,
       tasks
       |> Enum.group_by(& &1.membership_id)
       |> Enum.map(fn {_id, list} ->
         %{
           membership: hd(list).membership,
           total: length(list),
           done: Enum.count(list, &OnboardingTask.done?/1),
           tasks: Enum.sort_by(list, & &1.position)
         }
       end)
       |> Enum.reject(&(&1.done == &1.total))
       |> Enum.sort_by(& &1.membership.inserted_at, {:desc, NaiveDateTime})}
    end
  end

  @doc "Give a new member the studio's standard checklist."
  def start_onboarding(%Scope{} = scope, membership_id, labels \\ nil) do
    with :ok <- Authorization.authorize(scope, :"onboarding.write"),
         {:ok, membership} <- Scoped.fetch(Membership, scope, membership_id) do
      labels = labels || OnboardingTask.default_tasks()

      labels
      |> Enum.with_index()
      |> Enum.reduce(Multi.new(), fn {label, index}, multi ->
        Multi.insert(
          multi,
          {:task, index},
          OnboardingTask.changeset(%OnboardingTask{}, %{
            "studio_id" => Scope.studio_id(scope),
            "membership_id" => membership.id,
            "label" => label,
            "position" => index
          })
        )
      end)
      |> Repo.transaction()
      |> case do
        {:ok, _changes} -> list_onboarding(scope, membership.id)
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  def toggle_onboarding_task(%Scope{} = scope, task_id) do
    with :ok <- Authorization.authorize(scope, :"onboarding.write"),
         {:ok, task} <- Scoped.fetch(OnboardingTask, scope, task_id) do
      task |> OnboardingTask.toggle_changeset(Scope.user_id(scope)) |> Repo.update()
    end
  end

  def add_onboarding_task(%Scope{} = scope, membership_id, label) do
    with :ok <- Authorization.authorize(scope, :"onboarding.write"),
         {:ok, membership} <- Scoped.fetch(Membership, scope, membership_id) do
      next =
        OnboardingTask
        |> Scoped.for_studio(scope)
        |> where([t], t.membership_id == ^membership.id)
        |> Repo.aggregate(:count)

      %OnboardingTask{}
      |> OnboardingTask.changeset(%{
        "studio_id" => Scope.studio_id(scope),
        "membership_id" => membership.id,
        "label" => label,
        "position" => next
      })
      |> Repo.insert()
    end
  end

  ## Internals

  defp own_leave_only(query, %Scope{} = scope) do
    if Authorization.can?(scope, :"leave.approve") do
      query
    else
      where(query, [r], r.user_id == ^Scope.user_id(scope))
    end
  end

  # Raising leave for somebody else is an approver's job. Without this a
  # photographer could book a colleague a fortnight off.
  defp ensure_own_or_approver(%Scope{} = scope, attrs) do
    requested_for = attrs["user_id"] || attrs[:user_id]

    cond do
      Authorization.can?(scope, :"leave.approve") -> :ok
      is_nil(requested_for) -> :ok
      requested_for == Scope.user_id(scope) -> :ok
      true -> {:error, :unauthorized}
    end
  end

  defp ensure_pending(%LeaveRequest{status: "pending"}), do: :ok
  defp ensure_pending(%LeaveRequest{status: status}), do: {:error, {:already_decided, status}}

  defp period_for(%Scope{} = scope, request) do
    case LeaveRequest.period(request, scope.time_zone) do
      {:ok, period} -> {:ok, period}
      :error -> {:error, :bad_dates}
    end
  end

  defp leave_label(%LeaveRequest{kind: kind}),
    do: "#{String.capitalize(kind)} leave"

  # The hold expires when the leave ends, so a lapsed block cannot outlive the
  # time off it was standing in for.
  defp expiry_for({_from, to}), do: to

  defp release_block(_repo, %LeaveRequest{assignment_id: nil}), do: {:ok, :nothing_to_release}

  defp release_block(repo, %LeaveRequest{assignment_id: id}) do
    case repo.get(Assignment, id) do
      nil -> {:ok, :already_gone}
      assignment -> assignment |> Assignment.release_changeset() |> repo.update()
    end
  end
end
