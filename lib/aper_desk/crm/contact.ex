defmodule AperDesk.Crm.Contact do
  @moduledoc "A person or company the studio deals with. Reused across leads and jobs."
  use AperDesk.Schema

  alias AperDesk.Accounts.Studio
  alias AperDesk.Crm.Lead

  schema "contacts" do
    belongs_to :studio, Studio

    field :name, :string
    field :partner_name, :string
    field :email, :string
    field :phone, :string
    field :company, :string
    field :preferred_channel, :string, default: "email"
    field :time_zone, :string
    field :locale, :string
    field :currency, :string
    field :notes, :string
    field :address, :map, default: %{}
    field :marketing_opt_in, :boolean, default: false
    field :source, :string
    field :archived_at, :utc_datetime_usec

    has_many :leads, Lead

    timestamps()
  end

  def changeset(contact, attrs) do
    contact
    |> cast(attrs, [
      :studio_id,
      :name,
      :partner_name,
      :email,
      :phone,
      :company,
      :preferred_channel,
      :time_zone,
      :locale,
      :currency,
      :notes,
      :address,
      :marketing_opt_in,
      :source
    ])
    |> validate_required([:studio_id, :name])
    |> update_change(:email, &normalize_email/1)
    |> validate_format(:email, ~r/^[^\s@,;]+@[^\s@,;]+\.[^\s@,;]+$/,
      message: "must be a valid email address"
    )
    |> validate_inclusion(:preferred_channel, ~w(email phone whatsapp sms))
    |> unique_constraint([:studio_id, :email],
      message: "another contact in this studio already uses this address"
    )
    |> foreign_key_constraint(:studio_id)
  end

  defp normalize_email(nil), do: nil

  defp normalize_email(email) do
    case email |> String.trim() |> String.downcase() do
      "" -> nil
      value -> value
    end
  end

  @doc "How the contact is addressed on client-facing documents."
  def display_name(%__MODULE__{name: name, partner_name: nil}), do: name
  def display_name(%__MODULE__{name: name, partner_name: partner}), do: "#{name} & #{partner}"
end
