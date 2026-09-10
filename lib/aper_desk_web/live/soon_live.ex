defmodule AperDeskWeb.SoonLive do
  @moduledoc """
  A placeholder for the screens whose contexts exist but whose UI does not yet.

  These routes are real rather than absent on purpose: the sidebar links to
  them, and a link that 404s is worse than one that says plainly what is coming.
  Each entry names the context that already backs it, so it is clear the work
  remaining is the screen, not the domain underneath.
  """

  use AperDeskWeb, :live_view

  import AperDeskWeb.AppComponents

  @sections %{
    calendar: %{
      title: "Calendar",
      blurb: "Month view with clash detection, soft holds and travel days.",
      backed_by:
        "AperDesk.Scheduling — jobs, assignments and the exclusion constraint that prevents double-booking."
    },
    galleries: %{
      title: "Galleries",
      blurb: "Branded delivery galleries with favourites, selections and download limits.",
      backed_by: "AperDesk.Galleries — uploads, share tokens, expiry and the plan's storage cap."
    },
    quotes: %{
      title: "Quotes",
      blurb: "Build a quote, send it, and turn an acceptance into a booking.",
      backed_by: "AperDesk.Sales — quotes, contracts and tamper-evident e-signatures."
    },
    finance: %{
      title: "Finance",
      blurb: "Invoices out, payments in, crew payouts and FX exposure.",
      backed_by: "AperDesk.Finance — invoices, payments, refunds and payout runs."
    },
    team: %{
      title: "Team",
      blurb: "Who is on the books, their roles, and who is away.",
      backed_by: "AperDesk.Accounts — memberships, invitations and the five roles."
    },
    automations: %{
      title: "Automations",
      blurb: "Workflows, nurture sequences and everything waiting on your approval.",
      backed_by: "AperDesk.Automation — the transactional outbox and its idempotent drain."
    },
    settings: %{
      title: "Settings",
      blurb: "Studio branding, currencies, reply targets and your plan.",
      backed_by: "AperDesk.Accounts and AperDesk.Billing — studio settings, plans and usage."
    },
    new_lead: %{
      title: "New lead",
      blurb: "Capture an enquiry by hand, with your studio's custom fields.",
      backed_by: "AperDesk.Crm — lead creation, plan limits and the outbox event it emits."
    }
  }

  @impl true
  def mount(_params, _session, socket) do
    section = Map.fetch!(@sections, socket.assigns.live_action)

    {:ok,
     socket
     |> assign(page_title: section.title)
     |> assign(section: section)
     |> assign(active: nav_key(socket.assigns.live_action))}
  end

  # The new-lead screen belongs under Leads in the sidebar.
  defp nav_key(:new_lead), do: :leads
  defp nav_key(action), do: action
end
