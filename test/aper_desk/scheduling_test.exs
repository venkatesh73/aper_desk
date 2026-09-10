defmodule AperDesk.SchedulingTest do
  @moduledoc """
  Clash detection is enforced by a Postgres exclusion constraint, so the test
  that matters is the concurrent one: a check-then-insert would pass these
  single-threaded cases and still double-book under load.
  """

  use AperDesk.DataCase, async: false

  import AperDesk.Fixtures

  alias AperDesk.Scheduling
  alias AperDesk.Scheduling.Job

  setup do
    %{scope: scope, studio: studio, user: user} = studio_fixture()
    plan_fixture(studio)
    %{scope: scope, user: user}
  end

  describe "create_job/3" do
    test "reserves the crew including travel buffers", %{scope: scope, user: user} do
      {starts_at, ends_at} = future_window()

      assert {:ok, job} =
               Scheduling.create_job(
                 scope,
                 %{
                   "title" => "Anna & Ben wedding",
                   "starts_at" => starts_at,
                   "ends_at" => ends_at,
                   "travel_before_minutes" => 120,
                   "travel_after_minutes" => 120
                 },
                 [%{user_id: user.id, role: "lead_photographer"}]
               )

      {from, to} = Job.occupied_window(job)
      assert DateTime.diff(to, from) == DateTime.diff(ends_at, starts_at) + 4 * 3600
      refute Scheduling.available?(scope, user.id, {starts_at, ends_at})
    end
  end

  describe "clashes" do
    setup %{scope: scope, user: user} do
      {starts_at, ends_at} = future_window()

      {:ok, job} =
        Scheduling.create_job(
          scope,
          %{"title" => "Wedding", "starts_at" => starts_at, "ends_at" => ends_at},
          [%{user_id: user.id}]
        )

      %{job: job, window: {starts_at, ends_at}}
    end

    test "a second booking is refused and names the conflict", %{
      scope: scope,
      user: user,
      job: job,
      window: {starts_at, _}
    } do
      overlap = {DateTime.add(starts_at, 3600), DateTime.add(starts_at, 2 * 3600)}

      assert {:error, {:clash, [conflict]}} =
               Scheduling.assign(scope, %{user_id: user.id, period: overlap, kind: "shoot"})

      assert conflict.job_id == job.id
    end

    test "back-to-back is not a clash — ranges are half-open", %{
      scope: scope,
      user: user,
      window: {_, ends_at}
    } do
      adjacent = {ends_at, DateTime.add(ends_at, 3600)}
      assert Scheduling.available?(scope, user.id, adjacent)

      assert {:ok, _} =
               Scheduling.assign(scope, %{user_id: user.id, period: adjacent, kind: "edit"})
    end

    test "a soft hold warns but never blocks", %{scope: scope, user: user, window: {starts_at, _}} do
      overlap = {DateTime.add(starts_at, 3600), DateTime.add(starts_at, 2 * 3600)}

      assert {:ok, hold} =
               Scheduling.assign(scope, %{
                 user_id: user.id,
                 period: overlap,
                 kind: "hold",
                 expires_at: DateTime.add(DateTime.utc_now(), 86_400)
               })

      assert hold.kind == "hold"
      assert Enum.any?(Scheduling.clashes_for(scope, user.id, overlap), &(&1.kind == "hold"))
    end

    test "a hold must expire", %{scope: scope, user: user} do
      window = future_window(500)

      assert {:error, %Ecto.Changeset{}} =
               Scheduling.assign(scope, %{user_id: user.id, period: window, kind: "hold"})
    end
  end

  describe "concurrency" do
    test "exactly one of eight simultaneous bookings wins", %{scope: scope, user: user} do
      period = future_window(200)

      results =
        1..8
        |> Task.async_stream(
          fn _ ->
            Scheduling.assign(scope, %{user_id: user.id, period: period, kind: "shoot"})
          end,
          max_concurrency: 8,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, {:clash, _}}, &1)) == 7
    end

    test "only one client can take a booking slot", %{scope: scope} do
      {starts_at, ends_at} = future_window(300)

      {:ok, slot} =
        Repo.insert(
          AperDesk.Scheduling.BookingSlot.changeset(%AperDesk.Scheduling.BookingSlot{}, %{
            studio_id: scope.studio.id,
            starts_at: starts_at,
            ends_at: ends_at
          })
        )

      results =
        1..6
        |> Task.async_stream(
          fn i -> Scheduling.book_slot(slot.id, "client#{i}@example.com") end,
          max_concurrency: 6,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :slot_taken})) == 5
    end
  end

  describe "cancelling" do
    test "releases the crew so the date frees up", %{scope: scope, user: user} do
      {starts_at, ends_at} = future_window(400)

      {:ok, job} =
        Scheduling.create_job(
          scope,
          %{"title" => "Wedding", "starts_at" => starts_at, "ends_at" => ends_at},
          [%{user_id: user.id}]
        )

      refute Scheduling.available?(scope, user.id, {starts_at, ends_at})
      assert {:ok, _} = Scheduling.cancel_job(scope, job.id, "client postponed")
      assert Scheduling.available?(scope, user.id, {starts_at, ends_at})
    end
  end
end
