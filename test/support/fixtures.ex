defmodule AperDesk.Fixtures do
  @moduledoc """
  Test data builders.

  Every fixture takes a studio (or makes one), because almost nothing in this
  system exists outside a tenant — a fixture that quietly creates its own
  studio would let a test pass while reading another tenant's rows.
  """

  alias AperDesk.Accounts
  alias AperDesk.Billing.{Plan, Subscription}
  alias AperDesk.Repo

  def unique(prefix \\ "x"), do: "#{prefix}#{System.unique_integer([:positive])}"

  @doc "A studio with an owner, and the scope for acting as them."
  def studio_fixture(attrs \\ %{}) do
    suffix = System.unique_integer([:positive])

    {:ok, %{user: user, studio: studio}} =
      Accounts.register_owner(
        %{
          email: "owner#{suffix}@example.com",
          name: Map.get(attrs, :owner_name, "Ada Turner"),
          password: "a sufficiently long passphrase"
        },
        Map.merge(
          %{
            name: "Aperture #{suffix}",
            base_currency: "USD",
            time_zone: "Etc/UTC",
            city: "Zurich"
          },
          Map.get(attrs, :studio, %{})
        )
      )

    # Studios come back through first-run setup already, because almost no test
    # is about that gate and every one of them would otherwise be redirected to
    # it. Pass `configured: false` to get a studio that still needs setting up.
    studio =
      if Map.get(attrs, :configured, true) do
        studio
        |> Ecto.Changeset.change(
          setup_completed_at: DateTime.utc_now(),
          city: "Zurich",
          country_code: "CH"
        )
        |> Repo.update!()
      else
        studio
      end

    {:ok, scope} = Accounts.scope_for(user, studio.id)
    %{user: user, studio: studio, scope: scope}
  end

  @doc """
  The directory's categories.

  These live in `priv/repo/seeds.exs` rather than in a migration, so the test
  database has none of them — which made a category filter silently match
  nothing rather than fail. Any test that touches the directory needs this.
  """
  def categories_fixture do
    [
      {"wedding", "Wedding"},
      {"portrait", "Portrait"},
      {"newborn", "Newborn & family"},
      {"event", "Event"},
      {"commercial", "Commercial"},
      {"product", "Product"},
      {"real_estate", "Real estate"}
    ]
    |> Enum.with_index(1)
    |> Enum.map(fn {{key, name}, position} ->
      Repo.insert!(
        AperDesk.Directory.Category.changeset(%AperDesk.Directory.Category{}, %{
          key: key,
          name: name,
          position: position
        }),
        on_conflict: :nothing,
        conflict_target: :key
      )
    end)
  end

  @doc """
  A plan and an active subscription for `studio`.

  Limits default to something generous so a test that is not about limits does
  not trip over one; pass `limits:` to test the caps themselves.
  """
  def plan_fixture(studio, opts \\ []) do
    limits =
      Keyword.get(opts, :limits, %{
        "active_leads" => 1000,
        "active_galleries" => 100,
        "storage_bytes" => 107_374_182_400,
        "gallery_window_days" => 180,
        "packages" => 50,
        "forms" => 20,
        "workflows" => 50
      })

    plan =
      Repo.insert!(
        Plan.changeset(%Plan{}, %{
          key: Keyword.get(opts, :key, unique("plan")),
          name: Keyword.get(opts, :name, "Pro"),
          tagline: "For working photographers",
          monthly_price_cents: 2399,
          yearly_price_cents: 26_400,
          currency: "USD",
          public: true,
          features: ["ai_replies"],
          limits: limits
        })
      )

    Repo.insert!(
      Subscription.changeset(%Subscription{}, %{
        studio_id: studio.id,
        plan_id: plan.id,
        status: "active",
        billing_period: "monthly"
      })
    )

    plan
  end

  def contact_fixture(scope, attrs \\ %{}) do
    name = Map.get(attrs, "name", "Anna Bell")

    # The email is derived from the name. A fixed default gave every contact an
    # "anna@..." address, so searching for one name matched all of them and a
    # search test passed while proving nothing.
    slug = name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")

    {:ok, contact} =
      AperDesk.Crm.create_contact(
        scope,
        Map.merge(%{"name" => name, "email" => "#{slug}-#{unique()}@example.com"}, attrs)
      )

    contact
  end

  def lead_fixture(scope, attrs \\ %{}) do
    {:ok, lead} =
      AperDesk.Crm.create_lead(
        scope,
        Map.merge(%{"title" => "Summer wedding", "shoot_type" => "wedding"}, attrs)
      )

    lead
  end

  def invoice_fixture(scope, attrs \\ %{}) do
    {:ok, invoice} =
      AperDesk.Finance.create_invoice(
        scope,
        Map.merge(
          %{
            "currency" => "USD",
            "line_items" => [
              %{
                "description" => "Wedding package",
                "quantity" => 1,
                "unit_price_cents" => 250_000
              }
            ]
          },
          attrs
        )
      )

    invoice
  end

  def gallery_fixture(scope, attrs \\ %{}) do
    {:ok, gallery} =
      AperDesk.Galleries.create_gallery(scope, Map.merge(%{"title" => "Anna and Ben"}, attrs))

    gallery
  end

  @doc """
  A booked shoot, optionally with crew.

  `crew` takes the same shape `Scheduling.create_job/3` does — a list of maps
  with at least a `:user_id` — so a test that wants a clash books the same
  person twice rather than writing overlapping assignments by hand.
  """
  def job_fixture(scope, attrs \\ %{}, crew \\ []) do
    {from, to} = future_window()

    {:ok, job} =
      AperDesk.Scheduling.create_job(
        scope,
        Map.merge(
          %{
            "title" => "Anna and Ben",
            "shoot_type" => "wedding",
            "starts_at" => from,
            "ends_at" => to
          },
          attrs
        ),
        crew
      )

    job
  end

  @doc "A pencilled-in date that lapses in `days` unless it is confirmed."
  def hold_fixture(scope, user_id, attrs \\ %{}) do
    {from, to} = future_window()

    {:ok, assignment} =
      AperDesk.Scheduling.assign(
        scope,
        Map.merge(
          %{
            "user_id" => user_id,
            "kind" => "hold",
            "label" => "Pencilled date",
            "period" => {from, to},
            "expires_at" => DateTime.add(DateTime.utc_now(), 3 * 86_400, :second)
          },
          attrs
        )
      )

    assignment
  end

  @doc "A future window, so fixtures never clash with each other by accident."
  def future_window(offset_hours \\ 24, length_hours \\ 4) do
    from = DateTime.utc_now() |> DateTime.add(offset_hours * 3600, :second)
    {from, DateTime.add(from, length_hours * 3600, :second)}
  end
end
