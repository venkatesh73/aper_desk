defmodule AperDesk.PeopleTest do
  use AperDesk.DataCase, async: true

  import AperDesk.Fixtures

  alias AperDesk.{Accounts, People, Repo, Scheduling}
  alias AperDesk.People.LeaveRequest

  setup do
    %{studio: studio, scope: owner} = studio_fixture()
    plan_fixture(studio)
    anna = member(studio, "Anna", "photographer")
    hr = member(studio, "Sofia", "hr")
    %{studio: studio, owner: owner, anna: anna, hr: hr}
  end

  defp member(studio, name, role) do
    {:ok, user} =
      Accounts.register_user(%{
        "name" => name,
        "email" => "#{String.downcase(name)}-#{System.unique_integer([:positive])}@example.com",
        "password" => "a sufficiently long passphrase"
      })

    membership =
      Repo.insert!(
        Accounts.Membership.changeset(%Accounts.Membership{}, %{
          user_id: user.id,
          studio_id: studio.id,
          role: role,
          status: "active"
        })
      )

    {:ok, scope} = Accounts.scope_for(user, studio.id)
    %{user: user, scope: scope, membership: membership}
  end

  defp request(scope, user_id, from, to) do
    {:ok, request} =
      People.request_leave(scope, %{
        "user_id" => user_id,
        "starts_on" => from,
        "ends_on" => to,
        "kind" => "holiday",
        "reason" => "A week away"
      })

    request
  end

  describe "raising leave" do
    test "a photographer may ask for their own and nobody else's", %{anna: anna, hr: hr} do
      from = Date.add(Date.utc_today(), 30)
      to = Date.add(from, 4)

      assert {:ok, _} =
               People.request_leave(anna.scope, %{
                 "user_id" => anna.user.id,
                 "starts_on" => from,
                 "ends_on" => to
               })

      # Without this a photographer could book a colleague a fortnight off.
      assert {:error, :unauthorized} =
               People.request_leave(anna.scope, %{
                 "user_id" => hr.user.id,
                 "starts_on" => from,
                 "ends_on" => to
               })
    end

    test "a request that ends before it starts is refused", %{anna: anna} do
      from = Date.add(Date.utc_today(), 30)

      assert {:error, changeset} =
               People.request_leave(anna.scope, %{
                 "user_id" => anna.user.id,
                 "starts_on" => from,
                 "ends_on" => Date.add(from, -1)
               })

      assert "cannot be before the first day" in errors_on(changeset).ends_on
    end

    test "a photographer sees only their own", %{owner: owner, anna: anna, hr: hr} do
      from = Date.add(Date.utc_today(), 30)
      request(owner, anna.user.id, from, Date.add(from, 2))
      request(owner, hr.user.id, from, Date.add(from, 2))

      assert {:ok, [mine]} = People.list_leave(anna.scope)
      assert mine.user_id == anna.user.id

      # HR approves, so HR sees the queue.
      assert {:ok, both} = People.list_leave(hr.scope)
      assert length(both) == 2
    end
  end

  describe "approving" do
    test "blocks the calendar, not just the record", %{owner: owner, anna: anna, hr: hr} do
      from = Date.add(Date.utc_today(), 30)
      to = Date.add(from, 4)
      leave = request(owner, anna.user.id, from, to)

      assert {:ok, approved} = People.approve_leave(hr.scope, leave.id)
      assert approved.status == "approved"
      assert approved.assignment_id

      # The whole point: the booking flow reads assignments, so leave that did
      # not land there would be a note nobody consults.
      {:ok, window_from} = DateTime.new(from, ~T[09:00:00], "Etc/UTC")
      {:ok, window_to} = DateTime.new(from, ~T[17:00:00], "Etc/UTC")

      clashes = Scheduling.clashes_for(owner, anna.user.id, {window_from, window_to})
      assert [%{kind: "hold", label: "Holiday leave"}] = clashes
    end

    test "a photographer cannot approve their own", %{owner: owner, anna: anna} do
      from = Date.add(Date.utc_today(), 30)
      leave = request(owner, anna.user.id, from, Date.add(from, 2))

      assert {:error, :unauthorized} = People.approve_leave(anna.scope, leave.id)
    end

    test "deciding twice is refused", %{owner: owner, anna: anna, hr: hr} do
      from = Date.add(Date.utc_today(), 30)
      leave = request(owner, anna.user.id, from, Date.add(from, 2))

      assert {:ok, _} = People.approve_leave(hr.scope, leave.id)
      assert {:error, {:already_decided, "approved"}} = People.decline_leave(hr.scope, leave.id)
    end

    test "declining leaves the calendar alone", %{owner: owner, anna: anna, hr: hr} do
      from = Date.add(Date.utc_today(), 30)
      leave = request(owner, anna.user.id, from, Date.add(from, 2))

      assert {:ok, declined} = People.decline_leave(hr.scope, leave.id, "Too many away")
      assert declined.status == "declined"
      refute declined.assignment_id

      {:ok, f} = DateTime.new(from, ~T[09:00:00], "Etc/UTC")
      {:ok, t} = DateTime.new(from, ~T[17:00:00], "Etc/UTC")
      assert Scheduling.clashes_for(owner, anna.user.id, {f, t}) == []
    end
  end

  describe "cancelling" do
    test "frees the date back up", %{owner: owner, anna: anna, hr: hr} do
      from = Date.add(Date.utc_today(), 30)
      leave = request(owner, anna.user.id, from, Date.add(from, 2))
      {:ok, _} = People.approve_leave(hr.scope, leave.id)

      assert {:ok, cancelled} = People.cancel_leave(anna.scope, leave.id)
      assert cancelled.status == "cancelled"

      # Cancelled leave still holding the date would make somebody unbookable
      # for a week nobody can account for.
      {:ok, f} = DateTime.new(from, ~T[09:00:00], "Etc/UTC")
      {:ok, t} = DateTime.new(from, ~T[17:00:00], "Etc/UTC")
      assert Scheduling.clashes_for(owner, anna.user.id, {f, t}) == []
    end
  end

  describe "onboarding" do
    test "starts from the studio's standard checklist and tracks progress", %{
      hr: hr,
      anna: anna
    } do
      assert {:ok, tasks} = People.start_onboarding(hr.scope, anna.membership.id)
      assert length(tasks) == length(AperDesk.People.OnboardingTask.default_tasks())
      assert Enum.all?(tasks, &is_nil(&1.done_at))

      assert {:ok, [in_progress]} = People.onboarding_in_progress(hr.scope)
      assert in_progress.done == 0
      assert in_progress.total == length(tasks)

      {:ok, done} = People.toggle_onboarding_task(hr.scope, hd(tasks).id)
      assert done.done_at

      assert {:ok, [updated]} = People.onboarding_in_progress(hr.scope)
      assert updated.done == 1
    end

    test "drops off the list once everything is ticked", %{hr: hr, anna: anna} do
      {:ok, tasks} = People.start_onboarding(hr.scope, anna.membership.id)
      for task <- tasks, do: {:ok, _} = People.toggle_onboarding_task(hr.scope, task.id)

      assert {:ok, []} = People.onboarding_in_progress(hr.scope)
    end

    test "a photographer cannot see or change it", %{hr: hr, anna: anna} do
      {:ok, _} = People.start_onboarding(hr.scope, anna.membership.id)

      assert {:error, :unauthorized} = People.onboarding_in_progress(anna.scope)
      assert {:error, :unauthorized} = People.list_onboarding(anna.scope, anna.membership.id)
    end
  end
end
