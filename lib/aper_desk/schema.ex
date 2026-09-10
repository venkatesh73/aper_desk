defmodule AperDesk.Schema do
  @moduledoc """
  Shared schema defaults: UUIDv7 primary keys, UUID foreign keys, microsecond
  UTC timestamps. Every schema in the app uses this rather than repeating the
  four `@primary_key`-style attributes.
  """

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key {:id, :binary_id, autogenerate: false, read_after_writes: true}
      @foreign_key_type :binary_id
      @timestamps_opts [type: :utc_datetime_usec]

      @typedoc "An `#{inspect(__MODULE__)}` struct."
      @type t :: %__MODULE__{}
    end
  end
end
