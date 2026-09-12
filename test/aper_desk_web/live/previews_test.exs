defmodule AperDeskWeb.PreviewsTest do
  use AperDeskWeb.ConnCase, async: true

  import AperDesk.Fixtures
  import Phoenix.LiveViewTest

  alias AperDesk.Accounts
  alias AperDesk.Catalog
  alias AperDesk.Comms
  alias AperDesk.Sales

  defp sign_in(conn, user, studio) do
    {:ok, token, _} = Accounts.create_token(user, "session")

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:studio_id, studio.id)
  end

  setup %{conn: conn} do
    %{user: user, studio: studio, scope: scope} = studio_fixture()
    plan_fixture(studio)
    %{conn: sign_in(conn, user, studio), scope: scope, studio: studio}
  end

  describe "an email template preview" do
    setup %{scope: scope} do
      {:ok, template} =
        Comms.create_template(scope, %{
          "key" => "enquiry_reply",
          "name" => "Enquiry reply",
          "subject" => "About your {{shoot_type}} on {{shoot_date}}",
          "body" => "Hi {{first_name}},\n\n{{studio_name}} would love to shoot it. {{total}}."
        })

      %{template: template}
    end

    test "fills the tokens with sample details rather than blanks", %{
      conn: conn,
      studio: studio,
      template: template
    } do
      {:ok, view, _html} = live(conn, ~p"/app/templates?tab=email")

      html =
        view
        |> element("button[phx-click='preview'][phx-value-id='#{template.id}']")
        |> render_click()

      assert html =~ "Hi Anna,"
      assert html =~ studio.name
      assert html =~ "About your Wedding on"

      # A preview full of empty strings shows a layout the studio never sends.
      refute html =~ "{{first_name}}"
      refute html =~ "{{studio_name}}"
    end

    test "shows it as a message, with the header the client sees", %{
      conn: conn,
      template: template
    } do
      {:ok, view, _html} = live(conn, ~p"/app/templates?tab=email")

      html =
        view
        |> element("button[phx-click='preview'][phx-value-id='#{template.id}']")
        |> render_click()

      assert html =~ "mailprev"
      assert html =~ "anna@example.com"
    end

    test "closes again", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/app/templates?tab=email")

      view
      |> element("button[phx-click='preview'][phx-value-id='#{template.id}']")
      |> render_click()

      html = view |> element("#template-preview button[aria-label='Close']") |> render_click()
      refute html =~ "template-preview"
    end
  end

  describe "a contract preview" do
    test "renders the same tokens an email would", %{conn: conn, scope: scope, studio: studio} do
      {:ok, template} =
        Sales.create_template(scope, %{
          "name" => "Wedding contract",
          "body" => "{{studio_name}} agrees to photograph {{name}} at {{venue}}.",
          "requires_deposit" => true
        })

      {:ok, view, _html} = live(conn, ~p"/app/templates?tab=contract")

      html =
        view
        |> element("button[phx-click='preview'][phx-value-id='#{template.id}']")
        |> render_click()

      assert html =~ "#{studio.name} agrees to photograph Anna Bell at Quinta da Regaleira."
      assert html =~ "deposit of"
      assert html =~ "docprev-sign"
    end
  end

  describe "a questionnaire preview" do
    test "shows the form the client actually fills in", %{conn: conn, scope: scope} do
      {:ok, form} =
        Comms.create_form(scope, %{
          "name" => "Wedding enquiry",
          "headline" => "Tell us about your day",
          "intro" => "Two minutes, and we will come back within four hours.",
          "success_message" => "Thank you — we will be in touch.",
          "fields" => %{
            "fields" => [
              %{"key" => "name", "label" => "Your name", "type" => "text", "required" => true},
              %{"key" => "date", "label" => "The date", "type" => "date"},
              %{
                "key" => "style",
                "label" => "What style",
                "type" => "select",
                "options" => ["Documentary", "Classic"]
              }
            ]
          }
        })

      {:ok, view, _html} = live(conn, ~p"/app/templates?tab=questionnaire")

      html =
        view
        |> element("button[phx-click='preview'][phx-value-id='#{form.id}']")
        |> render_click()

      assert html =~ "Tell us about your day"
      assert html =~ "Your name"
      assert html =~ ~s(type="date")
      assert html =~ "Documentary"
      assert html =~ "Required"
      assert html =~ "Thank you — we will be in touch."
    end

    test "says so when there are no questions", %{conn: conn, scope: scope} do
      {:ok, form} = Comms.create_form(scope, %{"name" => "Empty", "headline" => "Hello"})

      {:ok, view, _html} = live(conn, ~p"/app/templates?tab=questionnaire")

      html =
        view
        |> element("button[phx-click='preview'][phx-value-id='#{form.id}']")
        |> render_click()

      # Wrapped across lines in the template, so match the part that cannot wrap.
      assert html =~ "No questions yet"
    end
  end

  describe "previewing a draft" do
    test "renders what is on the form, without saving it first", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/app/templates/email/new")

      view
      |> form("form")
      |> render_change(%{
        "template" => %{
          "key" => "draft_reply",
          "name" => "Draft",
          "subject" => "Hello {{first_name}}",
          "body" => "We would love to shoot your {{shoot_type}}."
        }
      })

      html = view |> element("button[phx-click='preview-draft']") |> render_click()

      assert html =~ "Hello Anna"
      assert html =~ "We would love to shoot your Wedding."

      # The question a studio asks while writing is "does this read right", and
      # answering it must not require saving a half-finished draft.
      assert Comms.list_templates(scope) == []
    end
  end

  describe "the modal itself" do
    test "the backdrop is behind the panel, not wrapped around it", %{
      conn: conn,
      scope: scope
    } do
      {:ok, template} =
        Comms.create_template(scope, %{
          "key" => "k",
          "name" => "Any",
          "subject" => "s",
          "body" => "b"
        })

      {:ok, view, _html} = live(conn, ~p"/app/templates?tab=email")

      html =
        view
        |> element("button[phx-click='preview'][phx-value-id='#{template.id}']")
        |> render_click()

      # A wrapper is the obvious shape and it is wrong: a click inside the
      # panel bubbles to the wrapper and closes the thing being read.
      assert html =~ ~s(<div class="modal-backdrop" phx-click="close-preview")
      refute html =~ ~s(class="modal-layer" phx-click)

      [panel] = Regex.run(~r/<div class="modal wide"[^>]*>/, html)
      refute panel =~ "phx-click"
    end
  end

  describe "media previews" do
    @png Base.decode64!(
           "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
         )

    test "a package thumbnail opens the file at full size", %{conn: conn, scope: scope} do
      {:ok, package} =
        Catalog.create_package(scope, %{
          "name" => "Full day",
          "price_cents" => 450_000,
          "price_currency" => "USD"
        })

      {:ok, view, _html} = live(conn, ~p"/app/packages/#{package}/edit")

      file =
        file_input(view, "#package-media-form", :images, [
          %{name: "sample.png", content: @png, type: "image/png", size: byte_size(@png)}
        ])

      render_upload(file, "sample.png")
      view |> form("#package-media-form") |> render_submit()

      [media] = Catalog.list_media(scope, package.id)

      html = view |> element("div[phx-value-id='#{media.id}']") |> render_click()

      assert html =~ "media-preview"
      assert html =~ "sample.png"
      assert html =~ AperDesk.Storage.url(media.storage_key)
    end

    test "removing from inside the preview closes it", %{conn: conn, scope: scope} do
      {:ok, package} =
        Catalog.create_package(scope, %{
          "name" => "Half day",
          "price_cents" => 200_000,
          "price_currency" => "USD"
        })

      {:ok, view, _html} = live(conn, ~p"/app/packages/#{package}/edit")

      file =
        file_input(view, "#package-media-form", :images, [
          %{name: "sample.png", content: @png, type: "image/png", size: byte_size(@png)}
        ])

      render_upload(file, "sample.png")
      view |> form("#package-media-form") |> render_submit()

      [media] = Catalog.list_media(scope, package.id)
      view |> element("div[phx-value-id='#{media.id}']") |> render_click()

      html = view |> element("#media-preview button[phx-click*='remove-media']") |> render_click()

      refute html =~ "media-preview"
      assert Catalog.list_media(scope, package.id) == []
    end
  end
end
