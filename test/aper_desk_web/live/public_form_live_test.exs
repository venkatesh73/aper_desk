defmodule AperDeskWeb.PublicFormLiveTest do
  @moduledoc """
  The enquiry form a studio embeds, as a stranger fills it in.

  This is the front of the whole funnel: a lead that never arrives cannot be
  quoted, booked, shot or invoiced. Two bugs here made it not arrive, and both
  are asserted below.
  """
  use AperDeskWeb.ConnCase, async: true

  import AperDesk.Fixtures
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias AperDesk.Comms
  alias AperDesk.Crm.Lead
  alias AperDesk.Repo

  setup %{conn: conn} do
    %{studio: studio, scope: scope} = studio_fixture(%{studio: %{name: "Aperture Lisboa"}})
    plan_fixture(studio)

    {:ok, form} =
      Comms.create_form(scope, %{
        "name" => "Wedding enquiry",
        "headline" => "Tell us about your day",
        "intro" => "Three short questions and your date.",
        "fields" => %{
          "fields" => [
            %{
              "key" => "shoot_type",
              "label" => "What are we photographing?",
              "type" => "select",
              "options" => ["Wedding", "Engagement", "Brand / commercial"]
            },
            %{"key" => "name", "label" => "Your name", "type" => "text", "required" => true},
            %{"key" => "email", "label" => "Email", "type" => "email", "required" => true},
            %{"key" => "message", "label" => "Anything to know?", "type" => "textarea"}
          ]
        }
      })

    %{conn: conn, studio: studio, scope: scope, form: form}
  end

  describe "the page" do
    test "puts the studio's work beside the questions", %{conn: conn, studio: studio, form: form} do
      {:ok, _view, html} = live(conn, ~p"/f/#{studio.slug}/#{form.slug}")

      assert html =~ ~s(class="pub")
      assert html =~ "Tell us about your day"
      assert html =~ "Aperture Lisboa"
    end

    test "a short choice becomes chips rather than a dropdown", %{
      conn: conn,
      studio: studio,
      form: form
    } do
      {:ok, _view, html} = live(conn, ~p"/f/#{studio.slug}/#{form.slug}")

      assert html =~ ~s(class="chips")
      assert html =~ "Engagement"
    end

    test "a chip does not name its value parameter `value`", %{
      conn: conn,
      studio: studio,
      form: form
    } do
      {:ok, _view, html} = live(conn, ~p"/f/#{studio.slug}/#{form.slug}")

      # For a button, LiveView merges the element's own `value` property into
      # the event params under "value", which silently beats the attribute and
      # arrives as "". The chips looked right and did nothing, and no
      # LiveViewTest can see it because the test client reads the attributes
      # directly. This asserts the shape that avoids the collision.
      assert html =~ "phx-value-option"
      refute html =~ "phx-value-value"
    end
  end

  # `form/3` refuses to set a hidden input, which is what a chip writes to —
  # so the chip is clicked, exactly as a client does it.
  defp choose(view, value) do
    view |> element("button[phx-click='choose'][phx-value-option='#{value}']") |> render_click()
  end

  describe "submitting" do
    test "creates a lead from what the client typed", %{
      conn: conn,
      studio: studio,
      form: form
    } do
      {:ok, view, _html} = live(conn, ~p"/f/#{studio.slug}/#{form.slug}")

      choose(view, "Wedding")

      html =
        view
        |> form("form[phx-submit=submit]", %{
          "answers" => %{
            "name" => "Lena Huber",
            "email" => "lena@example.com",
            "message" => "120 guests."
          }
        })
        |> render_submit()

      assert html =~ "Thank you" or html =~ "has your enquiry"

      lead = Repo.one!(from l in Lead, where: l.studio_id == ^studio.id)
      assert lead.source == "form"
      assert lead.shoot_type == "wedding"
    end

    test "accepts the studio's own wording for a shoot type", %{
      conn: conn,
      studio: studio,
      form: form
    } do
      {:ok, view, _html} = live(conn, ~p"/f/#{studio.slug}/#{form.slug}")

      # A studio writes options for a person to read. "Engagement" is not the
      # enum key "engagement", and passing it through made the changeset
      # invalid, rolled the transaction back, and showed the client "that did
      # not send" — so every form with readable options was broken.
      choose(view, "Engagement")

      view
      |> form("form[phx-submit=submit]", %{
        "answers" => %{"name" => "Lena", "email" => "lena@example.com"}
      })
      |> render_submit()

      assert Repo.one!(from l in Lead, where: l.studio_id == ^studio.id).shoot_type ==
               "engagement"
    end
  end

  describe "shoot_type_from/1" do
    test "maps the studio's wording onto the enum" do
      assert Comms.shoot_type_from("Wedding") == "wedding"
      assert Comms.shoot_type_from("Newborn & family") == "newborn"
      assert Comms.shoot_type_from("Brand / commercial") == "commercial"
      assert Comms.shoot_type_from("real estate") == "real_estate"
      assert Comms.shoot_type_from(nil) == "other"
      assert Comms.shoot_type_from("") == "other"
      assert Comms.shoot_type_from("balloon animals") == "other"
    end
  end
end
