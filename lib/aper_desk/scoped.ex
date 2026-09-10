defmodule AperDesk.Scoped do
  @moduledoc """
  Query helpers that apply a `%Scope{}` to a queryable.

  Every read of tenant data goes through `for_studio/2`. Row-level security in
  Postgres is the safety net underneath, but it is deliberately not the primary
  mechanism: a query that relies on RLS alone returns an empty list when the
  session variable is unset, which looks like "no results" rather than like a
  bug. Filtering explicitly here means a missing scope raises at the boundary.
  """

  import Ecto.Query

  alias AperDesk.Repo
  alias AperDesk.Scope

  @doc """
  Restrict `queryable` to the scope's studio.

  Raises on an anonymous scope. That is the point: an unscoped query over
  tenant data is never what the caller meant, and failing loudly here is much
  cheaper than discovering it in another studio's dashboard.
  """
  def for_studio(queryable, %Scope{} = scope) do
    studio_id = scope |> Scope.require_studio!() |> Scope.studio_id()
    from(q in queryable, where: q.studio_id == ^studio_id)
  end

  @doc """
  Fetch one row by id within the scope.

  Returns `{:error, :not_found}` rather than nil for a row that exists but
  belongs to another studio, so a caller cannot tell the difference between
  "does not exist" and "not yours" — which is the correct answer to give.
  """
  def fetch(queryable, %Scope{} = scope, id) do
    case queryable |> for_studio(scope) |> Repo.get(id) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  @doc "Fetch by id, raising if absent. For paths where absence is a bug."
  def fetch!(queryable, %Scope{} = scope, id) do
    case fetch(queryable, scope, id) do
      {:ok, record} -> record
      {:error, :not_found} -> raise Ecto.NoResultsError, queryable: queryable
    end
  end

  @doc "Fetch one row matching `clauses` within the scope."
  def fetch_by(queryable, %Scope{} = scope, clauses) do
    case queryable |> for_studio(scope) |> Repo.get_by(clauses) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  @doc "Whether any row matches, without loading it."
  def exists?(queryable, %Scope{} = scope), do: queryable |> for_studio(scope) |> Repo.exists?()

  @doc "Count rows in scope."
  def count(queryable, %Scope{} = scope),
    do: queryable |> for_studio(scope) |> select([q], count(q.id)) |> Repo.one()

  @doc """
  Apply keyset pagination. Ordered by id descending, which for UUIDv7 is
  reverse-chronological — so the common "newest first" list needs no extra
  timestamp column in the index.
  """
  def paginate(queryable, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 25) |> min(100) |> max(1)

    queryable
    |> order_by([q], desc: q.id)
    |> then(fn query ->
      case Keyword.get(opts, :after) do
        nil -> query
        cursor -> from(q in query, where: q.id < ^cursor)
      end
    end)
    |> limit(^limit)
  end

  @doc "Stamp `studio_id` from the scope onto attrs, so callers cannot set it themselves."
  def put_studio(attrs, %Scope{} = scope) when is_map(attrs) do
    studio_id = scope |> Scope.require_studio!() |> Scope.studio_id()

    case attrs do
      %{__struct__: _} -> raise ArgumentError, "expected a plain map of attributes"
      _ -> attrs |> stringify_safe() |> Map.put("studio_id", studio_id)
    end
  end

  # Attrs arrive as either string-keyed (params) or atom-keyed (internal calls).
  # Mixing the two in one map means Ecto silently ignores half of them.
  defp stringify_safe(attrs) do
    if Enum.any?(Map.keys(attrs), &is_atom/1) do
      Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    else
      attrs
    end
  end
end
