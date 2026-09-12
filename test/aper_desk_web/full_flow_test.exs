defmodule AperDeskWeb.FullFlowTest do
  @moduledoc """
  One studio's whole working life, end to end, in the order it actually
  happens: a stranger fills in the form on the studio's website, and the
  studio ends up paid with the photographs delivered.

  Every other test in this suite checks one screen or one context. This one
  checks that they join up — which is where integration bugs live, and where
  the ones that have actually bitten in this project were found. It is
  deliberately written as a narrative rather than split into cases, because the
  point is the sequence: each step depends on the state the previous one left.

  It goes through the contexts rather than the LiveViews wherever a screen is
  not the thing under test, so a failure points at the seam rather than at a
  selector.
  """
  use AperDeskWeb.ConnCase, async: false

  import AperDesk.Fixtures
  import Phoenix.LiveViewTest

  alias AperDesk.{
    Accounts,
    Comms,
    Crm,
    Finance,
    Galleries,
    Operations,
    People,
    Repo,
    Sales,
    Scheduling
  }

  alias AperDesk.Automation.Workers.OutboxDrainWorker

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
       )

  test "an enquiry becomes a booked, shot, delivered and paid job", %{conn: conn} do
    # ---- The studio exists and is set up ------------------------------------
    %{user: owner, studio: studio, scope: scope} = studio_fixture()
    plan_fixture(studio)

    photographer = add_member(studio, "Jonas Weber", "photographer")
    ops = add_member(studio, "Mira Rocha", "ops")

    # ---- 1. A stranger fills in the form on the studio's website ------------
    {:ok, form} =
      Comms.create_form(scope, %{
        "name" => "Wedding enquiry",
        "headline" => "Tell us about your day",
        "fields" => %{
          "fields" => [
            %{"key" => "name", "label" => "Your names", "type" => "text", "required" => true},
            %{"key" => "email", "label" => "Email", "type" => "email", "required" => true},
            %{"key" => "venue", "label" => "Where", "type" => "text"}
          ]
        }
      })

    studio_slug = Repo.reload!(studio).slug

    {:ok, public, html} = live(build_conn(), ~p"/f/#{studio_slug}/#{form.slug}")
    assert html =~ "Tell us about your day"

    # A submission missing a required answer is refused, not silently dropped.
    html =
      public
      |> form("form")
      |> render_submit(%{"answers" => %{"name" => "", "email" => "anna@example.com"}})

    assert html =~ "is required"
    assert {:ok, []} = Crm.list_leads(scope)

    html =
      public
      |> form("form")
      |> render_submit(%{
        "answers" => %{
          "name" => "Anna Bell",
          "email" => "anna@example.com",
          "venue" => "Quinta da Regaleira",
          # An answer to a question the form does not ask is dropped rather
          # than stored — the field list is the contract.
          "injected" => "should not be kept"
        }
      })

    assert html =~ "Thank you"

    # ---- 2. It arrived as a lead, with a contact behind it ------------------
    assert {:ok, [lead]} = Crm.list_leads(scope)
    assert lead.contact_id
    {:ok, contact} = Crm.fetch_contact(scope, lead.contact_id)
    assert contact.email == "anna@example.com"

    [submission] = Repo.all(AperDesk.Comms.FormSubmission)
    refute Map.has_key?(submission.answers, "injected")

    # ---- 3. The automation spine actually turns ----------------------------
    assert {:ok, drained} = OutboxDrainWorker.perform(%Oban.Job{args: %{}})
    assert drained.processed > 0

    # ---- 4. The studio quotes it -------------------------------------------
    {:ok, quote} =
      Sales.create_quote(scope, %{
        "title" => "Anna and Ben — wedding",
        "contact_id" => contact.id,
        "lead_id" => lead.id,
        "currency" => "USD",
        "valid_until" => Date.add(Date.utc_today(), 30),
        "line_items" => [
          %{"description" => "Full day coverage", "quantity" => 1, "unit_price_cents" => 450_000}
        ],
        "deposit_cents" => 112_500
      })

    assert quote.total_cents == 450_000

    {:ok, _quote, token} = Sales.send_quote(scope, quote.id)

    # ---- 5. The client reads it on a link with no account ------------------
    {:ok, _client, client_html} = live(build_conn(), ~p"/q/#{token}")
    assert client_html =~ "Anna and Ben"
    assert client_html =~ "$4,500"

    {:ok, viewed} = Sales.fetch_quote(scope, quote.id)
    assert viewed.status == "viewed"

    # ---- 6. They accept, and the lead moves with it ------------------------
    {:ok, accepted} = Sales.accept_quote(scope, quote.id)
    assert accepted.status == "accepted"
    {:ok, booked_lead} = Crm.fetch_lead(scope, lead.id)
    assert booked_lead.stage == "booked"

    # ---- 7. The shoot goes in the calendar, with crew -----------------------
    {:ok, starts} = DateTime.new(Date.add(Date.utc_today(), 60), ~T[10:00:00], "Etc/UTC")
    {:ok, ends} = DateTime.new(Date.add(Date.utc_today(), 60), ~T[20:00:00], "Etc/UTC")

    {:ok, job} =
      Scheduling.create_job(
        scope,
        %{
          "title" => "Anna and Ben — wedding",
          "contact_id" => contact.id,
          "lead_id" => lead.id,
          "starts_at" => starts,
          "ends_at" => ends,
          "venue_name" => "Quinta da Regaleira",
          "travel_before_minutes" => 90
        },
        [%{user_id: photographer.id}]
      )

    # The photographer sees their own shoot, and nobody else's.
    {:ok, photographer_scope} = Accounts.scope_for(photographer, studio.id)
    assert {:ok, [theirs]} = Scheduling.list_jobs(photographer_scope)
    assert theirs.id == job.id

    # ---- 8. Booking them twice is refused by the database ------------------
    assert {:error, {:clash, _}} =
             Scheduling.create_job(
               scope,
               %{"title" => "Clashing shoot", "starts_at" => starts, "ends_at" => ends},
               [%{user_id: photographer.id}]
             )

    # ---- 9. Leave over the date warns rather than being silently allowed ---
    {:ok, leave} =
      People.request_leave(scope, %{
        "user_id" => photographer.id,
        "starts_on" => Date.add(Date.utc_today(), 60),
        "ends_on" => Date.add(Date.utc_today(), 61)
      })

    {:ok, _approved} = People.approve_leave(scope, leave.id)
    clashes = Scheduling.clashes_for(scope, photographer.id, {starts, ends})
    assert Enum.any?(clashes, &(&1.kind == "hold"))

    # ---- 10. Ops signs the kit out -----------------------------------------
    {:ok, ops_scope} = Accounts.scope_for(ops, studio.id)
    {:ok, body} = Operations.create_gear(scope, %{"name" => "A7 IV #1", "category" => "body"})

    {:ok, checkout} =
      Operations.check_out(ops_scope, body.id, %{
        "user_id" => photographer.id,
        "job_id" => job.id
      })

    assert {:error, :already_out} = Operations.check_out(ops_scope, body.id)

    # ---- 11. The deposit is invoiced and paid ------------------------------
    {:ok, deposit} =
      Finance.create_invoice(scope, %{
        "contact_id" => contact.id,
        "kind" => "deposit",
        "currency" => "USD",
        "due_on" => Date.add(Date.utc_today(), 7),
        "line_items" => [
          %{"description" => "Deposit", "quantity" => 1, "unit_price_cents" => 112_500}
        ]
      })

    {:ok, deposit} = Finance.send_invoice(scope, deposit.id)

    {:ok, %{invoice: paid}} =
      Finance.record_payment(scope, deposit.id, %{
        "amount_cents" => 112_500,
        "currency" => "USD",
        "method" => "bank_transfer",
        "received_at" => DateTime.utc_now()
      })

    assert paid.status == "paid"
    assert paid.paid_cents == 112_500

    # ---- 12. The photographs are delivered ---------------------------------
    {:ok, gallery} =
      Galleries.create_gallery(scope, %{
        "title" => "Anna and Ben",
        "contact_id" => contact.id,
        "job_id" => job.id
      })

    {:ok, gallery_view, _} = live(sign_in(conn, owner, studio), ~p"/app/galleries/#{gallery}")

    file =
      file_input(gallery_view, "#upload-form", :photos, [
        %{name: "frame.png", content: @png, type: "image/png", size: byte_size(@png)}
      ])

    render_upload(file, "frame.png")
    gallery_view |> form("#upload-form") |> render_submit()

    assert [media] = Galleries.list_media(scope, gallery.id)
    assert File.exists?(Path.join("tmp/test_uploads", media.storage_key))

    {:ok, delivered} = Galleries.deliver_gallery(scope, gallery.id)
    assert delivered.status == "delivered"
    assert delivered.expires_at

    {:ok, _share, gallery_token} =
      Galleries.share_gallery(scope, gallery.id, %{"label" => "The couple"})

    # ---- 13. The couple open it and pick their favourites ------------------
    {:ok, client_gallery, gallery_html} = live(build_conn(), ~p"/g/#{gallery_token}")
    assert gallery_html =~ "Anna and Ben"

    render_click(element(client_gallery, "button[phx-value-id='#{media.id}']"))
    assert {:ok, [favourite]} = Galleries.list_selections(scope, gallery.id, "favourite")
    assert favourite.media_id == media.id

    # ---- 14. The balance is invoiced and settled ---------------------------
    {:ok, balance} =
      Finance.create_invoice(scope, %{
        "contact_id" => contact.id,
        "kind" => "balance",
        "currency" => "USD",
        "due_on" => Date.add(Date.utc_today(), -1),
        "line_items" => [
          %{"description" => "Balance", "quantity" => 1, "unit_price_cents" => 337_500}
        ]
      })

    {:ok, _} = Finance.send_invoice(scope, balance.id)

    # Overdue, so the chaser picks it up — once.
    assert AperDesk.Finance.Workers.InvoiceReminderWorker.remind() == 1
    assert AperDesk.Finance.Workers.InvoiceReminderWorker.remind() == 0

    {:ok, %{invoice: settled}} =
      Finance.record_payment(scope, balance.id, %{
        "amount_cents" => 337_500,
        "currency" => "USD",
        "method" => "bank_transfer",
        "received_at" => DateTime.utc_now()
      })

    assert settled.status == "paid"

    # ---- 15. The kit comes back and the books balance ----------------------
    {:ok, _} = Operations.check_in(ops_scope, checkout.id)
    assert {:ok, []} = Operations.checked_out(ops_scope)

    outstanding = Finance.outstanding_total(scope)
    assert outstanding.amount == 0

    # ---- 16. The owner's dashboard reflects all of it ----------------------
    {:ok, _dashboard, dashboard_html} = live(sign_in(conn, owner, studio), ~p"/app")

    assert dashboard_html =~ "Booked"
    # Everything is settled and nothing is late, which is what the owner's
    # screen should be saying by now.
    assert dashboard_html =~ "nothing overdue"
    assert dashboard_html =~ "Nothing needs you right now"

    # ---- 17. Nothing is left unprocessed in the outbox ---------------------
    assert {:ok, final} = OutboxDrainWorker.perform(%Oban.Job{args: %{}})
    assert final.skipped == 0
  end

  defp add_member(studio, name, role) do
    {:ok, user} =
      Accounts.register_user(%{
        "name" => name,
        "email" =>
          "#{String.downcase(String.replace(name, " ", "."))}-#{System.unique_integer([:positive])}@example.com",
        "password" => "a sufficiently long passphrase"
      })

    Repo.insert!(
      Accounts.Membership.changeset(%Accounts.Membership{}, %{
        user_id: user.id,
        studio_id: studio.id,
        role: role,
        status: "active"
      })
    )

    user
  end

  defp sign_in(conn, user, studio) do
    {:ok, token, _} = Accounts.create_token(user, "session")

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:studio_id, studio.id)
  end
end
