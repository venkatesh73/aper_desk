defmodule AperDesk.Repo.Migrations.AddStudioSetup do
  use Ecto.Migration

  @moduledoc """
  Display preferences, and a record of whether the studio has been set up.

  `setup_completed_at` is deliberately separate from `onboarding_state`. The
  latter tracks product adoption — inbox connected, packages added, first lead —
  which is a different question from "has this studio told us its currency and
  time zone". Conflating them would let a studio that added a package skip being
  asked, and then quote in the wrong currency.

  The formats have defaults because every existing studio needs a sensible
  answer immediately; the setup screen exists to confirm them, not to leave the
  app unusable until someone does.
  """

  def change do
    alter table(:studios) do
      # 10/09/2026 vs 09/10/2026 is the difference between a shoot next week and
      # one last month, so this is not cosmetic.
      add :date_format, :string, null: false, default: "dmy"
      add :time_format, :string, null: false, default: "24h"
      add :week_starts_on, :string, null: false, default: "monday"
      add :setup_completed_at, :utc_datetime_usec
    end

    create constraint(:studios, :studios_date_format_is_known,
             check: "date_format IN ('dmy','mdy','iso','long')"
           )

    create constraint(:studios, :studios_time_format_is_known,
             check: "time_format IN ('12h','24h')"
           )

    create constraint(:studios, :studios_week_start_is_known,
             check: "week_starts_on IN ('monday','sunday')"
           )
  end
end
