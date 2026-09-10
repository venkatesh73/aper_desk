defmodule AperDesk.BillingTest do
  use AperDesk.DataCase, async: false

  import AperDesk.Fixtures

  alias AperDesk.Billing
  alias AperDesk.Billing.Plan

  describe "handle_webhook/5" do
    test "applies the change exactly once, however many times it is delivered" do
      counter = :counters.new(1, [])

      handler = fn _repo ->
        :counters.add(counter, 1, 1)
        {:ok, :applied}
      end

      event_id = "evt_#{System.unique_integer([:positive])}"

      assert {:ok, :applied} =
               Billing.handle_webhook("stripe", event_id, "invoice.paid", %{}, handler)

      assert {:ok, :already_processed} =
               Billing.handle_webhook("stripe", event_id, "invoice.paid", %{}, handler)

      assert :counters.get(counter, 1) == 1
    end

    test "a failing handler rolls the event record back, so a retry can work" do
      event_id = "evt_#{System.unique_integer([:positive])}"
      failing = fn _repo -> {:error, :boom} end

      assert {:error, :boom} = Billing.handle_webhook("stripe", event_id, "x", %{}, failing)

      # The event was not recorded, so a redelivery is free to try again.
      succeeding = fn _repo -> {:ok, :applied} end
      assert {:ok, :applied} = Billing.handle_webhook("stripe", event_id, "x", %{}, succeeding)
    end
  end

  describe "plan versions" do
    test "publishing a new version does not reprice existing subscriptions" do
      %{scope: scope, studio: studio} = studio_fixture()
      key = unique("plan")
      original = plan_fixture(studio, key: key, name: "Pro")

      {:ok, v2} = Billing.publish_plan_version(key, %{monthly_price_cents: 9999})

      assert v2.version == 2
      assert v2.monthly_price_cents == 9999
      assert Billing.get_subscription(scope).plan_id == original.id
      assert Billing.current_plan(key).version == 2
    end
  end

  describe "change_plan/2" do
    test "refuses a downgrade the studio is already over" do
      %{scope: scope, studio: studio} = studio_fixture()
      plan_fixture(studio, limits: %{"active_leads" => 100})
      for i <- 1..3, do: lead_fixture(scope, %{"title" => "Lead #{i}"})

      tiny_key = unique("tiny")

      Repo.insert!(
        Plan.changeset(%Plan{}, %{
          key: tiny_key,
          name: "Tiny",
          monthly_price_cents: 100,
          yearly_price_cents: 1000,
          currency: "USD",
          limits: %{"active_leads" => 1}
        })
      )

      assert {:error, {:over_limit_for_plan, "active_leads", 3, 1}} =
               Billing.change_plan(scope, tiny_key)
    end
  end

  describe "reconcile" do
    test "recomputes counters from the underlying rows" do
      %{scope: scope, studio: studio} = studio_fixture()
      plan_fixture(studio)
      for i <- 1..3, do: lead_fixture(scope, %{"title" => "Lead #{i}"})

      # Corrupt the counter the way a bypassed trigger would.
      Repo.update_all(
        from(u in AperDesk.Billing.StudioUsage, where: u.studio_id == ^studio.id),
        set: [active_leads: 99]
      )

      assert {:ok, usage} = Billing.reconcile_usage(studio.id)
      assert usage.active_leads == 3
      assert usage.reconciled_at
    end
  end
end
