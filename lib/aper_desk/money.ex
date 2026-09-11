defmodule AperDesk.Money do
  @moduledoc """
  Money as integer minor units plus an ISO-4217 code.

  Amounts never become floats, at any point, for any reason — not for display,
  not for a quick sum, not "just in this one report". Every rounding decision is
  explicit and happens once, at the edge.
  """

  @type t :: %__MODULE__{amount: integer(), currency: String.t()}

  defstruct amount: 0, currency: "USD"

  # Currencies the product sells in. Minor-unit exponents differ (JPY has none),
  # so this is a lookup rather than an assumption of 100.
  @exponents %{"USD" => 2, "EUR" => 2, "INR" => 2, "GBP" => 2, "JPY" => 0}
  @symbols %{"USD" => "$", "EUR" => "€", "INR" => "₹", "GBP" => "£", "JPY" => "¥"}

  def new(amount, currency) when is_integer(amount) and is_binary(currency) do
    %__MODULE__{amount: amount, currency: String.upcase(currency)}
  end

  def zero(currency \\ "USD"), do: new(0, currency)

  def supported_currencies, do: Application.get_env(:aper_desk, :money)[:supported] || ["USD"]

  def exponent(currency), do: Map.get(@exponents, String.upcase(currency), 2)
  def symbol(currency), do: Map.get(@symbols, String.upcase(currency), "")

  @doc "Add two amounts. Mixing currencies is a bug, so it raises."
  def add(%__MODULE__{currency: c} = a, %__MODULE__{currency: c} = b),
    do: %__MODULE__{a | amount: a.amount + b.amount}

  def add(%__MODULE__{currency: a}, %__MODULE__{currency: b}),
    do: raise(ArgumentError, "cannot add #{a} to #{b} without an explicit conversion")

  def subtract(%__MODULE__{currency: c} = a, %__MODULE__{currency: c} = b),
    do: %__MODULE__{a | amount: a.amount - b.amount}

  @doc """
  Multiply by a quantity. Rounds half-up at the end, once — the standard for
  invoice line items, and the reason a 3 × $19.99 line reads $59.97 rather than
  $59.96999999.
  """
  def multiply(%__MODULE__{} = money, quantity) do
    product =
      quantity
      |> to_decimal()
      |> Decimal.mult(Decimal.new(money.amount))
      |> Decimal.round(0, :half_up)
      |> Decimal.to_integer()

    %__MODULE__{money | amount: product}
  end

  @doc "Apply a rate in basis points (1500 = 15%)."
  def percent_bps(%__MODULE__{} = money, bps) when is_integer(bps) do
    amount =
      money.amount
      |> Decimal.new()
      |> Decimal.mult(Decimal.new(bps))
      |> Decimal.div(Decimal.new(10_000))
      |> Decimal.round(0, :half_up)
      |> Decimal.to_integer()

    %__MODULE__{money | amount: amount}
  end

  @doc """
  Convert using an explicit rate. There is intentionally no "convert using
  today's rate" shortcut: the caller must decide *which* rate applies, because
  for an issued document the answer is the rate stored on the document.
  """
  def convert(%__MODULE__{} = money, to_currency, rate) do
    amount =
      money.amount
      |> Decimal.new()
      |> Decimal.mult(to_decimal(rate))
      |> Decimal.round(0, :half_up)
      |> Decimal.to_integer()

    new(amount, to_currency)
  end

  @doc "Render for display, e.g. `$7,200` or `€1,234.50`."
  def to_string(money, opts \\ [])

  def to_string(%__MODULE__{} = money, opts) do
    exp = exponent(money.currency)
    show_cents = Keyword.get(opts, :cents, rem(money.amount, pow10(exp)) != 0)
    sign = if money.amount < 0, do: "−", else: ""
    abs_amount = abs(money.amount)

    units = div(abs_amount, pow10(exp))
    rest = rem(abs_amount, pow10(exp))

    formatted =
      if show_cents and exp > 0 do
        "#{group(units)}.#{String.pad_leading(Integer.to_string(rest), exp, "0")}"
      else
        group(units)
      end

    "#{sign}#{symbol(money.currency)}#{formatted}"
  end

  def to_string(nil, _opts), do: "—"

  @doc """
  Parse what a person typed into integer minor units.

  People type `4500`, `4,500`, `4 500,50`, `$4500.50` or nothing at all, and
  every screen that takes money has to cope with all of it. Done through
  `Decimal` rather than `Float`, because `4500.10 * 100` is `450009.99999...`
  in binary floating point and rounding that is one cent of silent error per
  invoice line.

  Anything unparseable is `0` rather than an exception: the form's own
  validation is what should tell the reader their price is wrong, not a crash
  halfway through a changeset.
  """
  def from_major(nil, _currency), do: 0
  def from_major("", _currency), do: 0

  def from_major(value, currency) when is_integer(value),
    do: value * pow10(exponent(currency))

  def from_major(%Decimal{} = value, currency), do: scale(value, currency)

  def from_major(value, currency) when is_float(value),
    do: value |> Decimal.from_float() |> scale(currency)

  def from_major(value, currency) when is_binary(value) do
    cleaned =
      value
      |> String.replace(~r/[^\d.,+-]/, "")
      |> normalise_separators()

    case Decimal.parse(cleaned) do
      {decimal, _rest} -> scale(decimal, currency)
      :error -> 0
    end
  end

  @doc """
  Integer minor units back to the major-unit string a form field shows.

  The inverse of `from_major/2`, so a price typed as `4500.50`, saved, and
  re-opened for editing comes back as `4500.50` rather than `4500.5` or
  `4500.499999`.
  """
  def to_major(nil, _currency), do: nil

  def to_major(cents, currency) when is_integer(cents) do
    exponent = exponent(currency)

    cents
    |> Decimal.new()
    |> Decimal.div(Decimal.new(pow10(exponent)))
    |> Decimal.round(exponent)
    |> Decimal.to_string(:normal)
  end

  defp scale(%Decimal{} = value, currency) do
    value
    |> Decimal.mult(Decimal.new(pow10(exponent(currency))))
    |> Decimal.round(0)
    |> Decimal.to_integer()
  end

  # "1.234,56" is a thousands separator and a decimal comma; "1,234.56" is the
  # other way round. The last separator in the string is the decimal one, and
  # every other separator is noise — which is true of both conventions.
  defp normalise_separators(value) do
    case {String.last(String.replace(value, ~r/[^.,]/, "")), value} do
      {nil, _} ->
        value

      {",", _} ->
        value |> String.replace(".", "") |> String.replace(",", ".")

      {".", _} ->
        String.replace(value, ",", "")
    end
  end

  @doc "Convenience for the many schemas that store `*_cents` + `*_currency`."
  def from_fields(struct, prefix) do
    amount = Map.get(struct, :"#{prefix}_cents")
    currency = Map.get(struct, :"#{prefix}_currency")

    case {amount, currency} do
      {nil, _} -> nil
      {_, nil} -> nil
      {a, c} -> new(a, c)
    end
  end

  defp pow10(0), do: 1
  defp pow10(n), do: Integer.pow(10, n)

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp to_decimal(n) when is_binary(n), do: Decimal.new(n)

  # Thousands separators, done by hand rather than pulling in a locale library
  # for one function.
  defp group(units) do
    units
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.join/1)
    |> Enum.join(",")
    |> String.reverse()
  end
end
