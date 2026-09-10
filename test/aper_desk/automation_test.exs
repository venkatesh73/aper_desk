defmodule AperDesk.AutomationTest do
  @moduledoc """
  The drain must be safe to retry and safe to run twice at once, because in
  production it will be both. The unique index on (workflow_id, event_id) is
  what guarantees it, and these tests exercise that rather than the happy path.
  """

  use AperDesk.DataCase, async: false

  import AperDesk.Fixtures

  alias AperDesk.Automation
  alias AperDesk.Automation.{AutomationRun, AutomationRunStep, OutboxEvent}
  alias AperDesk.Comms

  setup do
    %{scope: scope, studio: studio} = studio_fixture()
    plan_fixture(studio)

    {:ok, template} =
      Comms.create_template(scope, %{
        "key" => "reply",
        "name" => "Reply",
        "subject" => "Hi {{name}}",
        "body" => "Thanks for getting in touch."
      })

    {:ok, workflow} =
      Automation.create_workflow(scope, %{
        "name" => "Reply to wedding leads",
        "trigger_event" => "lead.created",
        "active" => true,
        "trigger_conditions" => %{"shoot_type" => "wedding"},
        "steps" => [
          %{
            "name" => "Send reply",
            "action" => "send_template",
            "config" => %{"template_id" => template.id}
          }
        ]
      })

    %{scope: scope, workflow: workflow}
  end

  describe "drain/1" do
    test "fires only workflows whose conditions match", %{scope: scope, workflow: workflow} do
      wedding = lead_fixture(scope, %{"title" => "Wedding", "shoot_type" => "wedding"})
      _portrait = lead_fixture(scope, %{"title" => "Portrait", "shoot_type" => "portrait"})

      Automation.drain()

      runs = Repo.all(from r in AutomationRun, where: r.workflow_id == ^workflow.id)
      assert [run] = runs
      assert run.subject_id == wedding.id
    end

    test "materialises the workflow's steps", %{scope: scope, workflow: workflow} do
      lead_fixture(scope)
      Automation.drain()

      [run] = Repo.all(from r in AutomationRun, where: r.workflow_id == ^workflow.id)
      [step] = Repo.all(from s in AutomationRunStep, where: s.run_id == ^run.id)
      assert step.action == "send_template"
      assert step.status == "pending"
    end

    test "re-draining processes nothing", %{scope: scope, workflow: workflow} do
      lead_fixture(scope)
      assert %{runs: 1} = Automation.drain()
      assert %{processed: 0} = Automation.drain()

      assert Repo.aggregate(
               from(r in AutomationRun, where: r.workflow_id == ^workflow.id),
               :count
             ) == 1
    end

    test "concurrent drains cannot double-fire", %{scope: scope, workflow: workflow} do
      lead_fixture(scope)

      1..6
      |> Task.async_stream(fn _ -> Automation.drain() end, max_concurrency: 6, timeout: 30_000)
      |> Stream.run()

      assert Repo.aggregate(
               from(r in AutomationRun, where: r.workflow_id == ^workflow.id),
               :count
             ) == 1

      assert Repo.aggregate(from(e in OutboxEvent, where: is_nil(e.processed_at)), :count) == 0
    end
  end

  describe "approval" do
    test "a parked step shows the message that would be sent", %{scope: scope} do
      lead_fixture(scope)
      Automation.drain()
      [step] = Repo.all(AutomationRunStep)

      {:ok, _} = Automation.request_approval(step, %{"subject" => "Hi Anna", "body" => "Thanks!"})

      assert [waiting] = Automation.awaiting_approval(scope)
      assert waiting.preview["subject"] == "Hi Anna"
      assert waiting.status == "awaiting_approval"
    end

    test "rejecting a step cancels its run", %{scope: scope} do
      lead_fixture(scope)
      Automation.drain()
      [step] = Repo.all(AutomationRunStep)
      {:ok, _} = Automation.request_approval(step, %{})

      assert {:ok, rejected} = Automation.reject_step(scope, step.id)
      assert rejected.status == "rejected"
      assert Repo.get!(AutomationRun, step.run_id).status == "cancelled"
    end
  end

  describe "preview_workflow/3" do
    test "matches history without writing anything", %{scope: scope, workflow: workflow} do
      lead_fixture(scope)
      lead_fixture(scope, %{"title" => "Another wedding"})

      before = Repo.aggregate(AutomationRun, :count)
      matched = Automation.preview_workflow(scope, workflow)

      assert length(matched) == 2
      assert Repo.aggregate(AutomationRun, :count) == before
    end
  end

  describe "workflow validation" do
    test "an active workflow needs at least one step", %{scope: scope} do
      assert {:error, %Ecto.Changeset{}} =
               Automation.create_workflow(scope, %{
                 "name" => "Empty",
                 "trigger_event" => "lead.created",
                 "active" => true
               })
    end

    test "an unknown trigger is rejected", %{scope: scope} do
      assert {:error, %Ecto.Changeset{}} =
               Automation.create_workflow(scope, %{
                 "name" => "X",
                 "trigger_event" => "lead.craeted"
               })
    end
  end
end
