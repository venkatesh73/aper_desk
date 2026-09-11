defmodule AperDesk.MoneyMajorTest do
  use ExUnit.Case, async: true

  alias AperDesk.Money

  describe "from_major/2" do
    test "reads the plain cases" do
      assert Money.from_major("4500", "USD") == 450_000
      assert Money.from_major("4500.50", "USD") == 450_050
      assert Money.from_major(4500, "USD") == 450_000
      assert Money.from_major(4500.5, "USD") == 450_050
    end

    test "does not lose a cent to binary floating point" do
      # 4500.10 * 100 is 450009.99999999994 as a float.
      assert Money.from_major("4500.10", "USD") == 450_010
      assert Money.from_major("0.07", "USD") == 7
      assert Money.from_major("19.99", "USD") == 1999
    end

    test "copes with what people actually type" do
      assert Money.from_major("$4,500.50", "USD") == 450_050
      assert Money.from_major("4 500", "USD") == 450_000
      assert Money.from_major("1.234,56", "EUR") == 123_456
      assert Money.from_major("1,234.56", "USD") == 123_456
    end

    test "respects the currency's exponent" do
      assert Money.from_major("4500", "JPY") == 4500
    end

    test "is zero rather than an exception for nonsense" do
      assert Money.from_major("", "USD") == 0
      assert Money.from_major(nil, "USD") == 0
      assert Money.from_major("about four thousand", "USD") == 0
    end
  end

  describe "to_major/2" do
    test "round-trips what from_major/2 produced" do
      for input <- ~w(4500 4500.50 0.07 19.99 1234.56) do
        cents = Money.from_major(input, "USD")
        assert Money.from_major(Money.to_major(cents, "USD"), "USD") == cents
      end
    end

    test "keeps the trailing zero a price needs" do
      assert Money.to_major(450_050, "USD") == "4500.50"
      assert Money.to_major(450_000, "USD") == "4500.00"
      assert Money.to_major(4500, "JPY") == "4500"
    end
  end
end
