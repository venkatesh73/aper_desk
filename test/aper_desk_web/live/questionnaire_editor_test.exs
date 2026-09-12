defmodule AperDeskWeb.QuestionnaireEditorTest do
  @moduledoc """
  The editor that was promised and did not exist.

  Before this, the form said "Questions are added on the form's own page once
  it exists" — and there was no such page. A studio could create a
  questionnaire, preview it, be told it had no questions, and have no way at
  all to fix that.
  """
  use AperDeskWeb.ConnCase, async: true

  import AperDesk.Fixtures
  import Phoenix.LiveViewTest

  alias AperDesk.Accounts
  alias AperDesk.Comms
  alias AperDesk.Comms.LeadCaptureForm

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
    %{conn: sign_in(conn, user, studio), scope: scope}
  end

  defp form_fixture(scope, fields \\ []) do
    {:ok, form} =
      Comms.create_form(scope, %{
        "name" => "Wedding enquiry",
        "headline" => "Tell us about your day",
        "fields" => %{"fields" => fields}
      })

    form
  end

  test "adds questions to a form that had none", %{conn: conn, scope: scope} do
    form = form_fixture(scope)
    {:ok, view, html} = live(conn, ~p"/app/templates/questionnaire/#{form}/edit")

    assert html =~ "No questions yet"

    view |> element("button[phx-click='add-question']") |> render_click()
    view |> element("button[phx-click='add-question']") |> render_click()

    view
    |> form("form")
    |> render_submit(%{
      "template" => %{
        "name" => "Wedding enquiry",
        "questions" => %{
          "0" => %{"key" => "", "label" => "Your names", "type" => "text", "required" => "true"},
          "1" => %{"key" => "", "label" => "The date", "type" => "date", "required" => "false"}
        }
      }
    })

    {:ok, saved} = Comms.fetch_form(scope, form.id)
    fields = LeadCaptureForm.field_list(saved)

    assert Enum.map(fields, & &1["label"]) == ["Your names", "The date"]
    assert Enum.map(fields, & &1["type"]) == ["text", "date"]

    # A key is derived from the label so a submission has something stable to
    # arrive under.
    assert Enum.map(fields, & &1["key"]) == ["your_names", "the_date"]
    assert Enum.map(fields, & &1["required"]) == [true, false]
  end

  test "a select question keeps its choices", %{conn: conn, scope: scope} do
    form = form_fixture(scope)
    {:ok, view, _html} = live(conn, ~p"/app/templates/questionnaire/#{form}/edit")

    view |> element("button[phx-click='add-question']") |> render_click()

    view
    |> form("form")
    |> render_submit(%{
      "template" => %{
        "name" => "Wedding enquiry",
        "questions" => %{
          "0" => %{
            "key" => "",
            "label" => "What style",
            "type" => "select",
            "options" => "Documentary\nClassic\n\nA mix\n"
          }
        }
      }
    })

    {:ok, saved} = Comms.fetch_form(scope, form.id)
    [field] = LeadCaptureForm.field_list(saved)

    # Blank lines are the author pressing return, not an unnamed choice.
    assert field["options"] == ["Documentary", "Classic", "A mix"]
  end

  test "renaming a question does not orphan its answers", %{conn: conn, scope: scope} do
    form =
      form_fixture(scope, [
        %{"key" => "couple_names", "label" => "Your names", "type" => "text"}
      ])

    {:ok, view, _html} = live(conn, ~p"/app/templates/questionnaire/#{form}/edit")

    view
    |> form("form")
    |> render_submit(%{
      "template" => %{
        "name" => "Wedding enquiry",
        "questions" => %{
          "0" => %{"key" => "couple_names", "label" => "What are your names?", "type" => "text"}
        }
      }
    })

    {:ok, saved} = Comms.fetch_form(scope, form.id)
    [field] = LeadCaptureForm.field_list(saved)

    assert field["label"] == "What are your names?"
    # Submissions already collected arrive under the old key; changing it would
    # strand them.
    assert field["key"] == "couple_names"
  end

  test "reorders questions, which is the bit a list cannot show", %{conn: conn, scope: scope} do
    form =
      form_fixture(scope, [
        %{"key" => "a", "label" => "First", "type" => "text"},
        %{"key" => "b", "label" => "Second", "type" => "text"}
      ])

    {:ok, view, _html} = live(conn, ~p"/app/templates/questionnaire/#{form}/edit")

    view
    |> element("button[phx-value-index='1'][phx-value-by='-1']")
    |> render_click()

    view |> form("form") |> render_submit(%{"template" => %{"name" => "Wedding enquiry"}})

    {:ok, saved} = Comms.fetch_form(scope, form.id)
    assert saved |> LeadCaptureForm.field_list() |> Enum.map(& &1["label"]) == ["Second", "First"]
  end

  test "removes a question", %{conn: conn, scope: scope} do
    form =
      form_fixture(scope, [
        %{"key" => "a", "label" => "Keep me", "type" => "text"},
        %{"key" => "b", "label" => "Drop me", "type" => "text"}
      ])

    {:ok, view, _html} = live(conn, ~p"/app/templates/questionnaire/#{form}/edit")

    view |> element("button[phx-click='remove-question'][phx-value-index='1']") |> render_click()
    view |> form("form") |> render_submit(%{"template" => %{"name" => "Wedding enquiry"}})

    {:ok, saved} = Comms.fetch_form(scope, form.id)
    assert saved |> LeadCaptureForm.field_list() |> Enum.map(& &1["label"]) == ["Keep me"]
  end

  test "a half-typed question survives the next keystroke", %{conn: conn, scope: scope} do
    form = form_fixture(scope)
    {:ok, view, _html} = live(conn, ~p"/app/templates/questionnaire/#{form}/edit")

    view |> element("button[phx-click='add-question']") |> render_click()

    html =
      view
      |> form("form")
      |> render_change(%{
        "template" => %{
          "name" => "Wedding enquiry",
          "questions" => %{"0" => %{"key" => "", "label" => "Half typ", "type" => "text"}}
        }
      })

    # Reading the questions back off the changeset would lose them, because
    # `fields` is a map column rather than a cast association.
    assert html =~ "Half typ"
  end

  test "the preview shows what was just added", %{conn: conn, scope: scope} do
    form = form_fixture(scope)
    {:ok, view, _html} = live(conn, ~p"/app/templates/questionnaire/#{form}/edit")

    view |> element("button[phx-click='add-question']") |> render_click()

    view
    |> form("form")
    |> render_change(%{
      "template" => %{
        "name" => "Wedding enquiry",
        "questions" => %{"0" => %{"key" => "", "label" => "Your names", "type" => "text"}}
      }
    })

    html = view |> element("button[phx-click='preview-draft']") |> render_click()

    assert html =~ "Your names"
    refute html =~ "No questions yet"
  end
end
