defmodule AperDesk.Repo do
  use Ecto.Repo,
    otp_app: :aper_desk,
    adapter: Ecto.Adapters.Postgres

  @doc """
  Run `fun` inside a transaction with the Postgres session variable
  `app.studio_id` set, which is what the row-level security policies read.

  This is defence in depth, not the primary scoping mechanism — contexts still
  filter by `studio_id` explicitly. It exists so that the day someone forgets a
  `where`, the database returns nothing rather than another studio's clients.

  `set_config(..., true)` makes the setting local to the transaction, so it
  cannot leak to the next checkout of a pooled connection.
  """
  def with_studio(studio_id, fun) when is_binary(studio_id) and is_function(fun, 0) do
    transaction(fn ->
      query!("SELECT set_config('app.studio_id', $1, true)", [studio_id])
      fun.()
    end)
  end

  def with_studio(nil, fun) when is_function(fun, 0), do: {:ok, fun.()}
end
