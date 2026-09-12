defmodule AperDeskWeb.GraphqlRolesTest do
  @moduledoc """
  The mobile client is hit by the same five roles the web UI is.

  A resolver assembles one response from several contexts, so a role that may
  read four of them and not the fifth has to still get an answer. Gating the
  contexts without teaching the resolvers about refusal turned an HR user's
  dashboard query into a 500 — these pin that shut.
  """
  use AperDeskWeb.ConnCase, async: true

  import AperDesk.Fixtures

  alias AperDesk.{Accounts, Repo}
  alias AperDeskWeb.Graphql.Resolvers.{DashboardResolver, MiscResolver}

  setup do
    %{studio: studio, scope: owner_scope} = studio_fixture()
    plan_fixture(studio)
    %{studio: studio, owner_scope: owner_scope}
  end

  defp scope_for(studio, role) do
    {:ok, user} =
      Accounts.register_user(%{
        "name" => "#{role}",
        "email" => "#{role}-#{System.unique_integer([:positive])}@example.com",
        "password" => "a sufficiently long passphrase"
      })

    Repo.insert!(
      Accounts.Membership.changeset(%Accounts.Membership{}, %{
        user_id: user.id,
        studio_id: studio.id,
        role: to_string(role),
        status: "active"
      })
    )

    {:ok, scope} = Accounts.scope_for(user, studio.id)
    scope
  end

  for role <- [:owner, :photographer, :finance, :hr, :ops] do
    test "the dashboard query answers a #{role} instead of crashing", %{
      studio: studio,
      owner_scope: owner_scope
    } do
      # Some real data, so the resolvers touch every context they can.
      {:ok, _} = AperDesk.Crm.create_lead(owner_scope, %{"title" => "A wedding"})

      scope =
        if unquote(role) == :owner, do: owner_scope, else: scope_for(studio, unquote(role))

      assert {:ok, dashboard} =
               DashboardResolver.dashboard(nil, %{role: to_string(unquote(role))}, %{
                 context: %{scope: scope}
               })

      assert is_binary(dashboard.greeting)
      assert is_binary(dashboard.subtitle)
      assert is_list(dashboard.stats)
      assert is_list(dashboard.needs_attention)
    end
  end

  test "a photographer's dashboard counts only their own leads", %{
    studio: studio,
    owner_scope: owner_scope
  } do
    scope = scope_for(studio, :photographer)

    {:ok, _} = AperDesk.Crm.create_lead(owner_scope, %{"title" => "Not theirs"})

    {:ok, _} =
      AperDesk.Crm.create_lead(owner_scope, %{"title" => "Theirs", "owner_id" => scope.user.id})

    {:ok, dashboard} =
      DashboardResolver.dashboard(nil, %{role: "photographer"}, %{context: %{scope: scope}})

    open = Enum.find(dashboard.stats, &(&1.key == "open_leads"))
    assert open.value == "1"
  end

  test "an HR user gets no money on the dashboard", %{studio: studio} do
    scope = scope_for(studio, :hr)

    {:ok, dashboard} =
      DashboardResolver.dashboard(nil, %{role: "hr"}, %{context: %{scope: scope}})

    refute Enum.any?(dashboard.stats, &(&1.key == "outstanding"))
  end

  test "the team query returns the leave and onboarding it promises", %{
    studio: studio,
    owner_scope: owner_scope
  } do
    hr = scope_for(studio, :hr)
    anna = scope_for(studio, :photographer)

    membership =
      Repo.get_by!(AperDesk.Accounts.Membership, user_id: anna.user.id, studio_id: studio.id)

    from = Date.add(Date.utc_today(), 20)

    {:ok, _} =
      AperDesk.People.request_leave(owner_scope, %{
        "user_id" => anna.user.id,
        "starts_on" => from,
        "ends_on" => Date.add(from, 3)
      })

    {:ok, _} = AperDesk.People.start_onboarding(hr, membership.id)

    assert {:ok, team} = MiscResolver.team(nil, %{}, %{context: %{scope: hr}})

    # The Flutter client asks for these by name; returning [] was a lie the
    # schema told.
    assert [request] = team.leave_requests
    assert request.person =~ "photographer"

    assert [row] = team.onboarding
    assert row.tasks != []
  end
end
