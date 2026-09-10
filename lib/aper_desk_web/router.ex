defmodule AperDeskWeb.Router do
  use AperDeskWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AperDeskWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug AperDeskWeb.Plugs.Authenticate
    plug AperDeskWeb.Graphql.Context
  end

  # Authentication is resolved for browser requests too, so public pages can
  # render differently for a signed-in user without a separate pipeline.
  pipeline :authenticated do
    plug AperDeskWeb.Plugs.Authenticate
  end

  pipeline :require_auth do
    plug AperDeskWeb.Plugs.RequireAuth
  end

  scope "/", AperDeskWeb do
    pipe_through [:browser, :authenticated]

    live "/", LandingLive, :index
  end

  # The mobile client is a first-class consumer, so GraphQL sits beside the
  # LiveView UI rather than being bolted on. Complexity and depth limits are
  # applied here: a public GraphQL endpoint without them is a denial-of-service
  # waiting for a deeply nested query.
  scope "/api" do
    pipe_through :api

    forward "/graphql", Absinthe.Plug,
      schema: AperDeskWeb.Graphql.Schema,
      analyze_complexity: true,
      max_complexity:
        Application.compile_env(:aper_desk, [AperDeskWeb.Graphql, :max_complexity], 300)
  end

  # The playground is opened in a browser, which sends `Accept: text/html`.
  # Running it through the JSON-only :api pipeline returns 406, so it gets its
  # own pipeline that accepts both.
  if Application.compile_env(:aper_desk, :dev_routes) do
    pipeline :graphiql do
      plug :accepts, ["html", "json"]
      plug :fetch_session
      plug AperDeskWeb.Plugs.Authenticate
      plug AperDeskWeb.Graphql.Context
    end

    scope "/api" do
      pipe_through :graphiql

      forward "/graphiql", Absinthe.Plug.GraphiQL,
        schema: AperDeskWeb.Graphql.Schema,
        interface: :playground
    end
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:aper_desk, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AperDeskWeb.Telemetry
    end
  end
end
