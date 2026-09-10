defmodule AperDesk.FinanceTest do
  @moduledoc """
  Money is where correctness is least negotiable, so these tests target the
  guarantees rather than the happy path: a balance that cannot be corrupted by
  concurrency, and a webhook that cannot credit twice.
  """

  # async: false — the concurrency tests spawn Tasks, which need the shared
  # sandbox. Running them async would give each Task its own connection and no
  # visibility of the fixtures.
  use AperDesk.DataCase, async: false

  import AperDesk.Fixtures

  alias AperDesk.Finance
  alias AperDesk.Finance.{Invoice, Payment}

  setup do
    %{scope: scope, studio: studio} = studio_fixture()
    plan_fixture(studio)
    %{scope: scope, studio: studio}
  end

  describe "record_payment/3" do
    test "moves the invoice through partial to paid", %{scope: scope} do
      invoice = invoice_fixture(scope)
      assert invoice.total_cents == 250_000

      assert {:ok, %{invoice: partial}} =
               Finance.record_payment(scope, invoice.id, %{
                 "amount_cents" => 100_000,
                 "method" => "bank_transfer"
               })

      assert partial.paid_cents == 100_000
      assert partial.status == "partial"
      refute partial.paid_at

      assert {:ok, %{invoice: paid}} =
               Finance.record_payment(scope, invoice.id, %{
                 "amount_cents" => 150_000,
                 "method" => "card"
               })

      assert paid.paid_cents == 250_000
      assert paid.status == "paid"
      assert paid.paid_at
    end

    test "refuses a payment in a different currency from the invoice", %{scope: scope} do
      invoice = invoice_fixture(scope)

      assert {:error, {:currency_mismatch, "EUR", "USD"}} =
               Finance.record_payment(scope, invoice.id, %{
                 "amount_cents" => 1000,
                 "currency" => "EUR"
               })
    end

    test "concurrent payments sum exactly", %{scope: scope} do
      invoice =
        invoice_fixture(scope, %{
          "line_items" => [
            %{"description" => "Album", "quantity" => 10, "unit_price_cents" => 10_000}
          ]
        })

      1..10
      |> Task.async_stream(
        fn i ->
          Finance.record_payment(scope, invoice.id, %{
            "amount_cents" => 10_000,
            "method" => "cash",
            "provider" => "manual",
            "provider_reference" => "ref_#{invoice.id}_#{i}"
          })
        end,
        max_concurrency: 10,
        timeout: 30_000
      )
      |> Stream.run()

      final = Repo.get!(Invoice, invoice.id)
      assert final.paid_cents == 100_000, "lost update under concurrency"
      assert final.status == "paid"

      # The stored balance must be re-derivable from the rows that justify it.
      sum =
        Repo.one(
          from p in Payment, where: p.invoice_id == ^invoice.id, select: sum(p.amount_cents)
        )

      assert Decimal.equal?(Decimal.new(sum), 100_000)
    end
  end

  describe "provider replays" do
    test "the same charge delivered twice credits once", %{scope: scope} do
      invoice = invoice_fixture(scope)
      reference = "ch_#{System.unique_integer([:positive])}"

      assert {:ok, %{invoice: first}} =
               Finance.apply_provider_payment(scope, invoice.id, "stripe", reference, %{
                 "amount_cents" => 250_000
               })

      assert first.paid_cents == 250_000

      assert {:error, :already_recorded} =
               Finance.apply_provider_payment(scope, invoice.id, "stripe", reference, %{
                 "amount_cents" => 250_000
               })

      assert Repo.get!(Invoice, invoice.id).paid_cents == 250_000
    end
  end

  describe "refunds" do
    test "reverse the balance and reopen the invoice", %{scope: scope} do
      invoice = invoice_fixture(scope)

      {:ok, %{payment: payment}} =
        Finance.record_payment(scope, invoice.id, %{"amount_cents" => 250_000})

      assert {:ok, %{invoice: refunded}} = Finance.refund_payment(scope, payment.id, 50_000)
      assert refunded.paid_cents == 200_000
      assert refunded.status == "partial"
    end

    test "cannot refund more than was paid", %{scope: scope} do
      invoice = invoice_fixture(scope)

      {:ok, %{payment: payment}} =
        Finance.record_payment(scope, invoice.id, %{"amount_cents" => 1000})

      assert {:error, {:refund_exceeds_payment, 1000, 5000}} =
               Finance.refund_payment(scope, payment.id, 5000)
    end
  end

  describe "authorization" do
    test "a photographer cannot record payments", %{scope: scope} do
      invoice = invoice_fixture(scope)
      photographer = %{scope | role: :photographer}

      assert {:error, :unauthorized} =
               Finance.record_payment(photographer, invoice.id, %{"amount_cents" => 100})
    end
  end
end
