defmodule AperDeskWeb.Graphql.Context do
  @moduledoc """
  Moves the `%Scope{}` that `AperDeskWeb.Plugs.Authenticate` resolved into the
  Absinthe context, where resolvers read it.

  Resolvers never see the connection, so this is the only place authentication
  crosses into GraphQL. That keeps the rule "every resolver takes a scope"
  enforceable by reading one module.
  """

  @behaviour Plug

  alias AperDesk.Scope

  def init(opts), do: opts

  def call(conn, _opts) do
    scope = conn.assigns[:current_scope] || Scope.public()
    Absinthe.Plug.put_options(conn, context: %{scope: scope})
  end
end
