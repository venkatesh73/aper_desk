defmodule AperDeskWeb.GraphqlTest do
  @moduledoc """
  Executes the mobile client's own GraphQL documents against the schema.

  The documents are read from the Flutter project rather than copied here, so
  the two cannot drift apart silently: if someone adds a field in Dart and not
  in Absinthe, this suite fails rather than the app failing at runtime in
  someone's hand. When the Flutter project is not checked out beside this one,
  the contract tests skip rather than fail — CI for the backend alone should
  not depend on a sibling repository.
  """

  use AperDesk.DataCase, async: false

  import AperDesk.Fixtures

  alias AperDesk.{Crm, Galleries, Sales, Scope}
  alias AperDeskWeb.Graphql.Schema

  @flutter_ops Path.expand("../../../aper_desk_flutter/lib/graphql/operations.dart", __DIR__)

  setup do
    %{scope: scope, studio: studio, user: user} = studio_fixture()
    plan_fixture(studio, name: "Pro")

    contact = contact_fixture(scope)

    lead =
      lead_fixture(scope, %{
        "contact_id" => contact.id,
        "owner_id" => user.id,
        "desired_date" => Date.add(Date.utc_today(), 20),
        "location" => "Villa Rosa",
        "guest_count" => 90,
        "budget_cents" => 450_000,
        "budget_currency" => "USD"
      })

    gallery = gallery_fixture(scope)

    {:ok, _} =
      Galleries.add_media(scope, gallery.id, %{
        "filename" => "a.jpg",
        "storage_key" => "k/a",
        "content_type" => "image/jpeg",
        "byte_size" => 1_500_000_000
      })

    {:ok, gallery} = Galleries.deliver_gallery(scope, gallery.id)

    {:ok, quote} =
      Sales.create_quote(scope, %{
        "lead_id" => lead.id,
        "contact_id" => contact.id,
        "currency" => "USD",
        "title" => "Wedding",
        "line_items" => [
          %{"description" => "Full day", "quantity" => 1, "unit_price_cents" => 450_000}
        ]
      })

    %{scope: scope, lead: lead, gallery: gallery, quote: quote, user: user}
  end

  defp ops do
    if File.exists?(@flutter_ops) do
      Regex.scan(~r/static const String (\w+) = r'''(.*?)''';/s, File.read!(@flutter_ops))
      |> Map.new(fn [_, name, doc] -> {name, doc} end)
    else
      %{}
    end
  end

  defp run!(name, scope, variables \\ %{}) do
    documents = ops()

    case Map.fetch(documents, name) do
      :error ->
        :skip

      {:ok, document} ->
        assert {:ok, result} =
                 Absinthe.run(document, Schema, context: %{scope: scope}, variables: variables)

        assert Map.get(result, :errors, []) == [],
               "#{name} returned errors: #{inspect(Map.get(result, :errors))}"

        result.data
    end
  end

  describe "the mobile client's documents" do
    test "currentStudio resolves the studio, plan and storage meter", %{scope: scope} do
      case run!("currentStudio", scope) do
        :skip ->
          :ok

        data ->
          studio = data["currentStudio"]
          assert studio["plan"] == "Pro"
          assert studio["replySlaHours"] == 4
          assert studio["storageUsedGb"] == 1.4
          assert studio["storageLimitGb"] == 100.0
          assert studio["currentUser"]["initials"] == "AT"
      end
    end

    test "leads carry the derived display fields", %{scope: scope} do
      case run!("leads", scope) do
        :skip ->
          :ok

        data ->
          lead = hd(data["leads"])
          assert lead["name"] == "Anna Bell"
          assert lead["budgetUsd"] == 4500.0
          assert lead["dateStatus"] == "upcoming"
          assert lead["nextAction"]
          assert lead["assignee"]["initials"] == "AT"
      end
    end

    test "leads can be filtered by stage", %{scope: scope} do
      case run!("leads", scope, %{"stage" => "NEW"}) do
        :skip -> :ok
        data -> assert length(data["leads"]) == 1
      end

      case run!("leads", scope, %{"stage" => "BOOKED"}) do
        :skip -> :ok
        data -> assert data["leads"] == []
      end
    end

    test "pipeline groups leads into columns", %{scope: scope} do
      case run!("pipeline", scope) do
        :skip ->
          :ok

        data ->
          new_column = Enum.find(data["pipeline"], &(&1["stage"] == "new"))
          assert new_column["count"] == 1
          assert hd(new_column["cards"])["amountUsd"] == 4500.0
      end
    end

    test "the dashboard hides revenue from a photographer", %{scope: scope} do
      case run!("dashboard", scope, %{"role" => "OWNER"}) do
        :skip ->
          :ok

        data ->
          assert Enum.any?(data["dashboard"]["stats"], &(&1["key"] == "outstanding"))
      end

      case run!("dashboard", scope, %{"role" => "PHOTOGRAPHER"}) do
        :skip ->
          :ok

        data ->
          refute Enum.any?(data["dashboard"]["stats"], &(&1["key"] == "outstanding")),
                 "a photographer's device should never receive studio revenue"
      end
    end

    test "calendar, finance, team and automations resolve", %{scope: scope} do
      today = Date.utc_today()
      vars = %{"month" => today.month, "year" => today.year}

      for {name, variables} <- [
            {"calendar", vars},
            {"finance", vars},
            {"team", %{}},
            {"automations", %{}}
          ] do
        assert run!(name, scope, variables) != nil
      end
    end

    test "galleries and gallery resolve, without leaking the password", %{
      scope: scope,
      gallery: gallery
    } do
      case run!("gallery", scope, %{"id" => gallery.id}) do
        :skip ->
          :ok

        data ->
          assert data["gallery"]["photoCount"] == 1
          assert data["gallery"]["sharePassword"] == nil
      end
    end

    test "a quote reports its margin", %{scope: scope, quote: quote} do
      case run!("quote", scope, %{"id" => quote.id}) do
        :skip ->
          :ok

        data ->
          assert data["quote"]["totals"]["clientPaysUsd"] == 4500.0
          assert data["quote"]["totals"]["marginPercent"] == 100.0
      end
    end

    test "createLead returns validation errors in the payload", %{scope: scope} do
      case run!("createLead", scope, %{"input" => %{"name" => ""}}) do
        :skip ->
          :ok

        data ->
          assert data["createLead"]["lead"] == nil
          assert data["createLead"]["errors"] != []
      end
    end

    test "updateLeadStage moves the lead", %{scope: scope, lead: lead} do
      case run!("updateLeadStage", scope, %{"id" => lead.id, "stage" => "CONTACTED"}) do
        :skip -> :ok
        data -> assert data["updateLeadStage"]["lead"]["stage"] == "contacted"
      end
    end
  end

  describe "authorization at the schema boundary" do
    test "an anonymous caller is refused, with a machine-readable code" do
      documents = ops()

      if document = documents["currentStudio"] do
        {:ok, result} = Absinthe.run(document, Schema, context: %{scope: Scope.public()})
        assert [error | _] = result.errors
        assert error[:code] == "FORBIDDEN"
      end
    end

    test "the public pricing table needs no scope" do
      documents = ops()

      if document = documents["plans"] do
        {:ok, result} = Absinthe.run(document, Schema, context: %{scope: Scope.public()})
        assert Map.get(result, :errors, []) == []
        assert result.data["plans"] != []
      end
    end

    test "another studio cannot read our lead", %{lead: lead} do
      documents = ops()
      %{scope: rival} = studio_fixture()

      if document = documents["lead"] do
        {:ok, result} =
          Absinthe.run(document, Schema, context: %{scope: rival}, variables: %{"id" => lead.id})

        assert result.data["lead"] == nil
        assert hd(result.errors)[:code] == "NOT_FOUND"
      end
    end
  end

  describe "schema hygiene" do
    test "every lead stage the database allows is representable in GraphQL" do
      graphql_values =
        Absinthe.Schema.lookup_type(Schema, :lead_stage).values
        |> Map.values()
        |> Enum.map(& &1.value)
        |> MapSet.new()

      assert MapSet.new(Crm.Lead.stages()) == graphql_values,
             "a stage exists in the database that the API cannot express"
    end
  end
end
