defmodule AperDesk.Accounts.Registration do
  @moduledoc """
  The sign-up form.

  Registration writes to two tables — a user and the studio they will own — so
  there is no single schema whose changeset the form can bind to. Without this,
  the controller would receive back either a `User` or a `Studio` changeset
  depending on which insert failed, and would have to guess which form field a
  `:name` error belonged to.

  An embedded schema gives the form one changeset with the field names the form
  actually uses, and `AperDesk.Accounts.register_studio/1` maps database-level
  failures (a taken email, a taken slug) back onto it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field :name, :string
    field :email, :string
    field :password, :string, redact: true
    field :studio_name, :string
    field :time_zone, :string, default: "Etc/UTC"
    field :base_currency, :string, default: "USD"
  end

  @doc "Validates the form. Mirrors the rules on `User` and `Studio`."
  def changeset(registration \\ %__MODULE__{}, attrs) do
    registration
    |> cast(attrs, [:name, :email, :password, :studio_name, :time_zone, :base_currency])
    |> validate_required([:name, :email, :password, :studio_name])
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> validate_format(:email, ~r/^[^\s@,;]+@[^\s@,;]+\.[^\s@,;]+$/,
      message: "must be a valid email address"
    )
    |> validate_length(:email, max: 160)
    # 12 characters and no composition rules, matching `User`: length beats
    # forced symbols, and the two must not disagree or the form would accept
    # something the insert then rejects.
    |> validate_length(:password, min: 12, max: 200)
    |> validate_length(:name, min: 2, max: 120)
    |> validate_length(:studio_name, min: 2, max: 120)
    |> validate_inclusion(:base_currency, AperDesk.Money.supported_currencies())
    |> validate_time_zone()
  end

  @doc "Attributes for `AperDesk.Accounts.User.registration_changeset/2`."
  def user_attrs(%Ecto.Changeset{} = changeset) do
    %{
      name: get_field(changeset, :name),
      email: get_field(changeset, :email),
      password: get_field(changeset, :password),
      time_zone: get_field(changeset, :time_zone)
    }
  end

  @doc "Attributes for `AperDesk.Accounts.Studio.changeset/2`."
  def studio_attrs(%Ecto.Changeset{} = changeset) do
    %{
      name: get_field(changeset, :studio_name),
      time_zone: get_field(changeset, :time_zone),
      base_currency: get_field(changeset, :base_currency)
    }
  end

  defp validate_time_zone(changeset) do
    validate_change(changeset, :time_zone, fn :time_zone, zone ->
      case DateTime.now(zone) do
        {:ok, _} -> []
        _ -> [time_zone: "is not a known time zone"]
      end
    end)
  end
end
