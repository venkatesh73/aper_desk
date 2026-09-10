defmodule AperDeskWeb.AppComponents do
  @moduledoc """
  The signed-in shell: sidebar, topbar and the small pieces the screens share.

  Navigation is filtered by `AperDesk.Authorization`, so a finance user is not
  shown a Galleries link they would be refused at the context boundary. Hiding
  it is presentation, not security — the context checks the same permission
  again, because a link that is merely absent is not a link that cannot be
  reached.
  """

  use AperDeskWeb, :html

  alias AperDesk.Authorization
  alias AperDesk.Scope

  attr :current_scope, :map, required: true
  attr :active, :atom, required: true

  def sidebar(assigns) do
    assigns = assign(assigns, :items, visible_items(assigns.current_scope))

    ~H"""
    <aside class="side">
      <a class="brand" href={~p"/"}>
        <img src={~p"/images/logo-long.png"} alt="AperDesk" width="120" height="40" />
      </a>

      <a :for={item <- @items} class={["ni", @active == item.key && "on"]} href={item.path}>
        {Phoenix.HTML.raw(item.icon)}{item.label}
        <span :if={item[:badge]} class="n">{item.badge}</span>
      </a>

      <div class="me">
        <span class="av">{initials(@current_scope)}</span>
        <span>
          <b>{@current_scope.user && @current_scope.user.name}</b>{studio_line(@current_scope)}
        </span>
        <span class="spacer"></span>
        <button
          class="btn icon ghost"
          data-theme-toggle
          title="Toggle theme"
          aria-label="Toggle theme"
        >
          <svg
            viewBox="0 0 24 24"
            width="14"
            height="14"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
          >
            <path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z" />
          </svg>
        </button>
      </div>
    </aside>
    """
  end

  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  slot :actions

  def topbar(assigns) do
    ~H"""
    <div class="topbar">
      <div>
        <h2>{@title}</h2>
        <div :if={@subtitle} class="sub">{@subtitle}</div>
      </div>
      <span class="spacer"></span>
      {render_slot(@actions)}
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :detail, :string, default: nil
  attr :tone, :atom, default: :neutral

  def stat(assigns) do
    ~H"""
    <div class="stat">
      <div class="k">{@label}</div>
      <div class="v">{@value}</div>
      <div :if={@detail} class={["d", tone_class(@tone)]}>{@detail}</div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :body, :string, default: nil

  def empty(assigns) do
    ~H"""
    <div class="empty">
      <b>{@title}</b>
      <span :if={@body}>{@body}</span>
    </div>
    """
  end

  ## Internals

  # Each entry names the permission that gates it, so adding a screen means
  # adding one row here rather than editing a role check somewhere else.
  defp nav_items do
    [
      %{
        key: :dashboard,
        label: "Dashboard",
        path: "/app",
        permission: nil,
        icon: nav_icon(:grid)
      },
      %{
        key: :leads,
        label: "Leads",
        path: "/app/leads",
        permission: :"lead.read",
        icon: nav_icon(:table)
      },
      %{
        key: :contacts,
        label: "Contacts",
        path: "/app/contacts",
        permission: :"contact.read",
        icon: nav_icon(:book)
      },
      %{
        key: :calendar,
        label: "Calendar",
        path: "/app/calendar",
        permission: :"job.read",
        icon: nav_icon(:calendar)
      },
      %{
        key: :galleries,
        label: "Galleries",
        path: "/app/galleries",
        permission: :"gallery.read",
        icon: nav_icon(:image)
      },
      %{
        key: :quotes,
        label: "Quotes",
        path: "/app/quotes",
        permission: :"quote.read",
        icon: nav_icon(:doc)
      },
      %{
        key: :finance,
        label: "Finance",
        path: "/app/finance",
        permission: :"invoice.read",
        icon: nav_icon(:card)
      },
      %{
        key: :team,
        label: "Team",
        path: "/app/team",
        permission: :"member.read",
        icon: nav_icon(:people)
      },
      %{
        key: :packages,
        label: "Packages",
        path: "/app/packages",
        permission: :"package.read",
        icon: nav_icon(:box)
      },
      %{
        key: :templates,
        label: "Templates",
        path: "/app/templates",
        permission: :"comms.read",
        icon: nav_icon(:doc)
      },
      %{
        key: :automations,
        label: "Automations",
        path: "/app/automations",
        permission: :"workflow.read",
        icon: nav_icon(:bolt)
      },
      %{
        key: :settings,
        label: "Settings",
        path: "/app/settings",
        permission: :"studio.read",
        icon: nav_icon(:cog)
      }
    ]
  end

  defp visible_items(scope) do
    Enum.filter(nav_items(), fn item ->
      is_nil(item.permission) or Authorization.can?(scope, item.permission)
    end)
  end

  # The studio and the role in one line, since the sidebar footer is the only
  # place either is shown now.
  defp studio_line(%Scope{studio: nil}), do: "No studio"

  defp studio_line(%Scope{studio: studio, role: role}),
    do: "#{studio.name} · #{role_label(role)}"

  defp role_label(nil), do: "Signed out"
  defp role_label(:owner), do: "Studio owner"
  defp role_label(:photographer), do: "Photographer"
  defp role_label(:finance), do: "Finance"
  defp role_label(:hr), do: "HR"
  defp role_label(:ops), do: "Operations"

  defp initials(%Scope{user: nil}), do: "?"

  defp initials(%Scope{user: user}),
    do: AperDeskWeb.Graphql.Resolvers.Helpers.initials(user.name)

  defp tone_class(:up), do: "up"
  defp tone_class(:down), do: "down"
  defp tone_class(:warning), do: "warn"
  defp tone_class(_), do: nil

  defp nav_icon(:grid),
    do:
      ~S(<svg viewBox="0 0 24 24"><rect x="3" y="3" width="7" height="9" rx="1"/><rect x="14" y="3" width="7" height="5" rx="1"/><rect x="14" y="12" width="7" height="9" rx="1"/><rect x="3" y="16" width="7" height="5" rx="1"/></svg>)

  defp nav_icon(:table),
    do: ~S(<svg viewBox="0 0 24 24"><path d="M4 4h16v16H4z"/><path d="M4 9h16M9 9v11"/></svg>)

  defp nav_icon(:calendar),
    do:
      ~S(<svg viewBox="0 0 24 24"><rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/></svg>)

  defp nav_icon(:image),
    do:
      ~S(<svg viewBox="0 0 24 24"><rect x="3" y="4" width="18" height="16" rx="2"/><path d="m3 16 5-5 4 4 3-3 6 6"/><circle cx="16" cy="9" r="1.5"/></svg>)

  defp nav_icon(:doc),
    do:
      ~S(<svg viewBox="0 0 24 24"><path d="M6 3h9l5 5v13H6z"/><path d="M14 3v6h6M9 13h6M9 17h6"/></svg>)

  defp nav_icon(:card),
    do:
      ~S(<svg viewBox="0 0 24 24"><rect x="3" y="6" width="18" height="12" rx="2"/><circle cx="12" cy="12" r="2.5"/></svg>)

  defp nav_icon(:people),
    do:
      ~S(<svg viewBox="0 0 24 24"><circle cx="9" cy="8" r="3.5"/><path d="M2.5 20a6.5 6.5 0 0 1 13 0"/><circle cx="17" cy="9" r="2.5"/><path d="M15 14.5a5 5 0 0 1 6.5 5.5"/></svg>)

  defp nav_icon(:bolt),
    do: ~S(<svg viewBox="0 0 24 24"><path d="M13 2 4 14h7l-1 8 9-12h-7z"/></svg>)

  defp nav_icon(:book),
    do:
      ~S(<svg viewBox="0 0 24 24"><path d="M4 4h12a3 3 0 0 1 3 3v13H7a3 3 0 0 0-3 3z"/><path d="M4 4v16a3 3 0 0 1 3-3h12"/></svg>)

  defp nav_icon(:box),
    do:
      ~S(<svg viewBox="0 0 24 24"><path d="M21 8 12 3 3 8l9 5z"/><path d="M3 8v8l9 5 9-5V8M12 13v8"/></svg>)

  defp nav_icon(:cog),
    do:
      ~S(<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9l2.1 2.1M17 17l2.1 2.1M4.9 19.1 7 17M17 7l2.1-2.1"/></svg>)
end
