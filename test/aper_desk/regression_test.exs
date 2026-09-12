defmodule AperDesk.RegressionTest do
  @moduledoc """
  Bugs that have already been fixed once.

  Each of these was found by the full-flow test or by an audit, and each was
  fixed in a way that is easy to undo by accident — a `mode: :savepoint` looks
  like noise, a default argument looks like a detail. They live here, named
  after the symptom rather than the mechanism, so that removing the fix fails a
  test that says what will break rather than one that says an assertion failed.
  """
  use AperDesk.DataCase, async: false

  import AperDesk.Fixtures

  alias AperDesk.{Accounts, Billing, Comms, Crm, Repo, Scheduling}

  describe "a booking clash must not poison the transaction" do
    test "the clash is reported, and the connection still works afterwards" do
      %{studio: studio, scope: scope} = studio_fixture()
      plan_fixture(studio)
      photographer = crew(studio)

      {:ok, from} = DateTime.new(Date.add(Date.utc_today(), 40), ~T[10:00:00], "Etc/UTC")
      {:ok, to} = DateTime.new(Date.add(Date.utc_today(), 40), ~T[18:00:00], "Etc/UTC")

      {:ok, _first} =
        Scheduling.create_job(
          scope,
          %{"title" => "First", "starts_at" => from, "ends_at" => to},
          [%{user_id: photographer.id}]
        )

      # The exclusion constraint firing aborts the surrounding Postgres
      # transaction. Without `mode: :savepoint` on the insert, the very next
      # statement fails with "current transaction is aborted" — including the
      # query that turns the violation into the clash detail below.
      assert {:error, {:clash, [_ | _]}} =
               Scheduling.create_job(
                 scope,
                 %{"title" => "Second", "starts_at" => from, "ends_at" => to},
                 [%{user_id: photographer.id}]
               )

      # The real assertion: the connection is still usable. Every test in this
      # suite runs inside one sandbox transaction, so a poisoned connection
      # takes everything after it down too.
      assert Repo.aggregate(Scheduling.Job, :count) == 1
      assert {:ok, _} = Crm.create_lead(scope, %{"title" => "Still working"})
    end
  end

  describe "a new studio must end up on a plan" do
    test "start_trial with no key picks the entry plan, and the studio can then work" do
      %{studio: studio, scope: scope} = studio_fixture()
      seed_plans()

      # The default used to be the key "basic", which exists in no seed file,
      # so this returned {:error, :not_found} for anybody not passing a key.
      assert {:ok, subscription} = Billing.start_trial(scope)
      assert subscription.status == "trialing"

      # And the point of having a plan: every limit check reads it, so without
      # one the studio can create nothing at all.
      {:ok, scope} = Accounts.scope_for(scope.user, studio.id)
      assert {:ok, _lead} = Crm.create_lead(scope, %{"title" => "A wedding"})
      assert {:ok, _gallery} = AperDesk.Galleries.create_gallery(scope, %{"title" => "A gallery"})
    end

    test "the entry plan is the cheapest, not whichever row came back first" do
      %{scope: scope} = studio_fixture()
      seed_plans()

      {:ok, subscription} = Billing.start_trial(scope)
      plan = Repo.get!(Billing.Plan, subscription.plan_id)

      assert plan.key == "solo"
    end

    test "a studio with no plan rows at all is refused rather than half-created" do
      %{scope: scope} = studio_fixture()

      # No plans seeded. Better an error the caller can report than a
      # subscription pointing at nothing.
      assert {:error, _reason} = Billing.start_trial(scope)
      assert is_nil(Billing.get_subscription(scope))
    end
  end

  describe "the system paths have no user and must still work" do
    test "a public form submission creates the contact and lead" do
      %{studio: studio, scope: scope} = studio_fixture()
      plan_fixture(studio)

      {:ok, form} =
        Comms.create_form(scope, %{
          "name" => "Enquiry",
          "slug" => "enquiry",
          "fields" => %{
            "fields" => [
              %{"key" => "name", "label" => "Name", "type" => "text", "required" => true},
              %{"key" => "email", "label" => "Email", "type" => "email", "required" => true}
            ]
          }
        })

      {:ok, public_form} = Comms.fetch_public_form(Repo.reload!(studio).slug, form.slug)

      # `upsert_contact/2` and `create_lead/2` are permission-gated, and the
      # public path has a tenant but nobody acting. Gating it for roles without
      # exempting the system paths refused every enquiry the studio's own
      # website sent.
      assert {:ok, %{lead: lead, contact: contact}} =
               Comms.submit_form(public_form, %{"name" => "Anna", "email" => "anna@example.com"})

      assert contact.email == "anna@example.com"
      assert lead.contact_id == contact.id
    end

    test "a real user with no permission is still refused" do
      %{studio: studio, scope: scope} = studio_fixture()
      plan_fixture(studio)

      hr = crew(studio, "hr")
      {:ok, hr_scope} = Accounts.scope_for(hr, studio.id)

      # The exemption is for a scope with no user at all. A person holding no
      # `lead.write` must not slip through it.
      assert {:error, :unauthorized} = Crm.create_lead(hr_scope, %{"title" => "Nope"})
      assert {:error, :unauthorized} = Crm.upsert_contact(hr_scope, %{"name" => "Nope"})
    end
  end

  defp crew(studio, role \\ "photographer") do
    {:ok, user} =
      Accounts.register_user(%{
        "name" => "Crew",
        "email" => "crew-#{System.unique_integer([:positive])}@example.com",
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

  defp seed_plans do
    for {key, name, price, position} <- [
          {"studio", "Studio", 2399, 2},
          {"solo", "Solo", 1500, 1},
          {"agency", "Agency", 3499, 3}
        ] do
      Repo.insert!(
        Billing.Plan.changeset(%Billing.Plan{}, %{
          key: key,
          name: name,
          tagline: "For photographers",
          monthly_price_cents: price,
          yearly_price_cents: price * 11,
          currency: "USD",
          public: true,
          position: position,
          features: [],
          limits: %{
            "active_leads" => 50,
            "active_galleries" => 10,
            "storage_bytes" => 10_737_418_240,
            "gallery_window_days" => 60,
            "packages" => 10,
            "seats" => 3
          }
        })
      )
    end
  end
end
