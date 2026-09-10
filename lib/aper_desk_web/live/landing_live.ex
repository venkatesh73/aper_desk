defmodule AperDeskWeb.LandingLive do
  @moduledoc """
  The public landing page.

  A LiveView rather than a static controller page because the pricing table has
  real state — billing period and display currency — and the reference
  prototype drove both with hand-written DOM manipulation. Holding that state on
  the server means the price a visitor sees is rendered from the same
  `AperDesk.Billing.Plan` rows the product actually bills against, so the
  pricing page cannot drift from the pricing.

  Currency conversion here is display-only. It uses `Finance.fx_rate/4`, the
  same daily snapshot an issued invoice converts with, rather than a hardcoded
  multiplier.
  """

  use AperDeskWeb, :live_view

  alias AperDesk.Billing
  alias AperDesk.Billing.Plan
  alias AperDesk.Finance
  alias AperDesk.Money

  @currencies ~w(USD EUR INR)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "The studio system for photographers")
     |> assign(period: :monthly, currency: "USD")
     |> assign(plans: Billing.list_public_plans())
     |> assign(currencies: offerable_currencies())}
  end

  @doc """
  The currencies we can actually quote in today.

  A currency is only offered if a rate exists to convert into it. Without this
  the switcher happily rendered a $15 plan as "€15", because the missing-rate
  fallback is 1.0 — which is a worse outcome than not offering the currency at
  all, since it looks like a price rather than a failure.
  """
  def offerable_currencies do
    today = Date.utc_today()

    Enum.filter(@currencies, fn currency ->
      currency == "USD" or
        Decimal.compare(Finance.fx_rate("USD", currency, today), Decimal.new(1)) != :eq
    end)
  end

  @impl true
  def handle_event("set-period", %{"period" => period}, socket)
      when period in ~w(monthly yearly) do
    {:noreply, assign(socket, period: String.to_existing_atom(period))}
  end

  def handle_event("set-currency", %{"currency" => currency}, socket)
      when currency in @currencies do
    {:noreply, assign(socket, currency: currency)}
  end

  ## Pricing helpers

  @doc """
  The headline price for a plan, in the visitor's chosen currency.

  Yearly is shown as a monthly equivalent, because that is the number a buyer
  compares against the monthly tier. Showing the annual total beside a monthly
  one makes the yearly plan look more expensive than it is.
  """
  def price(%Plan{} = plan, period, currency) do
    cents =
      case period do
        :monthly -> plan.monthly_price_cents
        :yearly -> div(plan.yearly_price_cents, 12)
      end

    cents
    |> Money.new(plan.currency)
    |> convert(currency)
    # No `cents: false` here. A yearly plan divided by twelve is rarely a round
    # number, and rendering $13.50 as "$13" understates the price on the one
    # page where that must not happen. `Money.to_string/2` already omits the
    # decimals when they are zero.
    |> Money.to_string()
  end

  def extra_seat_price(%Plan{extra_seat_price_cents: nil}, _currency), do: nil

  def extra_seat_price(%Plan{} = plan, currency) do
    plan.extra_seat_price_cents
    |> Money.new(plan.currency)
    |> convert(currency)
    |> Money.to_string(cents: true)
  end

  @doc "What committing to a year saves, as a whole percentage."
  def yearly_saving(%Plan{} = plan), do: div(Plan.yearly_saving_bps(plan), 100)

  defp convert(%Money{} = money, currency) when money.currency == currency, do: money

  defp convert(%Money{} = money, currency) do
    rate = Finance.fx_rate(money.currency, currency, Date.utc_today())
    Money.convert(money, currency, rate)
  end

  @doc """
  A plan's limits as the marketing bullets a buyer reads.

  Built from the plan's own `limits` map rather than written out by hand, so a
  published plan change updates the pricing page without anyone remembering to
  edit copy.
  """
  def plan_bullets(%Plan{} = plan) do
    [
      seats_bullet(plan),
      limit_bullet(plan, "active_leads", "active leads", "Unlimited leads"),
      limit_bullet(plan, "active_galleries", "active client galleries", "Unlimited galleries"),
      storage_bullet(plan),
      window_bullet(plan),
      limit_bullet(plan, "packages", "packages", "Unlimited packages"),
      limit_bullet(plan, "workflows", "workflows", "Unlimited workflows"),
      limit_bullet(plan, "emails_per_lead", "emails per lead", "Unlimited emails per lead")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp seats_bullet(%Plan{} = plan) do
    case Plan.limit(plan, "seats") do
      :unlimited -> "Unlimited users, all five roles"
      1 -> "1 user"
      n -> "#{n} users"
    end
  end

  defp limit_bullet(%Plan{} = plan, key, noun, unlimited_label) do
    case Plan.limit(plan, key) do
      :unlimited -> unlimited_label
      value -> "#{value} #{noun}"
    end
  end

  defp storage_bullet(%Plan{} = plan) do
    case Plan.limit(plan, "storage_bytes") do
      :unlimited -> "Unlimited live storage"
      bytes -> "#{round(bytes / 1_073_741_824)} GB live storage"
    end
  end

  defp window_bullet(%Plan{} = plan) do
    case Plan.limit(plan, "gallery_window_days") do
      :unlimited -> "Galleries stay live indefinitely"
      days -> "#{days}-day gallery delivery window"
    end
  end

  @doc "Whether to draw the plan as the recommended one."
  def highlighted?(%Plan{key: "studio"}), do: true
  def highlighted?(%Plan{}), do: false

  ## Marketing copy
  #
  # Kept as data in one place rather than inline in the template, so the page
  # stays readable and a copy change is a one-line edit. Anything that describes
  # what the product *does* lives here; anything that describes what a plan
  # *costs* is read from the database instead.

  @doc false
  def features do
    [
      %{
        phase: "Capture",
        title: "Lead forms",
        icon:
          ~S(<svg viewBox="0 0 24 24"><rect x="4" y="3" width="16" height="18" rx="2"/><path d="M8 8h8M8 12h8M8 16h5"/></svg>),
        body:
          "Embed a form on your site or share a link. Every submission arrives as a tracked lead with its source."
      },
      %{
        phase: "Book",
        title: "Online booking",
        icon:
          ~S(<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>),
        body:
          "Clients pick a slot from your real availability in their own timezone, with travel buffers built in."
      },
      %{
        phase: "Capture",
        title: "Clash detection",
        icon:
          ~S(<svg viewBox="0 0 24 24"><path d="M12 3 2.5 20h19z"/><path d="M12 9v5M12 17h.01"/></svg>),
        body:
          "Every date is checked against every shooter, hold and travel day before you spend an hour on a quote."
      },
      %{
        phase: "Book",
        title: "Packages",
        icon:
          ~S(<svg viewBox="0 0 24 24"><path d="M21 8 12 3 3 8l9 5z"/><path d="M3 8v8l9 5 9-5V8M12 13v8"/></svg>),
        body:
          "Build packages with sample photos, price and what is included. Share one in a click, in the client's currency."
      },
      %{
        phase: "Book",
        title: "Contracts & e-signature",
        icon:
          ~S(<svg viewBox="0 0 24 24"><path d="M4 20h16"/><path d="m5 16 10.5-10.5a2.1 2.1 0 0 1 3 3L8 19l-4 1z"/></svg>),
        body: "Send a contract template. Clients sign on their phone. No printing, no scanning."
      },
      %{
        phase: "Book",
        title: "Client portal",
        icon:
          ~S(<svg viewBox="0 0 24 24"><rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 9h18M8 13h4M8 16h8"/></svg>),
        body:
          "Clients open one branded link to see their quote, contract, invoices and gallery. No login to remember."
      },
      %{
        phase: "Run",
        title: "Workflows",
        icon: ~S(<svg viewBox="0 0 24 24"><path d="M13 2 4 14h7l-1 8 9-12h-7z"/></svg>),
        body:
          "Reminders, follow-ups, pre-shoot checklists and nurture sequences. Every trigger is visible, and any step can wait for your approval."
      },
      %{
        phase: "Deliver",
        title: "Client galleries",
        icon:
          ~S(<svg viewBox="0 0 24 24"><rect x="3" y="4" width="18" height="16" rx="2"/><path d="m3 16 5-5 4 4 3-3 6 6"/><circle cx="16" cy="9" r="1.5"/></svg>),
        body:
          "Branded delivery galleries with favourites, selections, and download limits you control."
      },
      %{
        phase: "Deliver",
        title: "Studio branding",
        icon:
          ~S(<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="3"/><path d="M12 3v3M12 18v3M3 12h3M18 12h3"/></svg>),
        body: "Your logo and colour on every quote, contract, gallery and email a client sees."
      },
      %{
        phase: "Run",
        title: "Address book",
        icon:
          ~S(<svg viewBox="0 0 24 24"><path d="M4 4h12a3 3 0 0 1 3 3v13H7a3 3 0 0 0-3 3z"/><path d="M4 4v16a3 3 0 0 1 3-3h12"/></svg>),
        body:
          "Every client's details, history and preferences in one searchable place. Import your list by CSV."
      },
      %{
        phase: "Run",
        title: "Deposits, invoices, payouts",
        icon:
          ~S(<svg viewBox="0 0 24 24"><rect x="3" y="6" width="18" height="12" rx="2"/><circle cx="12" cy="12" r="2.5"/><path d="M7 12h.01M17 12h.01"/></svg>),
        body:
          "Collect the deposit at signature, invoice the balance, and pay second shooters and editors from the same record."
      },
      %{
        phase: "Run",
        title: "Key stats",
        icon: ~S(<svg viewBox="0 0 24 24"><path d="M4 20V10M10 20V4M16 20v-7M22 20H2"/></svg>),
        body:
          "What is booked, what is earned, what is coming up, per role. The owner sees everything; everyone else sees their part."
      }
    ]
  end

  @doc false
  def phases do
    [
      %{
        number: "01",
        name: "Capture",
        title: "Every inquiry becomes a lead on its own.",
        body:
          "Forward the email, or let the site form do it. The lead lands in the pipeline with the shoot date already checked and a reply already drafted.",
        points: [
          "Email forwarding creates a tracked lead",
          "Embeddable form for your website",
          "Pipeline stages: new · contacted · consult · quote sent · booked"
        ]
      },
      %{
        number: "02",
        name: "Book",
        title: "Bookings without the back and forth.",
        body:
          "Send a package, share your availability, and get the contract signed from the lead itself. A soft hold protects the date while they decide.",
        points: [
          "Packages with sample photos and pricing",
          "Online booking with travel buffers",
          "Contract templates with e-signature and deposit"
        ]
      },
      %{
        number: "03",
        name: "Run",
        title: "Stay on top of every shoot without a spreadsheet.",
        body:
          "Workflows handle the recurring parts: confirmation reminders, pre-shoot checklists, call sheets for the crew, post-shoot follow-ups. Each one is visible and can wait for you.",
        points: [
          "Reminders, follow-ups and check-ins, auto or ask-me",
          "Nurture sequences for leads that go quiet",
          "Activity log on every action, with the reason"
        ]
      },
      %{
        number: "04",
        name: "Deliver",
        title: "Galleries clients love, on your brand.",
        body:
          "Upload, organise and share a branded gallery. Clients favourite, select and download. You decide what they can do and for how long.",
        points: [
          "Your logo and colour on every gallery",
          "Favourites and selections for album picks",
          "Download limits and a delivery window per plan"
        ]
      }
    ]
  end

  @doc false
  def roles do
    [
      %{
        name: "Owner",
        title: "Whole-studio view",
        body: "Pipeline, revenue, utilisation, and who has not replied to a lead yet."
      },
      %{
        name: "Photographer",
        title: "My shoots and leads",
        body: "Assigned inquiries, shot lists, call sheets, gallery deadlines."
      },
      %{
        name: "Finance",
        title: "Deposits to payouts",
        body: "Invoices, deposits, second-shooter payouts, multi-currency reports."
      },
      %{
        name: "HR",
        title: "Roster and leave",
        body: "Contracts, availability, leave requests, freelancer onboarding."
      },
      %{
        name: "Operations",
        title: "Gear and travel",
        body: "Equipment checkout, travel days, venue notes, clash resolution."
      }
    ]
  end

  @doc false
  def included do
    [
      "30-day free trial, no card",
      "Cancel any time, no contract",
      "Works on any phone, for you and your clients",
      "Email and IMAP sync",
      "Encrypted at rest and in transit",
      "Export your data any time as CSV"
    ]
  end

  @doc false
  def extras do
    [
      %{
        title: "Mobile first",
        body: "Your dashboard and the client portal both work on a phone at the venue."
      },
      %{title: "Activity log", body: "Every action is logged with what happened, when, and why."},
      %{
        title: "CSV contact import",
        body: "Bring your existing client list in one upload. Fields are matched for you."
      },
      %{
        title: "Tags and segments",
        body: "Label clients however you think: niche, source, package, venue."
      },
      %{
        title: "Custom fields",
        body:
          "Track what matters in your niche on every lead: wedding date, venue, guest count, second shooter."
      },
      %{
        title: "Three currencies",
        body: "Quote and invoice in USD, EUR or INR, and report in the one you choose."
      }
    ]
  end

  @doc false
  def beliefs do
    [
      %{
        title: "Forwarding your inbox should be enough.",
        body:
          "Most leads arrive as email, and everything you would type into a CRM is already in it. We read the mail, create the lead and draft the reply. You review and send."
      },
      %{
        title: "Automations should be obvious, not magic.",
        body:
          "Every workflow shows what fires, when, and why. Any step can be set to ask you first. The activity log explains what happened."
      },
      %{
        title: "Your data is yours.",
        body:
          "Full CSV export whenever you like. Cancel and your data stays available for 30 days, then it is deleted. No hostage situations."
      },
      %{
        title: "Pricing should be predictable.",
        body:
          "Three plans, no usage charges, no \"talk to sales\" tier. The price you sign up at is the price you keep."
      }
    ]
  end

  @doc false
  def faqs do
    [
      %{
        question: "How does email lead capture work?",
        answer:
          "Connect your studio inbox by IMAP or Gmail, or just forward inquiries to your AperDesk address. When a message arrives from someone who is not already a contact, we create the contact and the lead, check the date, and draft a reply. Nothing is sent until you approve it."
      },
      %{
        question: "Does it work for my niche?",
        answer:
          "Yes. Starter workflows, packages and contract templates ship for weddings, portraits, newborn, events and commercial work. Custom fields let you track what your niche cares about."
      },
      %{
        question: "Do I need to be technical to set it up?",
        answer:
          "No. Sign up, import your contacts by CSV, paste your packages, and connect your inbox. Most studios are running within a few minutes. Studio and Agency plans include an onboarding call."
      },
      %{
        question: "Can I try it before paying?",
        answer:
          "Every plan has a 30-day free trial with full access and no credit card. Cancel during the trial and you are never charged."
      },
      %{
        question: "What happens when I hit my storage cap?",
        answer:
          "Uploads pause with a clear message. Archive finished galleries to free space, add a 50 GB block, or move up a plan. Client downloads never count against your cap."
      },
      %{
        question: "Are my emails sent to a third party for the drafted replies?",
        answer:
          "With drafting on, the inquiry text is sent to an AI model to suggest a reply. The draft is stored on the lead for you to edit and send. You can switch drafting off in Settings at any time."
      },
      %{
        question: "What happens if I cancel?",
        answer:
          "Your data stays accessible for 30 days after cancellation. Export everything or reactivate during that window. After 30 days it is permanently deleted."
      }
    ]
  end

  @doc "The yearly toggle label, showing the real saving from the plan rows."
  def yearly_label([]), do: "Yearly"

  def yearly_label(plans) do
    case plans |> Enum.map(&yearly_saving/1) |> Enum.max(fn -> 0 end) do
      0 -> "Yearly"
      percent -> "Yearly · save #{percent}%"
    end
  end
end
