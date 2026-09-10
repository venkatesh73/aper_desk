defmodule AperDesk.Scheduling.TstzRange do
  @moduledoc """
  Ecto type mapping Postgres `tstzrange` to a `{from, to}` tuple of `DateTime`s.

  Ranges are always stored half-open `[from, to)`, which is what makes a shoot
  ending at 22:00 and one starting at 22:00 not count as a clash.
  """
  use Ecto.Type

  def type, do: :tstzrange

  def cast({%DateTime{} = from, %DateTime{} = to}), do: {:ok, {from, to}}
  def cast(%Postgrex.Range{} = range), do: {:ok, from_range(range)}
  def cast(_), do: :error

  def load(%Postgrex.Range{} = range), do: {:ok, from_range(range)}
  def load(_), do: :error

  def dump({%DateTime{} = from, %DateTime{} = to}) do
    {:ok,
     %Postgrex.Range{
       lower: from,
       upper: to,
       lower_inclusive: true,
       upper_inclusive: false
     }}
  end

  def dump(%Postgrex.Range{} = range), do: {:ok, range}
  def dump(_), do: :error

  defp from_range(%Postgrex.Range{lower: lower, upper: upper}), do: {lower, upper}

  @doc "Build a range from a start time and a duration in minutes."
  def from_duration(%DateTime{} = from, minutes) when is_integer(minutes),
    do: {from, DateTime.add(from, minutes * 60, :second)}

  @doc "Whether two half-open ranges overlap."
  def overlaps?({a_from, a_to}, {b_from, b_to}) do
    DateTime.compare(a_from, b_to) == :lt and DateTime.compare(b_from, a_to) == :lt
  end
end
