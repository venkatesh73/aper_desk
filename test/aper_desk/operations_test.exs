defmodule AperDesk.OperationsTest do
  use AperDesk.DataCase, async: false

  import AperDesk.Fixtures

  alias AperDesk.{Accounts, Operations, Repo}

  setup do
    %{studio: studio, scope: owner} = studio_fixture()
    plan_fixture(studio)
    ops = member(studio, "Mira", "ops")
    photog = member(studio, "Anna", "photographer")
    {:ok, body} = Operations.create_gear(owner, %{"name" => "A7 IV #1", "category" => "body"})
    %{studio: studio, owner: owner, ops: ops, photog: photog, body: body}
  end

  defp member(studio, name, role) do
    {:ok, user} =
      Accounts.register_user(%{
        "name" => name,
        "email" => "#{String.downcase(name)}-#{System.unique_integer([:positive])}@example.com",
        "password" => "a sufficiently long passphrase"
      })

    Repo.insert!(
      Accounts.Membership.changeset(%Accounts.Membership{}, %{
        user_id: user.id,
        studio_id: studio.id,
        role: role,
        status: "active"
      })
    )

    {:ok, scope} = Accounts.scope_for(user, studio.id)
    %{user: user, scope: scope}
  end

  describe "checking kit out" do
    test "one item is in one pair of hands", %{ops: ops, photog: photog, body: body} do
      assert {:ok, _} = Operations.check_out(ops.scope, body.id, %{"user_id" => photog.user.id})

      # A status column would need the application to keep it in step; the
      # index settles it instead.
      assert {:error, :already_out} = Operations.check_out(ops.scope, body.id)
    end

    test "two simultaneous checkouts do not both win", %{studio: studio, body: body, ops: ops} do
      # The database is the only thing that can decide this.
      results =
        1..6
        |> Task.async_stream(
          fn _ ->
            {:ok, scope} = Accounts.scope_for(ops.user, studio.id)
            Operations.check_out(scope, body.id)
          end,
          max_concurrency: 6
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :already_out})) == 5
    end

    test "returning it frees the item", %{ops: ops, body: body} do
      {:ok, checkout} = Operations.check_out(ops.scope, body.id)

      assert {:ok, [_]} = Operations.checked_out(ops.scope)
      assert {:ok, []} = Operations.available_gear(ops.scope)

      assert {:ok, _} = Operations.check_in(ops.scope, checkout.id, "Lens cap missing")
      assert {:ok, []} = Operations.checked_out(ops.scope)
      assert {:ok, [^body]} = Operations.available_gear(ops.scope)
    end

    test "returning twice is refused", %{ops: ops, body: body} do
      {:ok, checkout} = Operations.check_out(ops.scope, body.id)
      {:ok, _} = Operations.check_in(ops.scope, checkout.id)

      assert {:error, :already_returned} = Operations.check_in(ops.scope, checkout.id)
    end
  end

  describe "overdue" do
    test "is out and past the day it was promised", %{ops: ops, body: body} do
      yesterday = Date.add(Date.utc_today(), -1)
      {:ok, _} = Operations.check_out(ops.scope, body.id, %{"due_back_on" => yesterday})

      assert {:ok, [overdue]} = Operations.overdue_gear(ops.scope)
      assert overdue.gear_item.name == "A7 IV #1"
    end

    test "kit with no due date is never overdue", %{ops: ops, body: body} do
      {:ok, _} = Operations.check_out(ops.scope, body.id)
      assert {:ok, []} = Operations.overdue_gear(ops.scope)
    end
  end

  describe "who may touch it" do
    test "a photographer can see the kit but not move it", %{photog: photog, body: body} do
      assert {:ok, [_]} = Operations.list_gear(photog.scope)

      # Knowing what the studio owns is not the same as signing it out.
      assert {:error, :unauthorized} = Operations.check_out(photog.scope, body.id)
      assert {:error, :unauthorized} = Operations.create_gear(photog.scope, %{"name" => "Mine"})
    end

    test "finance has no business here at all", %{studio: studio} do
      finance = member(studio, "Daniel", "finance")
      assert {:error, :unauthorized} = Operations.list_gear(finance.scope)
    end
  end

  describe "retiring" do
    test "keeps past checkouts pointing at something", %{ops: ops, body: body} do
      {:ok, checkout} = Operations.check_out(ops.scope, body.id)
      {:ok, _} = Operations.check_in(ops.scope, checkout.id)
      {:ok, _} = Operations.retire_gear(ops.scope, body.id)

      assert {:ok, []} = Operations.list_gear(ops.scope)
      assert {:ok, [_]} = Operations.list_gear(ops.scope, include_retired: true)
    end
  end
end
