defmodule AperDesk.Repo.Migrations.AddObanJobsTable do
  use Ecto.Migration

  @moduledoc """
  The table Oban has needed since it went into `mix.exs`.

  `config.exs` has scheduled six workers on a crontab since the first commit,
  none of which could ever have run: there was no queue table, and Oban was not
  in the supervision tree. Everything that was meant to happen in the
  background — draining the outbox, expiring galleries, chasing invoices,
  reconciling usage — simply did not.
  """

  # Pinned rather than left to float: a later Oban release adding a version
  # would otherwise change what this migration does depending on when it runs.
  def up, do: Oban.Migration.up(version: 14)

  # Rolling all the way back drops the queue, which takes any unrun job with
  # it. Version 1 rather than 0 keeps the table and its data.
  def down, do: Oban.Migration.down(version: 1)
end
