defmodule AperDesk.Repo.Migrations.AddLeadNotes do
  @moduledoc """
  Somewhere for what the client actually wrote.

  A lead had no free-text column. `custom_fields` looks like one and is not:
  it is validated against the studio's own field definitions and anything
  undefined is dropped, so a booking's "anything we should know?" answer went
  in and came back out as `{}` — collected from the client and silently thrown
  away, which is worse than never asking.
  """
  use Ecto.Migration

  def change do
    alter table(:leads) do
      add :notes, :text
    end
  end
end
