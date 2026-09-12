defmodule AperDesk.SeatLimitTest do
  @moduledoc """
  Seats are the one plan limit that was counted and never enforced.

  Every other resource claims headroom under a row lock in the same
  transaction as its insert. Accepting an invitation did not, so a studio on a
  one-seat plan could grow to any size and only find out from the settings
  screen — which was itself reading a counter no trigger maintained until
  recently.
  """
  use AperDesk.DataCase, async: false

  import AperDesk.Fixtures
  import Ecto.Query

  alias AperDesk.{Accounts, Repo}

  defp studio_with_seats(seats) do
    %{studio: studio, scope: scope} = studio_fixture()
    plan_fixture(studio, limits: seat_limits(seats))
    %{studio: studio, scope: scope}
  end

  defp seat_limits(seats) do
    %{
      "seats" => seats,
      "active_leads" => 1000,
      "active_galleries" => 100,
      "storage_bytes" => 107_374_182_400,
      "gallery_window_days" => 180,
      "packages" => 50,
      "forms" => 20,
      "workflows" => 50
    }
  end

  defp candidate(name) do
    {:ok, user} =
      Accounts.register_user(%{
        "name" => name,
        "email" => "#{String.downcase(name)}-#{System.unique_integer([:positive])}@example.com",
        "password" => "a sufficiently long passphrase"
      })

    user
  end

  test "a studio with a free seat lets the next person in" do
    %{studio: studio, scope: scope} = studio_with_seats(2)

    {:ok, token, _} =
      Accounts.invite_member(scope, %{"email" => "a@example.com", "role" => "ops"})

    assert {:ok, membership} = Accounts.accept_invitation(token, candidate("Ada"))
    assert membership.studio_id == studio.id
  end

  test "a full studio refuses, with the numbers to act on" do
    # The owner already occupies the only seat.
    %{scope: scope} = studio_with_seats(1)

    {:ok, token, _} =
      Accounts.invite_member(scope, %{"email" => "a@example.com", "role" => "ops"})

    assert {:error, {:limit_reached, "seats", 1, 1}} =
             Accounts.accept_invitation(token, candidate("Ada"))
  end

  test "a refused acceptance leaves the invitation usable" do
    %{scope: scope} = studio_with_seats(1)

    {:ok, token, invitation} =
      Accounts.invite_member(scope, %{"email" => "a@example.com", "role" => "ops"})

    assert {:error, {:limit_reached, _, _, _}} =
             Accounts.accept_invitation(token, candidate("Ada"))

    # The whole transaction rolls back, so the studio can move up a plan and
    # the same link still works. Spending it would be the worst outcome: the
    # person is out and the invitation is gone.
    assert is_nil(Repo.reload!(invitation).accepted_at)
    assert {:ok, _invitation, _studio} = Accounts.preview_invitation(token)
  end

  test "two people accepting the last seat do not both get in" do
    %{studio: studio, scope: scope} = studio_with_seats(2)

    tokens =
      for index <- 1..6 do
        {:ok, token, _} =
          Accounts.invite_member(scope, %{
            "email" => "person#{index}@example.com",
            "role" => "ops"
          })

        {token, candidate("Person#{index}")}
      end

    results =
      tokens
      |> Task.async_stream(fn {token, user} -> Accounts.accept_invitation(token, user) end,
        max_concurrency: 6
      )
      |> Enum.map(fn {:ok, result} -> result end)

    # One seat free, six racing for it: the row lock decides.
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    seats =
      Repo.one(
        from m in Accounts.Membership,
          where: m.studio_id == ^studio.id and m.status == "active",
          select: count(m.id)
      )

    assert seats == 2
  end

  test "freeing a seat lets the next person in" do
    %{studio: studio, scope: scope} = studio_with_seats(2)

    {:ok, first, _} =
      Accounts.invite_member(scope, %{"email" => "a@example.com", "role" => "ops"})

    {:ok, membership} = Accounts.accept_invitation(first, candidate("Ada"))

    {:ok, second, _} =
      Accounts.invite_member(scope, %{"email" => "b@example.com", "role" => "ops"})

    assert {:error, {:limit_reached, "seats", 2, 2}} =
             Accounts.accept_invitation(second, candidate("Bea"))

    {:ok, _} = Accounts.remove_member(scope, membership.id)

    # Removing marks them `left`, and the seats trigger counts only `active` —
    # so the seat comes back without the history going anywhere.
    assert {:ok, _} = Accounts.accept_invitation(second, candidate("Cat"))
    assert Repo.get!(AperDesk.Billing.StudioUsage, studio.id).seats_used == 2
  end
end
