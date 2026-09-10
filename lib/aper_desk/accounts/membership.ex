defmodule AperDesk.Accounts.Membership do
  @moduledoc """
  A user's seat in a studio, and the role that seat carries.

  This table is why one person can be a `photographer` in someone else's studio
  and the `owner` of their own without holding two accounts.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.{Studio, User}

  @roles ~w(owner photographer finance hr ops)
  @employment_types ~w(staff freelance)
  @statuses ~w(invited active suspended left)

  schema "memberships" do
    belongs_to :user, User
    belongs_to :studio, Studio

    field :role, :string
    field :title, :string
    field :employment_type, :string, default: "staff"
    field :day_rate_cents, :integer
    field :day_rate_currency, :string
    field :contract_ends_on, :date
    field :status, :string, default: "active"
    field :last_active_at, :utc_datetime_usec

    timestamps()
  end

  def roles, do: @roles

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [
      :user_id,
      :studio_id,
      :role,
      :title,
      :employment_type,
      :day_rate_cents,
      :day_rate_currency,
      :contract_ends_on,
      :status
    ])
    |> validate_required([:user_id, :studio_id, :role])
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:employment_type, @employment_types)
    |> validate_inclusion(:status, @statuses)
    |> validate_day_rate()
    |> unique_constraint([:user_id, :studio_id],
      message: "is already a member of this studio"
    )
  end

  # A rate without a currency is not a rate.
  defp validate_day_rate(changeset) do
    case {get_field(changeset, :day_rate_cents), get_field(changeset, :day_rate_currency)} do
      {nil, _} -> changeset
      {_, nil} -> add_error(changeset, :day_rate_currency, "is required when a day rate is set")
      _ -> changeset
    end
  end
end
