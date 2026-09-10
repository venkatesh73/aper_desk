defmodule AperDeskWeb.Graphql.Middleware.RequireScope do
  @moduledoc """
  Rejects a field unless the request carries a studio-attached scope.

  Applied per field rather than to the whole schema, because some fields are
  deliberately public — the plan list on the pricing page, a gallery opened
  from a share link.
  """

  @behaviour Absinthe.Middleware

  alias AperDesk.Scope

  def call(%{context: %{scope: %Scope{studio: studio}}} = resolution, _config)
      when not is_nil(studio),
      do: resolution

  def call(resolution, _config),
    do: Absinthe.Resolution.put_result(resolution, {:error, :unauthorized})
end
