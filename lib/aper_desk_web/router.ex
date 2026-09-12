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

    get "/sign-up", AuthController, :new_registration
    post "/sign-up", AuthController, :create_registration
    get "/sign-in", AuthController, :new_session
    post "/sign-in", AuthController, :create_session
    delete "/sign-out", AuthController, :sign_out
    get "/sign-out", AuthController, :sign_out

    get "/auth/google", AuthController, :google_request
    get "/auth/google/callback", AuthController, :google_callback

    get "/forgot-password", AuthController, :new_reset
    post "/forgot-password", AuthController, :create_reset
    get "/reset-password/:token", AuthController, :edit_reset
    put "/reset-password/:token", AuthController, :update_reset

    get "/invitations/:token", AuthController, :show_invitation
    post "/invitations/:token", AuthController, :accept_invitation

    # The client's way in. The token is the whole authorisation — there is no
    # scope here, and the gallery id opens nothing.
    live "/g/:token", ClientGalleryLive, :show
    live "/q/:token", ClientQuoteLive, :show
  end

  # The signed-in application. RequireAuth guards the HTTP request that renders
  # the LiveView; the on_mount hook guards the socket that connects afterwards,
  # which is a separate process with only the session to go on.
  scope "/app", AperDeskWeb do
    pipe_through [:browser, :authenticated, :require_auth]

    # Its own session: the setup screen must not redirect to itself.
    live_session :setup, on_mount: {AperDeskWeb.LiveAuth, :require_scope_only} do
      live "/setup", SetupLive, :index
    end

    live_session :app, on_mount: {AperDeskWeb.LiveAuth, :require_scope} do
      live "/", DashboardLive, :index
      live "/leads", LeadsLive, :index
      live "/leads/new", LeadLive, :new

      live "/contacts", ContactsLive, :index
      live "/contacts/new", ContactsLive, :new
      live "/contacts/:id", ContactsLive, :show
      live "/contacts/:id/edit", ContactsLive, :edit

      live "/leads/:id", LeadLive, :show

      live "/calendar", CalendarLive, :index
      live "/calendar/new", CalendarLive, :new

      live "/packages", PackagesLive, :index
      live "/packages/new", PackagesLive, :new
      live "/packages/:id/edit", PackagesLive, :edit

      live "/templates", TemplatesLive, :index
      live "/templates/:kind/new", TemplatesLive, :new
      live "/templates/:kind/:id/edit", TemplatesLive, :edit

      live "/automations", AutomationsLive, :index
      live "/automations/new", AutomationsLive, :new_workflow
      live "/automations/nurture/new", AutomationsLive, :new_sequence
      live "/automations/nurture/:id/edit", AutomationsLive, :edit_sequence

      # Routes whose contexts exist but whose screens do not yet. Real routes
      # rather than missing ones, because the sidebar links to them and a 404
      # is a worse answer than saying plainly what is coming.
      live "/galleries", GalleriesLive, :index
      live "/galleries/new", GalleriesLive, :new
      live "/galleries/:id", GalleryLive, :show
      live "/quotes", QuotesLive, :index
      live "/quotes/new", QuotesLive, :new
      live "/quotes/:id", QuoteLive, :show
      live "/finance", FinanceLive, :index
      live "/finance/invoices/new", InvoiceLive, :new
      live "/finance/invoices/:id", InvoiceLive, :show
      live "/team", TeamLive, :index
      live "/operations", OperationsLive, :index
      live "/settings", SettingsLive, :index
    end
  end

  # The mobile client is a first-class consumer, so GraphQL sits beside the
  # LiveView UI rather than being bolted on. Complexity and depth limits are
  # applied here: a public GraphQL endpoint without them is a denial-of-service
  # waiting for a deeply nested query.
  scope "/api", AperDeskWeb do
    pipe_through :api

    # Token auth for the mobile client. The browser signs in at /sign-in and
    # gets a cookie; the phone signs in here and gets a bearer token.
    post "/auth/sign-in", ApiAuthController, :sign_in
    post "/auth/refresh", ApiAuthController, :refresh
    post "/auth/sign-out", ApiAuthController, :sign_out
  end

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
      # Sent mail is written here in development rather than delivered.
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
