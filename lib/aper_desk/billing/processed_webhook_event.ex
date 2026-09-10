defmodule AperDesk.Billing.ProcessedWebhookEvent do
  @moduledoc """
  A record that a provider webhook has already been handled.

  Stripe delivers at-least-once and out of order. Recording the provider's event
  id inside the same transaction that acts on it is the only reliable way to
  stay idempotent: a redelivered `invoice.paid` hits the unique index and is
  discarded instead of crediting the invoice a second time.
  """
  use AperDesk.Schema

  @providers ~w(stripe)

  schema "processed_webhook_events" do
    field :provider, :string
    field :event_id, :string
    field :event_type, :string
    field :processed_at, :utc_datetime_usec
    field :payload, :map

    timestamps(updated_at: false)
  end

  def providers, do: @providers

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:provider, :event_id, :event_type, :processed_at, :payload])
    |> validate_required([:provider, :event_id])
    |> validate_inclusion(:provider, @providers)
    |> put_processed_at()
    |> unique_constraint([:provider, :event_id],
      message: "this webhook has already been processed"
    )
  end

  defp put_processed_at(changeset) do
    case get_field(changeset, :processed_at) do
      nil -> put_change(changeset, :processed_at, DateTime.utc_now())
      _ -> changeset
    end
  end
end
