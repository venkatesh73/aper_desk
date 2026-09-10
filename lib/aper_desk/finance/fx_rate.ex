defmodule AperDesk.Finance.FxRate do
  @moduledoc """
  A daily exchange-rate snapshot.

  Rates are stored per day and never overwritten, because an issued invoice
  must always convert with the rate that applied on the day it was issued.
  Re-converting historical documents at today's rate would silently restate
  last quarter's revenue every time this table was refreshed.

  `AperDesk.Money.convert/3` deliberately takes an explicit rate rather than
  looking one up, so the caller has to decide *which* rate applies. This table
  is where that decision reads from.
  """
  use AperDesk.Schema

  @sources ~w(manual ecb openexchange stripe)

  # No updated_at: a rate for a given day is a fact, not a mutable record.
  schema "fx_rates" do
    field :base_currency, :string
    field :quote_currency, :string
    field :rate, :decimal
    field :as_of, :date
    field :source, :string, default: "manual"

    timestamps(updated_at: false)
  end

  def sources, do: @sources

  def changeset(fx_rate, attrs) do
    fx_rate
    |> cast(attrs, [:base_currency, :quote_currency, :rate, :as_of, :source])
    |> validate_required([:base_currency, :quote_currency, :rate, :as_of])
    |> update_change(:base_currency, &String.upcase/1)
    |> update_change(:quote_currency, &String.upcase/1)
    |> validate_inclusion(:source, @sources)
    |> validate_different_currencies()
    |> validate_positive_rate()
    |> unique_constraint([:base_currency, :quote_currency, :as_of],
      message: "a rate for this pair and date already exists"
    )
  end

  defp validate_different_currencies(changeset) do
    if get_field(changeset, :base_currency) == get_field(changeset, :quote_currency) do
      add_error(changeset, :quote_currency, "must differ from the base currency")
    else
      changeset
    end
  end

  # A zero or negative rate would zero out or invert every converted total.
  defp validate_positive_rate(changeset) do
    case get_field(changeset, :rate) do
      %Decimal{} = rate ->
        if Decimal.compare(rate, Decimal.new(0)) == :gt do
          changeset
        else
          add_error(changeset, :rate, "must be greater than zero")
        end

      _ ->
        changeset
    end
  end
end
