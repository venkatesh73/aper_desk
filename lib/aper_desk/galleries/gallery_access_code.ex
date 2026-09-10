defmodule AperDesk.Galleries.GalleryAccessCode do
  @moduledoc """
  A one-time code emailed to a client opening a gallery that requires
  verification.

  `attempts` is on the row rather than in a cache because the limit has to hold
  across restarts and across web nodes; a code that resets its own attempt count
  when a pod recycles is not a limit.
  """
  use AperDesk.Schema

  alias AperDesk.Galleries.Gallery

  @max_attempts 5
  @ttl_minutes 15

  schema "gallery_access_codes" do
    belongs_to :gallery, Gallery

    field :email, :string
    field :code_hash, :binary
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec
    field :attempts, :integer, default: 0

    field :code, :string, virtual: true, redact: true

    timestamps(updated_at: false)
  end

  def max_attempts, do: @max_attempts

  @doc "Mint a six-digit code for `email`, valid for #{@ttl_minutes} minutes."
  def changeset(access_code, attrs) do
    access_code
    |> cast(attrs, [:gallery_id, :email])
    |> validate_required([:gallery_id, :email])
    |> put_code()
    |> foreign_key_constraint(:gallery_id)
  end

  def consume_changeset(access_code), do: change(access_code, consumed_at: DateTime.utc_now())

  def attempt_changeset(access_code),
    do: change(access_code, attempts: (access_code.attempts || 0) + 1)

  def hash_code(code) when is_binary(code), do: :crypto.hash(:sha256, code)

  @doc "Constant-time check that `code` matches, without leaking timing information."
  def valid_code?(%__MODULE__{code_hash: hash}, code) when is_binary(code),
    do: :crypto.hash_equals(hash, hash_code(code))

  @doc "Whether this code can still be redeemed."
  def usable?(%__MODULE__{consumed_at: %DateTime{}}, _now), do: false

  def usable?(%__MODULE__{attempts: attempts}, _now) when attempts >= @max_attempts, do: false

  def usable?(%__MODULE__{expires_at: expires_at}, now),
    do: DateTime.compare(now, expires_at) != :gt

  defp put_code(changeset) do
    # Six digits from a cryptographic source, not :rand — this code is the only
    # thing standing between a stranger and a client's photographs.
    code =
      4
      |> :crypto.strong_rand_bytes()
      |> :binary.decode_unsigned()
      |> rem(900_000)
      |> Kernel.+(100_000)
      |> Integer.to_string()

    changeset
    |> put_change(:code, code)
    |> put_change(:code_hash, hash_code(code))
    |> put_change(:expires_at, DateTime.add(DateTime.utc_now(), @ttl_minutes * 60, :second))
  end
end
