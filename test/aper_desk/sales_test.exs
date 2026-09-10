defmodule AperDesk.SalesTest do
  use AperDesk.DataCase, async: false

  import AperDesk.Fixtures

  alias AperDesk.Crm.Lead
  alias AperDesk.Sales

  setup do
    %{scope: scope, studio: studio} = studio_fixture()
    plan_fixture(studio)
    contact = contact_fixture(scope)
    lead = lead_fixture(scope, %{"contact_id" => contact.id})

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

    %{scope: scope, lead: lead, quote: quote}
  end

  describe "accepting a quote" do
    test "moves the lead to booked in the same transaction", %{
      scope: scope,
      lead: lead,
      quote: quote
    } do
      {:ok, quote, _token} = Sales.send_quote(scope, quote.id)
      assert {:ok, accepted} = Sales.accept_quote(scope, quote.id)

      assert accepted.status == "accepted"
      assert Repo.get!(Lead, lead.id).stage == "booked"
    end

    test "cannot be accepted twice", %{scope: scope, quote: quote} do
      {:ok, quote, _} = Sales.send_quote(scope, quote.id)
      {:ok, _} = Sales.accept_quote(scope, quote.id)

      assert {:error, {:not_open, "accepted"}} = Sales.accept_quote(scope, quote.id)
    end

    test "an unsent draft is not open to the client", %{scope: scope, quote: quote} do
      assert {:error, {:not_open, "draft"}} = Sales.accept_quote(scope, quote.id)
    end
  end

  describe "share tokens" do
    test "resolve to the quote, and only the hash is stored", %{scope: scope, quote: quote} do
      {:ok, quote, token} = Sales.send_quote(scope, quote.id)

      assert quote.share_token_hash == :crypto.hash(:sha256, token)
      assert {:ok, found} = Sales.fetch_quote_by_token(token)
      assert found.id == quote.id
      assert {:error, :not_found} = Sales.fetch_quote_by_token("nope")
    end
  end

  describe "contracts" do
    setup %{scope: scope, lead: lead} do
      {:ok, contract} =
        Sales.create_contract(scope, %{
          "lead_id" => lead.id,
          "title" => "Wedding contract",
          "body" => "The studio agrees to shoot on the agreed date."
        })

      %{contract: contract}
    end

    test "a signature is tied to the exact text that was signed", %{
      scope: scope,
      contract: contract
    } do
      {:ok, _} =
        Sales.sign_contract(scope, contract.id, %{
          "signer_name" => "Anna",
          "signer_email" => "anna@example.com",
          "typed_name" => "Anna"
        })

      {:ok, signed} = Sales.fetch_contract(scope, contract.id)
      signature = hd(signed.signatures)

      assert Sales.signature_valid?(signed, signature)

      tampered = %{signed | body: "The studio agrees to shoot for free."}

      refute Sales.signature_valid?(tampered, signature),
             "an edited contract must not still validate against its signature"
    end

    test "cannot be signed twice", %{scope: scope, contract: contract} do
      signer = %{
        "signer_name" => "Anna",
        "signer_email" => "anna@example.com",
        "typed_name" => "Anna"
      }

      {:ok, _} = Sales.sign_contract(scope, contract.id, signer)

      assert {:error, :already_signed} =
               Sales.sign_contract(scope, contract.id, %{signer | "signer_name" => "Ben"})
    end
  end
end
