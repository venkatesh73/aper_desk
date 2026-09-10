defmodule AperDesk.Accounts.User do
  @moduledoc "A person. Identity is global; what they can do is per-studio."
  use AperDesk.Schema

  alias AperDesk.Accounts.Membership

  schema "users" do
    field :email, :string
    field :name, :string
    field :avatar_url, :string
    field :phone, :string
    field :locale, :string, default: "en"
    field :time_zone, :string, default: "Etc/UTC"
    field :confirmed_at, :utc_datetime_usec
    field :platform_admin, :boolean, default: false

    field :hashed_password, :string, redact: true
    field :password, :string, virtual: true, redact: true
    field :password_confirmation, :string, virtual: true, redact: true

    has_many :memberships, Membership

    timestamps()
  end

  @doc "Registration: email, name and a password that must survive the checks below."
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :password, :password_confirmation, :time_zone, :locale])
    |> validate_required([:email, :name, :password])
    |> validate_email()
    |> validate_password()
    |> put_password_hash()
  end

  @doc "Profile edits. Deliberately cannot touch email, password or admin flag."
  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :phone, :avatar_url, :time_zone, :locale])
    |> validate_required([:name])
  end

  def email_changeset(user, attrs) do
    user
    |> cast(attrs, [:email])
    |> validate_required([:email])
    |> validate_email()
    |> put_change(:confirmed_at, nil)
  end

  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password, :password_confirmation])
    |> validate_required([:password])
    |> validate_password()
    |> put_password_hash()
  end

  def confirm_changeset(user) do
    change(user, confirmed_at: DateTime.utc_now())
  end

  @doc """
  Verify a password against the stored hash.

  When the user has no hash — an invited teammate who has not set one, or an
  address that does not exist — we still run a dummy Argon2 verification so the
  response time does not tell an attacker which emails are registered.
  """
  def valid_password?(%__MODULE__{hashed_password: hash}, password)
      when is_binary(hash) and byte_size(password) > 0 do
    Argon2.verify_pass(password, hash)
  end

  def valid_password?(_user, _password) do
    Argon2.no_user_verify()
    false
  end

  defp validate_email(changeset) do
    changeset
    |> update_change(:email, &String.trim/1)
    |> update_change(:email, &String.downcase/1)
    |> validate_format(:email, ~r/^[^\s@,;]+@[^\s@,;]+\.[^\s@,;]+$/,
      message: "must be a valid email address"
    )
    |> validate_length(:email, max: 160)
    |> unsafe_validate_unique(:email, AperDesk.Repo)
    |> unique_constraint(:email)
  end

  # 12 characters with no composition rules. Length beats forced symbols: it
  # produces stronger passwords and fewer "Password1!" variants.
  defp validate_password(changeset) do
    changeset
    |> validate_length(:password, min: 12, max: 200)
    |> validate_confirmation(:password, required: false)
  end

  defp put_password_hash(%Ecto.Changeset{valid?: true} = changeset) do
    case get_change(changeset, :password) do
      nil ->
        changeset

      password ->
        changeset
        |> put_change(:hashed_password, Argon2.hash_pwd_salt(password))
        |> delete_change(:password)
        |> delete_change(:password_confirmation)
    end
  end

  defp put_password_hash(changeset), do: changeset
end
