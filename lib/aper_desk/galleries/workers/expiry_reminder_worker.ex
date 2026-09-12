defmodule AperDesk.Galleries.Workers.ExpiryReminderWorker do
  @moduledoc """
  Tells a studio that a client's gallery is about to close.

  Seven days' notice, once. A gallery closing is the one deadline in the
  product the client cannot see coming and the studio can still do something
  about — extending the window is a single click, but only if somebody knows
  to make it.

  The notice is emitted as an event rather than sent from here, so it goes
  through the same outbox as everything else.

  Told once, and once only. The gallery is claimed with a conditional UPDATE on
  `expiry_notice_sent_at` before the event is written, so two runs of this
  worker — or an overlapping retry — cannot both notify. `outbox_events` could
  not do that job: it has no unique index to conflict on, and a blanket one
  would be wrong, because an invoice reminder is *meant* to fire repeatedly for
  the same subject.
  """

  use Oban.Worker, queue: :galleries, max_attempts: 3

  import Ecto.Query

  alias AperDesk.Automation.OutboxEvent
  alias AperDesk.Galleries.Gallery
  alias AperDesk.Repo

  @notice_days 7

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: {:ok, %{notified: notify()}}

  def notify(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, @notice_days * 24 * 60 * 60, :second)

    Gallery
    |> where([g], g.status == "delivered" and is_nil(g.archived_at))
    |> where([g], not is_nil(g.expires_at) and g.expires_at > ^now and g.expires_at <= ^cutoff)
    |> where([g], is_nil(g.expiry_notice_sent_at))
    |> Repo.all()
    |> Enum.count(&claim_and_emit(&1, now))
  end

  defp claim_and_emit(gallery, now) do
    {count, _} =
      Repo.update_all(
        from(g in Gallery, where: g.id == ^gallery.id and is_nil(g.expiry_notice_sent_at)),
        set: [expiry_notice_sent_at: now, updated_at: now]
      )

    if count == 1 do
      gallery.studio_id
      |> OutboxEvent.new(
        "gallery.expiring",
        gallery,
        %{"expires_at" => gallery.expires_at, "days" => @notice_days},
        occurred_at: now
      )
      |> Repo.insert()

      true
    else
      false
    end
  end
end
