defmodule AperDesk.Finance.Workers.InvoiceReminderWorker do
  @moduledoc """
  Chases invoices that are past their due date.

  Chasing money is the job studios put off, so it is the one most worth doing
  without them. The reminder is emitted as an event and sent through the
  outbox, which is also what stops a client being chased twice in a day by two
  runs of this worker.

  `reminders_sent` is incremented in the same statement that selects the
  invoice, so an invoice cannot be picked up again by an overlapping run before
  the first has finished with it.
  """

  use Oban.Worker, queue: :billing, max_attempts: 3

  import Ecto.Query

  alias AperDesk.Automation.OutboxEvent
  alias AperDesk.Finance.Invoice
  alias AperDesk.Repo

  # Day 1, then weekly. A daily chase reads as harassment and gets the sender
  # filtered, which makes the next one worthless too.
  @intervals [1, 7, 14, 21, 28]

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: {:ok, %{reminded: remind()}}

  def remind(today \\ Date.utc_today()) do
    Invoice
    |> where([i], i.status in ^Invoice.outstanding_statuses())
    |> where([i], not is_nil(i.due_on) and i.due_on < ^today)
    |> where([i], i.paid_cents < i.total_cents)
    |> Repo.all()
    |> Enum.filter(&due_a_reminder?(&1, today))
    |> Enum.count(&chase(&1, today))
  end

  defp due_a_reminder?(invoice, today) do
    Date.diff(today, invoice.due_on) in @intervals and
      not reminded_today?(invoice, today)
  end

  defp reminded_today?(%Invoice{last_reminder_at: nil}, _today), do: false

  defp reminded_today?(%Invoice{last_reminder_at: at}, today),
    do: DateTime.to_date(at) == today

  defp chase(invoice, today) do
    now = DateTime.utc_now()

    {count, _} =
      Repo.update_all(
        from(i in Invoice,
          where:
            i.id == ^invoice.id and
              (is_nil(i.last_reminder_at) or fragment("?::date", i.last_reminder_at) < ^today)
        ),
        inc: [reminders_sent: 1],
        set: [last_reminder_at: now, updated_at: now]
      )

    if count == 1 do
      invoice.studio_id
      |> OutboxEvent.new(
        "invoice.reminder_due",
        invoice,
        %{"days_overdue" => Date.diff(today, invoice.due_on)},
        occurred_at: now
      )
      |> Repo.insert(on_conflict: :nothing)

      true
    else
      false
    end
  end
end
