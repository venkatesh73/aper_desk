defmodule AperDeskWeb.BookingLiveTest do
  @moduledoc """
  Booking a session from the public page.

  `book_slot/2` and its row-locked status guard existed from the first commit
  and nothing served a page that let anyone reach them, so the whole feature
  was usable only from iex.
  """
  use AperDeskWeb.ConnCase, async: true

  import AperDesk.Fixtures
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias AperDesk.Crm.Lead
  alias AperDesk.Repo
  alias AperDesk.Scheduling
  alias AperDesk.Scheduling.BookingSlot

  setup %{conn: conn} do
    %{studio: studio, scope: scope} = studio_fixture(%{studio: %{name: "Aperture Lisboa"}})
    plan_fixture(studio)

    {:ok, package} =
      AperDesk.Catalog.create_package(scope, %{
        "name" => "Portrait session",
        "price_cents" => 32_000,
        "price_currency" => "EUR",
        "duration_minutes" => 60,
        "deposit_percent" => 30,
        "public" => true
      })

    %{conn: conn, studio: studio, scope: scope, package: package}
  end

  defp pick_day(view, slot) do
    date = slot.starts_at |> DateTime.to_date() |> Date.to_iso8601()
    view |> element("button[phx-value-date='#{date}']") |> render_click()
  end

  defp slot(studio, package, days_ahead, hour, status \\ "open") do
    date = Date.add(Date.utc_today(), days_ahead)
    {:ok, starts} = DateTime.new(date, Time.new!(hour, 0, 0, {0, 6}), "Etc/UTC")

    Repo.insert!(%BookingSlot{
      studio_id: studio.id,
      package_id: package.id,
      starts_at: starts,
      ends_at: DateTime.add(starts, 3600, :second),
      status: status
    })
  end

  describe "the page" do
    test "offers the studio's public sessions", %{conn: conn, studio: studio, package: package} do
      slot(studio, package, 3, 10)

      {:ok, _view, html} = live(conn, ~p"/book/#{studio.slug}")

      assert html =~ "Book a session with Aperture Lisboa"
      assert html =~ "Portrait session"

      # The deposit is the studio's own figure and appears once a session is
      # chosen, because it is a percentage of that session's price.
      {:ok, view, _} = live(conn, ~p"/book/#{studio.slug}")
      chosen = view |> element("button[phx-click='session']") |> render_click()
      assert chosen =~ "30%"
    end

    test "never sends a slot somebody else already has", %{
      conn: conn,
      studio: studio,
      package: package
    } do
      open = slot(studio, package, 3, 10)
      taken = slot(studio, package, 3, 14, "booked")

      {:ok, view, _html} = live(conn, ~p"/book/#{studio.slug}")
      html = pick_day(view, open)

      # Absent, not greyed out. A page that renders someone else's booking has
      # told a stranger when that person is being photographed.
      assert html =~ open.id
      refute html =~ taken.id
    end

    test "a studio that is not here is a 404", %{conn: conn} do
      assert_raise AperDeskWeb.NotFoundError, fn ->
        live(conn, ~p"/book/nobody-at-all")
      end
    end

    test "is never offered to a crawler", %{conn: conn, studio: studio} do
      html = conn |> get(~p"/book/#{studio.slug}") |> html_response(200)
      assert html =~ "noindex"
    end
  end

  describe "booking a time" do
    setup %{studio: studio, package: package} do
      %{slot: slot(studio, package, 3, 10)}
    end

    defp choose_and_book(view, slot, details) do
      # A time is only offered once its day is picked, which is the order a
      # client does it in.
      pick_day(view, slot)
      view |> element("button[phx-value-id='#{slot.id}'][phx-click='slot']") |> render_click()
      view |> form("form[phx-submit=confirm]", %{"booking" => details}) |> render_submit()
    end

    test "creates a contact, a lead, and links the slot", %{
      conn: conn,
      studio: studio,
      slot: slot
    } do
      {:ok, view, _html} = live(conn, ~p"/book/#{studio.slug}")

      html =
        choose_and_book(view, slot, %{
          "name" => "Rita Sousa",
          "email" => "rita@example.com",
          "notes" => "Two of us, natural light please."
        })

      assert html =~ "That time is yours"

      lead = Repo.one!(from l in Lead, where: l.studio_id == ^studio.id)
      assert lead.source == "booking"
      assert lead.desired_date == DateTime.to_date(slot.starts_at)

      # The answer the client typed. It went into custom_fields first, which is
      # validated against the studio's own definitions and drops anything
      # undefined — so it was collected and thrown away.
      assert lead.notes == "Two of us, natural light please."

      contact = Repo.get!(AperDesk.Crm.Contact, lead.contact_id)
      assert contact.email == "rita@example.com"

      booked = Repo.get!(BookingSlot, slot.id)
      assert booked.status == "booked"
      assert booked.lead_id == lead.id
    end

    test "will not book without a name and an email", %{conn: conn, studio: studio, slot: slot} do
      {:ok, view, _html} = live(conn, ~p"/book/#{studio.slug}")

      html = choose_and_book(view, slot, %{"name" => "", "email" => ""})

      assert html =~ "need a name and an email"
      assert Repo.get!(BookingSlot, slot.id).status == "open"
    end

    test "tells the second person the time has gone rather than double-booking", %{
      conn: conn,
      studio: studio,
      slot: slot
    } do
      {:ok, view, _html} = live(conn, ~p"/book/#{studio.slug}")

      # Someone else takes it between this page loading and the click.
      {:ok, _} = Scheduling.book_slot(slot.id, %{"name" => "First", "email" => "a@example.com"})

      html =
        choose_and_book(view, slot, %{"name" => "Second", "email" => "b@example.com"})

      assert html =~ "just took that time"
      refute html =~ "That time is yours"

      # And exactly one lead exists, not two.
      assert Repo.aggregate(from(l in Lead, where: l.studio_id == ^studio.id), :count) == 1
    end

    test "a failed booking leaves the slot open", %{conn: conn, studio: studio, package: package} do
      # An email the contact changeset refuses, so the lead cannot be created.
      slot = slot(studio, package, 4, 11)
      {:ok, view, _html} = live(conn, ~p"/book/#{studio.slug}")

      choose_and_book(view, slot, %{"name" => "Rita", "email" => "not-an-email"})

      # Claiming the slot and creating the lead are one transaction: a slot
      # marked booked with no lead behind it is a Saturday held for nobody.
      assert Repo.get!(BookingSlot, slot.id).status == "open"
    end
  end
end
