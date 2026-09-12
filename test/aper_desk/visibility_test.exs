defmodule AperDesk.VisibilityTest do
  @moduledoc """
  A photographer sees their own work, not the studio's.

  `Authorization` said so in prose and the code did not do it: a photographer
  holding `lead.read` saw every lead in the studio. These tests are written
  against two photographers so that "sees their own" and "does not see the
  other one's" are the same assertion from both sides — a filter that
  accidentally matched everything would pass a one-photographer test.
  """
  use AperDesk.DataCase, async: true

  import AperDesk.Fixtures

  alias AperDesk.{Accounts, Crm, Galleries, Repo, Scheduling, Visibility}

  setup do
    %{user: owner, studio: studio, scope: owner_scope} = studio_fixture()
    plan_fixture(studio)

    anna = photographer(studio, "Anna")
    ben = photographer(studio, "Ben")

    %{studio: studio, owner: owner, owner_scope: owner_scope, anna: anna, ben: ben}
  end

  defp photographer(studio, name) do
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
        role: "photographer",
        status: "active"
      })
    )

    {:ok, scope} = Accounts.scope_for(user, studio.id)
    %{user: user, scope: scope}
  end

  describe "leads" do
    test "a photographer sees the ones they own and no others", %{
      owner_scope: owner_scope,
      anna: anna,
      ben: ben
    } do
      {:ok, _} =
        Crm.create_lead(owner_scope, %{"title" => "ANNA LEAD", "owner_id" => anna.user.id})

      {:ok, _} = Crm.create_lead(owner_scope, %{"title" => "BEN LEAD", "owner_id" => ben.user.id})
      {:ok, _} = Crm.create_lead(owner_scope, %{"title" => "NOBODY LEAD"})

      assert {:ok, annas} = Crm.list_leads(anna.scope)
      assert Enum.map(annas, & &1.title) == ["ANNA LEAD"]

      assert {:ok, bens} = Crm.list_leads(ben.scope)
      assert Enum.map(bens, & &1.title) == ["BEN LEAD"]

      # The owner still sees the studio's whole pipeline.
      assert {:ok, all} = Crm.list_leads(owner_scope)
      assert length(all) == 3
    end

    test "fetching somebody else's lead is refused, not reported missing", %{
      owner_scope: owner_scope,
      anna: anna,
      ben: ben
    } do
      {:ok, bens} =
        Crm.create_lead(owner_scope, %{"title" => "BEN LEAD", "owner_id" => ben.user.id})

      # Both answers end the request; only one of them is true.
      assert {:error, :unauthorized} = Crm.fetch_lead(anna.scope, bens.id)
      assert {:ok, _} = Crm.fetch_lead(ben.scope, bens.id)
    end

    test "the counts a dashboard reads are narrowed too", %{
      owner_scope: owner_scope,
      anna: anna,
      ben: ben
    } do
      {:ok, _} = Crm.create_lead(owner_scope, %{"title" => "A", "owner_id" => anna.user.id})
      {:ok, _} = Crm.create_lead(owner_scope, %{"title" => "B1", "owner_id" => ben.user.id})
      {:ok, _} = Crm.create_lead(owner_scope, %{"title" => "B2", "owner_id" => ben.user.id})

      # Narrowing the list but not the summary would leak the shape of the
      # pipeline while hiding its contents.
      assert Crm.pipeline_summary(anna.scope) |> Map.values() |> Enum.sum() == 1
      assert Crm.pipeline_summary(ben.scope) |> Map.values() |> Enum.sum() == 2
      assert Crm.pipeline_summary(owner_scope) |> Map.values() |> Enum.sum() == 3
    end
  end

  describe "shoots" do
    test "a photographer sees the ones they are crewed on", %{
      owner_scope: owner_scope,
      anna: anna,
      ben: ben
    } do
      job_fixture(owner_scope, %{"title" => "ANNA SHOOT"}, [%{user_id: anna.user.id}])
      job_fixture(owner_scope, %{"title" => "BEN SHOOT"}, [%{user_id: ben.user.id}])
      job_fixture(owner_scope, %{"title" => "UNCREWED"})

      assert {:ok, annas} = Scheduling.list_jobs(anna.scope)
      assert Enum.map(annas, & &1.title) == ["ANNA SHOOT"]

      assert {:ok, all} = Scheduling.list_jobs(owner_scope)
      assert length(all) == 3
    end

    test "being taken off a shoot takes the shoot with it", %{
      owner_scope: owner_scope,
      anna: anna
    } do
      job = job_fixture(owner_scope, %{"title" => "ANNA SHOOT"}, [%{user_id: anna.user.id}])

      assert {:ok, [_]} = Scheduling.list_jobs(anna.scope)

      {:ok, assignments} = Scheduling.calendar(owner_scope, {job.starts_at, job.ends_at})
      assignment = Enum.find(assignments, &(&1.user_id == anna.user.id))
      {:ok, _} = Scheduling.release(owner_scope, assignment.id)

      # Removing someone from a shoot is how a studio takes it off them; a
      # released row still granting sight of it would defeat that.
      assert {:ok, []} = Scheduling.list_jobs(anna.scope)
      assert {:error, :unauthorized} = Scheduling.fetch_job(anna.scope, job.id)
    end
  end

  describe "galleries" do
    test "a photographer sees the ones from shoots they covered", %{
      owner_scope: owner_scope,
      anna: anna,
      ben: ben
    } do
      job = job_fixture(owner_scope, %{"title" => "ANNA SHOOT"}, [%{user_id: anna.user.id}])
      gallery_fixture(owner_scope, %{"title" => "FROM ANNAS SHOOT", "job_id" => job.id})
      gallery_fixture(owner_scope, %{"title" => "OWNED BY BEN", "owner_id" => ben.user.id})
      gallery_fixture(owner_scope, %{"title" => "NOBODYS"})

      assert {:ok, annas} = Galleries.list_galleries(anna.scope)
      assert Enum.map(annas, & &1.title) == ["FROM ANNAS SHOOT"]

      assert {:ok, bens} = Galleries.list_galleries(ben.scope)
      assert Enum.map(bens, & &1.title) == ["OWNED BY BEN"]

      assert {:ok, all} = Galleries.list_galleries(owner_scope)
      assert length(all) == 3
    end
  end

  describe "what is deliberately not narrowed" do
    test "contacts stay studio-wide", %{owner_scope: owner_scope, anna: anna} do
      contact_fixture(owner_scope, %{"name" => "Somebody Elses Client"})

      # A photographer needs the phone number of a client whose lead belongs to
      # someone else. A directory nobody can search is worse than useless.
      assert {:ok, [_]} = Crm.list_contacts(anna.scope)
    end

    test "the other roles see the studio, not a slice of it", %{
      studio: studio,
      owner_scope: owner_scope
    } do
      {:ok, _} = Crm.create_lead(owner_scope, %{"title" => "Somebody's lead"})

      for role <- [:finance, :ops] do
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

        refute Visibility.own_work_only?(scope)
        assert {:ok, [_]} = Crm.list_leads(scope)
      end
    end
  end
end
