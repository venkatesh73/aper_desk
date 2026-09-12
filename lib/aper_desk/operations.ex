defmodule AperDesk.Operations do
  @moduledoc """
  The kit, and where it is.

  Ops is the role that answers "can Saturday actually happen" — which is a
  different question from "is Saturday in the calendar". A shoot with two
  bodies booked and one of them at the repair shop is on the calendar and is
  not going to work.

  One item is in one pair of hands at a time, and that is enforced by a partial
  unique index rather than by a status column. Two people checking out the same
  body at the same moment is a race, and only the database can settle it — see
  `AperDesk.Operations.GearCheckout`.
  """

  import Ecto.Query

  alias AperDesk.Authorization
  alias AperDesk.Operations.{GearCheckout, GearItem}
  alias AperDesk.Repo
  alias AperDesk.Scope
  alias AperDesk.Scoped

  ## Items

  def list_gear(%Scope{} = scope, opts \\ []) do
    with :ok <- Authorization.authorize(scope, :"gear.read") do
      {:ok,
       GearItem
       |> Scoped.for_studio(scope)
       |> then(fn q ->
         if Keyword.get(opts, :include_retired, false),
           do: q,
           else: where(q, [i], is_nil(i.retired_at))
       end)
       |> order_by([i], asc: i.category, asc: i.name)
       |> Repo.all()}
    end
  end

  def create_gear(%Scope{} = scope, attrs) do
    with :ok <- Authorization.authorize(scope, :"gear.write") do
      %GearItem{}
      |> GearItem.changeset(Scoped.put_studio(attrs, scope))
      |> Repo.insert()
    end
  end

  @doc "Retire a piece of kit. Past checkouts keep naming it."
  def retire_gear(%Scope{} = scope, id) do
    with :ok <- Authorization.authorize(scope, :"gear.write"),
         {:ok, item} <- Scoped.fetch(GearItem, scope, id) do
      item |> GearItem.retire_changeset() |> Repo.update()
    end
  end

  ## Checkouts

  @doc "Everything currently out, oldest first — the overdue ones float up."
  def checked_out(%Scope{} = scope) do
    with :ok <- Authorization.authorize(scope, :"gear.read") do
      {:ok,
       GearCheckout
       |> Scoped.for_studio(scope)
       |> where([c], is_nil(c.returned_at))
       |> order_by([c], asc: c.due_back_on, asc: c.taken_at)
       |> preload([:gear_item, :user, :job])
       |> Repo.all()}
    end
  end

  @doc "Still out and past the day it was promised back."
  def overdue_gear(%Scope{} = scope, today \\ Date.utc_today()) do
    with {:ok, out} <- checked_out(scope) do
      {:ok, Enum.filter(out, &GearCheckout.overdue?(&1, today))}
    end
  end

  @doc """
  Take a piece of kit out.

  Returns `{:error, :already_out}` when somebody else has it. The index is what
  decides, so two simultaneous checkouts cannot both succeed and leave the
  studio believing it has two of something it has one of.
  """
  def check_out(%Scope{} = scope, gear_item_id, attrs \\ %{}) do
    with :ok <- Authorization.authorize(scope, :"gear.write"),
         {:ok, item} <- Scoped.fetch(GearItem, scope, gear_item_id) do
      attrs =
        attrs
        |> Map.new(fn {k, v} -> {to_string(k), v} end)
        |> Map.put("studio_id", Scope.studio_id(scope))
        |> Map.put("gear_item_id", item.id)
        |> Map.put_new("user_id", Scope.user_id(scope))
        |> Map.put_new("taken_at", DateTime.utc_now())

      %GearCheckout{}
      |> GearCheckout.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, checkout} -> {:ok, checkout}
        {:error, changeset} -> {:error, already_out_or(changeset)}
      end
    end
  end

  def check_in(%Scope{} = scope, checkout_id, note \\ nil) do
    with :ok <- Authorization.authorize(scope, :"gear.write"),
         {:ok, checkout} <- Scoped.fetch(GearCheckout, scope, checkout_id) do
      if GearCheckout.out?(checkout) do
        checkout |> GearCheckout.return_changeset(note) |> Repo.update()
      else
        {:error, :already_returned}
      end
    end
  end

  @doc """
  Items with nobody holding them, for the checkout picker.

  One query rather than a per-item lookup: a studio with sixty lenses would
  otherwise issue sixty round trips to draw a dropdown.
  """
  def available_gear(%Scope{} = scope) do
    with :ok <- Authorization.authorize(scope, :"gear.read") do
      out =
        GearCheckout
        |> Scoped.for_studio(scope)
        |> where([c], is_nil(c.returned_at))
        |> select([c], c.gear_item_id)

      {:ok,
       GearItem
       |> Scoped.for_studio(scope)
       |> where([i], is_nil(i.retired_at) and i.id not in subquery(out))
       |> order_by([i], asc: i.category, asc: i.name)
       |> Repo.all()}
    end
  end

  defp already_out_or(%Ecto.Changeset{errors: errors} = changeset) do
    if Keyword.has_key?(errors, :gear_item_id), do: :already_out, else: changeset
  end
end
