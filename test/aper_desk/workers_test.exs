defmodule AperDesk.WorkersTest do
  @moduledoc """
  The six workers the crontab has named since the first commit.

  None of them existed, there was no `oban_jobs` table, and Oban was not in the
  supervision tree — so nothing in this application had ever happened in the
  background. Every event emitted sat unprocessed, no gallery ever expired, no
  invoice was ever chased.

  These run the workers directly rather than through the queue, because what is
  being tested is what each one does, not that Oban can run a job.
  """
  use AperDesk.DataCase, async: false

  import AperDesk.Fixtures
  import Ecto.Query

  alias AperDesk.Automation.OutboxEvent
  alias AperDesk.Automation.Workers.OutboxDrainWorker
  alias AperDesk.Billing.Workers.UsageRollupWorker
  alias AperDesk.Finance.Workers.InvoiceReminderWorker
  alias AperDesk.Galleries.Workers.{ArchiveExpiredWorker, ExpiryReminderWorker}
  alias AperDesk.Repo

  describe "the outbox drain" do
    test "processes events that were sitting unhandled", %{} do
      %{studio: studio, scope: scope} = studio_fixture()
      plan_fixture(studio)

      {:ok, _lead} = AperDesk.Crm.create_lead(scope, %{"title" => "A wedding"})

      unprocessed = fn ->
        Repo.aggregate(from(e in OutboxEvent, where: is_nil(e.processed_at)), :count)
      end

      assert unprocessed.() > 0

      assert {:ok, result} = OutboxDrainWorker.perform(%Oban.Job{args: %{}})
      assert result.processed > 0
      assert unprocessed.() == 0
    end

    test "is safe to run twice", %{} do
      %{studio: studio, scope: scope} = studio_fixture()
      plan_fixture(studio)
      {:ok, _} = AperDesk.Crm.create_lead(scope, %{"title" => "A wedding"})

      {:ok, first} = OutboxDrainWorker.perform(%Oban.Job{args: %{}})
      {:ok, second} = OutboxDrainWorker.perform(%Oban.Job{args: %{}})

      # The second run finds nothing left to claim rather than re-running
      # anything — the conditional UPDATE is the whole guarantee.
      assert first.processed > 0
      assert second.processed == 0
    end
  end

  describe "gallery expiry" do
    setup do
      %{studio: studio, scope: scope} = studio_fixture()
      plan_fixture(studio)
      %{studio: studio, scope: scope}
    end

    test "archives a delivered gallery whose window has closed", %{scope: scope} do
      gallery = gallery_fixture(scope, %{"title" => "Anna and Ben"})
      {:ok, gallery} = AperDesk.Galleries.deliver_gallery(scope, gallery.id)

      # Wind the window back rather than waiting 180 days.
      Repo.update_all(
        from(g in AperDesk.Galleries.Gallery, where: g.id == ^gallery.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -86_400, :second)]
      )

      assert {:ok, result} = ArchiveExpiredWorker.perform(%Oban.Job{})
      assert result.archived == 1

      {:ok, reloaded} = AperDesk.Galleries.fetch_gallery(scope, gallery.id)
      assert reloaded.status == "archived"
      assert reloaded.purge_after
    end

    test "leaves a live gallery alone", %{scope: scope} do
      gallery = gallery_fixture(scope)
      {:ok, _} = AperDesk.Galleries.deliver_gallery(scope, gallery.id)

      assert {:ok, result} = ArchiveExpiredWorker.perform(%Oban.Job{})
      assert result.archived == 0
    end

    test "purges the files once the recovery window has passed too", %{
      scope: scope,
      studio: studio
    } do
      gallery = gallery_fixture(scope)
      {:ok, gallery} = AperDesk.Galleries.deliver_gallery(scope, gallery.id)

      key = AperDesk.Storage.key_for(studio.id, gallery.id, "frame.jpg")
      source = Path.join(System.tmp_dir!(), "purge-#{System.unique_integer([:positive])}.jpg")
      File.write!(source, "bytes")
      {:ok, _} = AperDesk.Storage.put(key, source)
      File.rm(source)

      assert File.exists?(Path.join("tmp/test_uploads", key))

      Repo.update_all(
        from(g in AperDesk.Galleries.Gallery, where: g.id == ^gallery.id),
        set: [
          status: "archived",
          archived_at: DateTime.utc_now(),
          purge_after: DateTime.add(DateTime.utc_now(), -86_400, :second)
        ]
      )

      assert {:ok, result} = ArchiveExpiredWorker.perform(%Oban.Job{})
      assert result.purged == 1

      # Files first, row second: a purged row still pointing at bytes is a
      # studio billed for storage it cannot see.
      refute File.exists?(Path.join("tmp/test_uploads", key))
      assert Repo.get!(AperDesk.Galleries.Gallery, gallery.id).status == "purged"
    end

    test "gives seven days' notice, once", %{scope: scope} do
      gallery = gallery_fixture(scope)
      {:ok, gallery} = AperDesk.Galleries.deliver_gallery(scope, gallery.id)

      Repo.update_all(
        from(g in AperDesk.Galleries.Gallery, where: g.id == ^gallery.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), 3 * 86_400, :second)]
      )

      assert {:ok, %{notified: 1}} = ExpiryReminderWorker.perform(%Oban.Job{})

      # Running again must not tell them twice.
      assert {:ok, %{notified: _}} = ExpiryReminderWorker.perform(%Oban.Job{})

      events =
        Repo.all(from e in OutboxEvent, where: e.name == "gallery.expiring", select: e.subject_id)

      assert events == [gallery.id]
    end
  end

  describe "invoice chasing" do
    test "chases on the first day overdue and not the second", %{} do
      %{studio: studio, scope: scope} = studio_fixture()
      plan_fixture(studio)

      invoice = invoice_fixture(scope, %{"due_on" => Date.add(Date.utc_today(), -1)})
      {:ok, _} = AperDesk.Finance.send_invoice(scope, invoice.id)

      assert InvoiceReminderWorker.remind() == 1

      reloaded = Repo.get!(AperDesk.Finance.Invoice, invoice.id)
      assert reloaded.reminders_sent == 1
      assert reloaded.last_reminder_at

      # A daily chase reads as harassment and gets the sender filtered.
      assert InvoiceReminderWorker.remind() == 0
      assert Repo.get!(AperDesk.Finance.Invoice, invoice.id).reminders_sent == 1
    end

    test "leaves a paid invoice alone", %{} do
      %{studio: studio, scope: scope} = studio_fixture()
      plan_fixture(studio)

      invoice = invoice_fixture(scope, %{"due_on" => Date.add(Date.utc_today(), -1)})
      {:ok, invoice} = AperDesk.Finance.send_invoice(scope, invoice.id)

      {:ok, _} =
        AperDesk.Finance.record_payment(scope, invoice.id, %{
          "amount_cents" => invoice.total_cents,
          "currency" => invoice.currency,
          "method" => "bank_transfer",
          "received_at" => DateTime.utc_now()
        })

      assert InvoiceReminderWorker.remind() == 0
    end
  end

  describe "the nightly rollup" do
    test "corrects a counter that drifted", %{} do
      %{studio: studio, scope: scope} = studio_fixture()
      plan_fixture(studio)
      {:ok, _} = AperDesk.Crm.create_lead(scope, %{"title" => "A wedding"})

      # A bulk import bypassing triggers is exactly the case this exists for.
      Repo.update_all(
        from(u in AperDesk.Billing.StudioUsage, where: u.studio_id == ^studio.id),
        set: [active_leads: 99]
      )

      assert {:ok, result} = UsageRollupWorker.perform(%Oban.Job{})
      assert result.studios >= 1

      assert Repo.get!(AperDesk.Billing.StudioUsage, studio.id).active_leads == 1
    end

    test "expires a quote nobody answered", %{} do
      %{studio: studio, scope: scope} = studio_fixture()
      plan_fixture(studio)

      {:ok, quote} =
        AperDesk.Sales.create_quote(scope, %{
          "title" => "A wedding",
          "currency" => "USD",
          "valid_until" => Date.add(Date.utc_today(), -1)
        })

      {:ok, _, _token} = AperDesk.Sales.send_quote(scope, quote.id)

      assert {:ok, result} = UsageRollupWorker.perform(%Oban.Job{})
      assert result.quotes_expired >= 1

      {:ok, reloaded} = AperDesk.Sales.fetch_quote(scope, quote.id)
      assert reloaded.status == "expired"
    end
  end

  test "every worker the crontab names is loadable and answers perform/1" do
    crontab =
      :aper_desk
      |> Application.fetch_env!(Oban)
      |> Keyword.fetch!(:plugins)
      |> Enum.find_value(fn
        {Oban.Plugins.Cron, opts} -> opts[:crontab]
        _ -> nil
      end)

    assert length(crontab) == 6

    for {_expression, worker} <- crontab do
      assert Code.ensure_loaded?(worker), "#{inspect(worker)} does not exist"

      assert function_exported?(worker, :perform, 1),
             "#{inspect(worker)} is not an Oban worker"

      # A crontab naming a module that raises on an empty database is a job
      # that fails silently every night.
      assert {:ok, _result} = worker.perform(%Oban.Job{args: %{}})
    end
  end
end
