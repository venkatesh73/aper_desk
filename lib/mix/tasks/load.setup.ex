defmodule Mix.Tasks.Load.Setup do
  @shortdoc "Seed a studio for load testing and print the k6 arguments"

  @moduledoc """
  Creates the rows the load scripts need and prints the exact commands.

  Load tests write real data, so the alternative is a person hand-copying UUIDs
  out of a console — which is how a load run ends up pointed at the wrong
  studio, or at production. This prints the whole command line.

      mix load.setup

  Idempotent: running it twice reuses the same studio rather than filling the
  database with load-test tenants.
  """
  use Mix.Task

  import Ecto.Query

  alias AperDesk.{Accounts, Billing, Comms, Galleries, Repo, Scope, Storage}

  @email "load@aperdesk.test"
  @password "load testing passphrase"

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    {user, studio} = studio()
    membership = Repo.get_by!(Accounts.Membership, user_id: user.id, studio_id: studio.id)
    scope = Scope.for_membership(user, studio, membership)

    ensure_plan(scope, studio)
    form = ensure_form(scope, studio)
    token = ensure_shared_gallery(scope, studio)

    base = "http://localhost:4000"

    Mix.shell().info("""

    Load-test fixtures ready.

      studio    #{studio.name} (#{studio.slug})
      sign in   #{@email} / #{@password}

    Run these against a server that is NOT production:

      k6 run load/browse.js -e BASE=#{base}

      k6 run load/public_form.js -e BASE=#{base} \\
        -e STUDIO=#{studio.slug} -e FORM=#{form.slug}

      k6 run load/client_gallery.js -e BASE=#{base} \\
        -e TOKEN=#{token}

    The gallery token is minted fresh each run, because only its hash is
    stored and the old one cannot be read back.
    """)
  end

  defp studio do
    case Repo.get_by(Accounts.User, email: @email) do
      nil ->
        {:ok, %{user: user, studio: studio}} =
          Accounts.register_owner(
            %{"name" => "Load Tester", "email" => @email, "password" => @password},
            %{
              "name" => "Load Testing Studio",
              "time_zone" => "Etc/UTC",
              "base_currency" => "USD",
              "setup_completed_at" => DateTime.utc_now()
            }
          )

        {user, studio}

      user ->
        studio =
          Repo.one!(
            from s in Accounts.Studio,
              join: m in Accounts.Membership,
              on: m.studio_id == s.id,
              where: m.user_id == ^user.id,
              limit: 1
          )

        {user, studio}
    end
  end

  defp ensure_plan(scope, _studio) do
    case Billing.get_subscription(scope) do
      nil -> Billing.start_trial(scope)
      subscription -> {:ok, subscription}
    end
  end

  defp ensure_form(scope, studio) do
    case Repo.get_by(Comms.LeadCaptureForm, studio_id: studio.id, slug: "enquiry") do
      nil ->
        {:ok, form} =
          Comms.create_form(scope, %{
            "name" => "Enquiry",
            "slug" => "enquiry",
            "headline" => "Tell us about your day",
            "fields" => %{
              "fields" => [
                %{"key" => "name", "label" => "Your name", "type" => "text", "required" => true},
                %{"key" => "email", "label" => "Email", "type" => "email", "required" => true}
              ]
            }
          })

        form

      form ->
        form
    end
  end

  # A delivered gallery with a frame in it, so the spike script is measuring a
  # page that actually renders images rather than an empty state.
  defp ensure_shared_gallery(scope, studio) do
    gallery =
      case Repo.get_by(Galleries.Gallery, studio_id: studio.id, slug: "load-test") do
        nil ->
          {:ok, gallery} =
            Galleries.create_gallery(scope, %{"title" => "Load test", "slug" => "load-test"})

          seed_media(scope, studio, gallery)
          {:ok, delivered} = Galleries.deliver_gallery(scope, gallery.id)
          delivered

        gallery ->
          gallery
      end

    {:ok, _share, token} =
      Galleries.share_gallery(scope, gallery.id, %{"label" => "Load test"})

    token
  end

  defp seed_media(scope, studio, gallery) do
    png =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
      )

    path = Path.join(System.tmp_dir!(), "load-seed.png")
    File.write!(path, png)

    for index <- 1..12 do
      key = Storage.key_in(Storage.gallery_prefix(studio.id, gallery.id), "frame-#{index}.png")
      {:ok, key} = Storage.put(key, path, content_type: "image/png")

      Galleries.add_media(scope, gallery.id, %{
        "filename" => "frame-#{index}.png",
        "storage_key" => key,
        "content_type" => "image/png",
        "byte_size" => byte_size(png)
      })
    end

    File.rm(path)
  end
end
