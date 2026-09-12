defmodule AperDesk.Automation.Workers.OutboxDrainWorker do
  @moduledoc """
  Moves events out of the transactional outbox and into automation runs.

  The outbox exists so that "the lead was created" and "the event describing
  it" commit together or not at all. That guarantee ends the moment the row is
  written — something has to pick it up, and until this worker existed nothing
  did. Every event ever emitted was sitting unprocessed, which meant no
  workflow in the product had ever fired.

  The claiming and fan-out live in `AperDesk.Automation.drain/1`, which already
  does both correctly. This is the schedule, not a second implementation:
  writing the claim again here would be two versions of the one piece of
  concurrency control that matters, and they would eventually disagree.
  """

  use Oban.Worker, queue: :automation, max_attempts: 3

  alias AperDesk.Automation

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    result =
      case Map.get(args, "limit") do
        nil -> Automation.drain()
        limit when is_integer(limit) -> Automation.drain(limit)
        limit when is_binary(limit) -> Automation.drain(String.to_integer(limit))
      end

    {:ok, result}
  end
end
