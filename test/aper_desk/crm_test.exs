defmodule AperDesk.CrmTest do
  @moduledoc """
  Covers the two guarantees the CRM is responsible for: a lead and its domain
  event commit together, and the plan's lead cap holds under concurrency.
  """

  use AperDesk.DataCase, async: false

  import AperDesk.Fixtures

  alias AperDesk.Automation.OutboxEvent
  alias AperDesk.Billing.StudioUsage
  alias AperDesk.Crm

  describe "create_lead/2" do
    setup do
      %{scope: scope, studio: studio} = studio_fixture()
      plan_fixture(studio)
      %{scope: scope, studio: studio}
    end

    test "writes the outbox event in the same transaction", %{scope: scope} do
      lead = lead_fixture(scope)

      events = Repo.all(from e in OutboxEvent, where: e.subject_id == ^lead.id)
      assert [event] = events
      assert event.name == "lead.created"
      assert event.payload["shoot_type"] == "wedding"
    end

    test "a rejected lead leaves no orphan event", %{scope: scope} do
      before = Repo.aggregate(OutboxEvent, :count)
      assert {:error, %Ecto.Changeset{}} = Crm.create_lead(scope, %{"title" => nil})
      assert Repo.aggregate(OutboxEvent, :count) == before
    end

    test "validates custom fields against their definitions", %{scope: scope} do
      {:ok, _} =
        Crm.create_custom_field(scope, %{
          "key" => "venue_postcode",
          "label" => "Venue postcode",
          "field_type" => "text",
          "required" => true
        })

      assert {:error, {:invalid_custom_fields, errors}} =
               Crm.create_lead(scope, %{"title" => "X", "custom_fields" => %{}})

      assert {"venue_postcode", "is required"} in errors

      assert {:ok, lead} =
               Crm.create_lead(scope, %{
                 "title" => "X",
                 "custom_fields" => %{"venue_postcode" => "8001", "junk" => "dropped"}
               })

      assert lead.custom_fields == %{"venue_postcode" => "8001"}
    end
  end

  describe "plan limits" do
    setup do
      %{scope: scope, studio: studio} = studio_fixture()
      plan_fixture(studio, limits: %{"active_leads" => 3})
      %{scope: scope, studio: studio}
    end

    test "refuse the lead that would exceed the cap", %{scope: scope} do
      for i <- 1..3, do: lead_fixture(scope, %{"title" => "Lead #{i}"})

      assert {:error, {:limit_reached, "active_leads", 3, 3}} =
               Crm.create_lead(scope, %{"title" => "One too many"})
    end

    test "a lost lead frees a slot", %{scope: scope, studio: studio} do
      lead = lead_fixture(scope)
      for i <- 2..3, do: lead_fixture(scope, %{"title" => "Lead #{i}"})

      assert {:error, {:limit_reached, _, _, _}} = Crm.create_lead(scope, %{"title" => "Blocked"})
      assert {:ok, _} = Crm.move_lead(scope, lead.id, "lost", %{lost_reason: "budget"})
      assert Repo.get!(StudioUsage, studio.id).active_leads == 2
      assert {:ok, _} = Crm.create_lead(scope, %{"title" => "Now fits"})
    end

    test "concurrent creates cannot both take the last slot", %{scope: scope, studio: studio} do
      for i <- 1..2, do: lead_fixture(scope, %{"title" => "Lead #{i}"})

      results =
        1..6
        |> Task.async_stream(
          fn i -> Crm.create_lead(scope, %{"title" => "race #{i}"}) end,
          max_concurrency: 6,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, {:limit_reached, _, _, _}}, &1)) == 5
      assert Repo.get!(StudioUsage, studio.id).active_leads == 3
    end
  end

  describe "upsert_contact/2" do
    test "reuses an existing contact rather than duplicating it" do
      %{scope: scope, studio: studio} = studio_fixture()
      plan_fixture(studio)

      {:ok, first} = Crm.upsert_contact(scope, %{"name" => "Anna", "email" => "anna@example.com"})

      {:ok, second} =
        Crm.upsert_contact(scope, %{"name" => "Anna B", "email" => "anna@example.com"})

      assert first.id == second.id
    end
  end

  describe "move_lead/4" do
    test "emits a stage-specific event so workflows can target winning" do
      %{scope: scope, studio: studio} = studio_fixture()
      plan_fixture(studio)
      lead = lead_fixture(scope)

      {:ok, _} = Crm.move_lead(scope, lead.id, "booked")

      names =
        Repo.all(from e in OutboxEvent, where: e.subject_id == ^lead.id, select: e.name)

      assert "lead.won" in names
    end

    test "losing a lead requires a reason" do
      %{scope: scope, studio: studio} = studio_fixture()
      plan_fixture(studio)
      lead = lead_fixture(scope)

      assert {:error, %Ecto.Changeset{}} = Crm.move_lead(scope, lead.id, "lost")
    end
  end
end
