defmodule AperDesk.Repo.Migrations.AddGalleryExpiryNotice do
  use Ecto.Migration

  @moduledoc """
  Records that a studio has been warned a gallery is about to close.

  The reminder worker needs somewhere to mark "told them", and `outbox_events`
  cannot serve: it has no unique index that would make an idempotent insert
  idempotent, and adding a blanket one would be wrong — an invoice reminder is
  *meant* to fire on day 1, 7 and 14 for the same subject.

  So the flag lives on the gallery, and the worker claims it with a conditional
  UPDATE, exactly as the invoice chaser does.
  """

  def change do
    alter table(:galleries) do
      add :expiry_notice_sent_at, :utc_datetime_usec
    end
  end
end
