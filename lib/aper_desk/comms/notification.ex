defmodule AperDesk.Comms.Notification do
  @moduledoc """
  An in-app notification for one team member.

  Rows are per-user rather than per-studio-with-a-read-set, so marking one read
  is a single-row update and the unread badge is an index scan rather than a
  join against a membership table on every page load.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.{Studio, User}

  @kinds ~w(lead_assigned lead_overdue job_upcoming job_clash quote_accepted quote_declined
            contract_signed invoice_paid invoice_overdue gallery_expiring gallery_viewed
            approval_required payout_approved plan_limit system)
  @severities ~w(info success warning critical)

  schema "notifications" do
    belongs_to :studio, Studio
    belongs_to :user, User

    field :kind, :string
    field :title, :string
    field :body, :string
    field :path, :string
    field :severity, :string, default: "info"
    field :read_at, :utc_datetime_usec

    timestamps(updated_at: false)
  end

  def kinds, do: @kinds
  def severities, do: @severities

  def changeset(notification, attrs) do
    notification
    |> cast(attrs, [:studio_id, :user_id, :kind, :title, :body, :path, :severity])
    |> validate_required([:studio_id, :user_id, :kind, :title])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:severity, @severities)
    |> foreign_key_constraint(:user_id)
  end

  def read_changeset(notification, at \\ DateTime.utc_now()),
    do: change(notification, read_at: notification.read_at || at)

  def read?(%__MODULE__{read_at: %DateTime{}}), do: true
  def read?(%__MODULE__{}), do: false
end
