defmodule AperDeskWeb.PackageMediaTest do
  use AperDeskWeb.ConnCase, async: true

  import AperDesk.Fixtures
  import AperDesk.DataCase, only: [errors_on: 1]
  import Phoenix.LiveViewTest

  alias AperDesk.Accounts
  alias AperDesk.Catalog
  alias AperDesk.Catalog.PackageMedia

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

    {:ok, package} =
      Catalog.create_package(scope, %{
        "name" => "Full day wedding",
        "price_cents" => 450_000,
        "price_currency" => "USD"
      })

    %{conn: sign_in(conn, user, studio), scope: scope, studio: studio, package: package}
  end

  # A one-pixel PNG, so the upload path carries real bytes rather than a name.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
       )

  defp upload(view, name, content, type, upload \\ :images) do
    file =
      file_input(view, "#package-media-form", upload, [
        %{name: name, content: content, type: type, size: byte_size(content)}
      ])

    render_upload(file, name)
    view |> form("#package-media-form") |> render_submit()
  end

  describe "the size limits" do
    test "an image is capped at 5 MB and a video at 10 MB" do
      assert PackageMedia.max_bytes("image") == 5 * 1_048_576
      assert PackageMedia.max_bytes("video") == 10 * 1_048_576
      assert PackageMedia.max_label("image") == "5 MB"
      assert PackageMedia.max_label("video") == "10 MB"
    end

    test "the browser is told the caps, one upload per kind", %{conn: conn, package: package} do
      {:ok, _view, html} = live(conn, ~p"/app/packages/#{package}/edit")

      # LiveView's max_file_size is per upload, so the two kinds have to be
      # separate inputs or the smaller cap cannot be enforced in the browser.
      assert html =~ "images to 5 MB, video to 10 MB"
      assert html =~ ~s(name="images")
      assert html =~ ~s(name="videos")
    end

    test "an oversized image is refused by the schema, whatever the browser said", %{
      scope: scope,
      package: package
    } do
      {:error, changeset} =
        Catalog.add_media(scope, package.id, %{
          "kind" => "image",
          "storage_key" => "studios/x/packages/y/z.jpg",
          "byte_size" => 6 * 1_048_576
        })

      assert "is larger than 5 MB — the limit for images" in errors_on(changeset).byte_size
    end

    test "a video of the same size is fine, because its cap is higher", %{
      scope: scope,
      package: package
    } do
      assert {:ok, media} =
               Catalog.add_media(scope, package.id, %{
                 "kind" => "video",
                 "storage_key" => "studios/x/packages/y/z.mp4",
                 "byte_size" => 6 * 1_048_576
               })

      assert media.kind == "video"
    end

    test "a video over 10 MB is still refused", %{scope: scope, package: package} do
      {:error, changeset} =
        Catalog.add_media(scope, package.id, %{
          "kind" => "video",
          "storage_key" => "studios/x/packages/y/z.mp4",
          "byte_size" => 11 * 1_048_576
        })

      assert "is larger than 10 MB — the limit for video" in errors_on(changeset).byte_size
    end
  end

  describe "uploading" do
    test "stores the file and attaches it to the package", %{
      conn: conn,
      scope: scope,
      studio: studio,
      package: package
    } do
      {:ok, view, html} = live(conn, ~p"/app/packages/#{package}/edit")
      assert html =~ "Nothing yet"

      upload(view, "sample.png", @png, "image/png")

      assert [media] = Catalog.list_media(scope, package.id)
      assert media.kind == "image"
      assert media.filename == "sample.png"
      assert media.byte_size == byte_size(@png)
      assert media.studio_id == studio.id

      # The key is generated under the package's own prefix, never taken from
      # the browser's filename.
      assert media.storage_key =~ "studios/#{studio.id}/packages/#{package.id}/"
      refute media.storage_key =~ "sample"
      assert File.read!(Path.join("tmp/test_uploads", media.storage_key)) == @png
    end

    test "the kind is decided from the file, not assumed", %{
      conn: conn,
      scope: scope,
      package: package
    } do
      {:ok, view, _html} = live(conn, ~p"/app/packages/#{package}/edit")

      upload(view, "clip.mp4", @png, "video/mp4", :videos)

      assert [media] = Catalog.list_media(scope, package.id)
      assert media.kind == "video"
      assert media.storage_key =~ ".mp4"
    end

    test "removing one takes the file with it", %{conn: conn, scope: scope, package: package} do
      {:ok, view, _html} = live(conn, ~p"/app/packages/#{package}/edit")
      upload(view, "sample.png", @png, "image/png")

      [media] = Catalog.list_media(scope, package.id)
      path = Path.join("tmp/test_uploads", media.storage_key)
      assert File.exists?(path)

      view |> element("button[phx-click='remove-media']") |> render_click()

      assert Catalog.list_media(scope, package.id) == []
      refute File.exists?(path)
    end
  end

  describe "the count cap" do
    test "a package shows at most twelve pieces of work", %{scope: scope, package: package} do
      for index <- 1..Catalog.media_limit() do
        assert {:ok, _} =
                 Catalog.add_media(scope, package.id, %{
                   "kind" => "image",
                   "storage_key" => "studios/x/packages/y/#{index}.jpg",
                   "byte_size" => 1024
                 })
      end

      assert {:error, {:media_limit, 12}} =
               Catalog.add_media(scope, package.id, %{
                 "kind" => "image",
                 "storage_key" => "studios/x/packages/y/last.jpg",
                 "byte_size" => 1024
               })

      assert length(Catalog.list_media(scope, package.id)) == 12
    end

    test "a refused upload leaves no file behind", %{
      conn: conn,
      scope: scope,
      studio: studio,
      package: package
    } do
      for index <- 1..Catalog.media_limit() do
        {:ok, _} =
          Catalog.add_media(scope, package.id, %{
            "kind" => "image",
            "storage_key" => "studios/x/packages/y/#{index}.jpg",
            "byte_size" => 1024
          })
      end

      {:ok, view, _html} = live(conn, ~p"/app/packages/#{package}/edit")
      html = upload(view, "one-too-many.png", @png, "image/png")

      assert html =~ "at most 12 pieces of work"

      # The object is written before the row and taken back out when the row is
      # refused, so nothing is left paying for disk under the prefix.
      prefix =
        Path.join("tmp/test_uploads", AperDesk.Storage.package_prefix(studio.id, package.id))

      refute File.exists?(prefix) and File.ls!(prefix) != []
    end
  end

  describe "new packages" do
    test "say that sample work comes after saving", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/app/packages/new")

      # There is no package to attach a file to yet, so the form says so rather
      # than showing an upload control that could not work.
      assert html =~ "Sample work comes next"
      refute html =~ "package-media-form"
    end
  end
end
