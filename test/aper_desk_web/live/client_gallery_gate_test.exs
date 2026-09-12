defmodule AperDeskWeb.ClientGalleryGateTest do
  @moduledoc """
  The code in front of a gated gallery.

  Every test here fails if the gate is removed, which is the point: the toggle
  existed and was persisted and read by the API long before anything enforced
  it, and a suite that only checks the toggle saves would have stayed green
  through all of that.
  """
  use AperDeskWeb.ConnCase, async: true

  import AperDesk.Fixtures
  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias AperDesk.Galleries

  @client "couple@example.com"

  setup %{conn: conn} do
    %{studio: studio, scope: scope} = studio_fixture()
    plan_fixture(studio)
    gallery = gallery_fixture(scope, %{"title" => "Anna and Ben"})

    {:ok, media} =
      Galleries.add_media(scope, gallery.id, %{
        "filename" => "IMG_0001.jpg",
        "storage_key" => "studios/x/galleries/y/secret-frame.jpg",
        "content_type" => "image/jpeg",
        "byte_size" => 1024
      })

    %{conn: conn, scope: scope, gallery: gallery, media: media}
  end

  defp gate(scope, gallery) do
    {:ok, _gallery} = Galleries.update_gallery(scope, gallery.id, %{"requires_otp" => true})
    :ok
  end

  defp share(scope, gallery, email \\ @client) do
    attrs = %{"label" => "The couple"}
    attrs = if email, do: Map.put(attrs, "email", email), else: attrs
    {:ok, _share, token} = Galleries.share_gallery(scope, gallery.id, attrs)
    token
  end

  # Read straight from the mailbox rather than through `assert_email_sent/1`,
  # which consumes the message it matched and leaves nothing to pull the code
  # out of.
  defp code_from_mail do
    assert_received {:email, %Swoosh.Email{to: [{_name, @client}], text_body: body}}
    [code] = Regex.run(~r/Your code is (\d{6})/, body, capture: :all_but_first)
    code
  end

  describe "a gallery that asks for a code" do
    test "shows the gate instead of the photographs", %{
      conn: conn,
      scope: scope,
      gallery: gallery,
      media: media
    } do
      :ok = gate(scope, gallery)
      token = share(scope, gallery)

      {:ok, _view, html} = live(conn, ~p"/g/#{token}")

      assert html =~ "Email me a code"
      assert html =~ "Anna and Ben"

      # The gate must not merely decline to draw the photographs — they must
      # never reach the socket. A storage key in the HTML is a working URL.
      refute html =~ media.storage_key
      refute html =~ "secret-frame"
      refute html =~ "masonry"
    end

    test "mails the code to the address the studio named, not the one typed in", %{
      conn: conn,
      scope: scope,
      gallery: gallery
    } do
      :ok = gate(scope, gallery)
      token = share(scope, gallery)

      {:ok, view, _html} = live(conn, ~p"/g/#{token}")

      html =
        view
        |> form("form[phx-submit=request-code]", %{"email" => "stranger@example.com"})
        |> render_submit()

      # Same page as a match, so the form cannot be used to find out whose
      # gallery this is — but nothing was sent.
      assert html =~ "six-digit code"
      refute_email_sent()
    end

    test "opens once the right code is given, and stays open on a refresh", %{
      conn: conn,
      scope: scope,
      gallery: gallery,
      media: media
    } do
      :ok = gate(scope, gallery)
      token = share(scope, gallery)

      {:ok, view, _html} = live(conn, ~p"/g/#{token}")

      view
      |> form("form[phx-submit=request-code]", %{"email" => @client})
      |> render_submit()

      code = code_from_mail()

      {:error, {:redirect, %{to: unlock}}} =
        view
        |> form("form[phx-submit=submit-code]", %{"code" => code})
        |> render_submit()

      assert unlock =~ "/unlock?pass="

      # Through the controller, which is the only thing that can write the
      # session, and back to the gallery.
      conn = get(conn, unlock)
      assert redirected_to(conn) == "/g/#{token}"

      {:ok, _view, html} = live(conn, ~p"/g/#{token}")
      assert html =~ media.filename
      refute html =~ "Email me a code"

      # A second load must not ask again: the unlock is in the session, not in
      # the socket that redeemed it.
      {:ok, _view, again} = live(conn, ~p"/g/#{token}")
      assert again =~ media.filename
    end

    test "refuses a wrong code and does not open", %{conn: conn, scope: scope, gallery: gallery} do
      :ok = gate(scope, gallery)
      token = share(scope, gallery)

      {:ok, view, _html} = live(conn, ~p"/g/#{token}")

      view
      |> form("form[phx-submit=request-code]", %{"email" => @client})
      |> render_submit()

      html =
        view
        |> form("form[phx-submit=submit-code]", %{"code" => "000000"})
        |> render_submit()

      assert html =~ "not right"
      refute html =~ "masonry"
    end

    test "will not mail a second code within the minute", %{
      conn: conn,
      scope: scope,
      gallery: gallery
    } do
      :ok = gate(scope, gallery)
      token = share(scope, gallery)

      {:ok, view, _html} = live(conn, ~p"/g/#{token}")

      for _ <- 1..3 do
        view |> form("form[phx-submit=request-code]", %{"email" => @client}) |> render_submit()
        view |> render_click("start-over", %{})
      end

      assert_email_sent()
      refute_email_sent()
    end

    test "says so when the studio gated a link it never addressed to anyone", %{
      conn: conn,
      scope: scope,
      gallery: gallery
    } do
      :ok = gate(scope, gallery)
      token = share(scope, gallery, nil)

      {:ok, _view, html} = live(conn, ~p"/g/#{token}")

      assert html =~ "needs a name on it"
      refute html =~ "Email me a code"
    end
  end

  describe "a gallery that does not ask for a code" do
    test "opens straight away", %{conn: conn, scope: scope, gallery: gallery, media: media} do
      token = share(scope, gallery)

      {:ok, _view, html} = live(conn, ~p"/g/#{token}")

      assert html =~ media.filename
      refute html =~ "Email me a code"
    end
  end
end
