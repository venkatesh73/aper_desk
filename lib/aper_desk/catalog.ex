defmodule AperDesk.Catalog do
  @moduledoc """
  Packages: what the studio sells, what is included, and what it costs.

  Packages are never hard-deleted. A quote issued last month names the package
  it was built from, and a deleted row would turn that quote's provenance into
  a dangling id — so retiring a package archives it and it stops being offered.
  """

  import Ecto.Query

  alias AperDesk.Authorization
  alias AperDesk.Billing.Limits
  alias AperDesk.Catalog.Package
  alias AperDesk.Repo
  alias AperDesk.Scope
  alias AperDesk.Scoped
  alias Ecto.Multi

  def list_packages(%Scope{} = scope, opts \\ []) do
    Package
    |> Scoped.for_studio(scope)
    |> then(fn q ->
      if Keyword.get(opts, :include_archived, false),
        do: q,
        else: where(q, [p], is_nil(p.archived_at))
    end)
    |> preload([:items, :media])
    |> order_by([p], asc: p.position, asc: p.name)
    |> Repo.all()
  end

  @doc "Packages a client may see on the public booking page."
  def list_public_packages(studio_id) do
    Repo.all(
      from p in Package,
        where: p.studio_id == ^studio_id and p.public and is_nil(p.archived_at),
        preload: [:items, :media],
        order_by: [asc: p.position, asc: p.name]
    )
  end

  def fetch_package(%Scope{} = scope, id) do
    case Package |> Scoped.for_studio(scope) |> preload([:items, :media]) |> Repo.get(id) do
      nil -> {:error, :not_found}
      package -> {:ok, package}
    end
  end

  @doc "Create a package, subject to the plan's package limit."
  def create_package(%Scope{} = scope, attrs) do
    with :ok <- Authorization.authorize(scope, :"package.write") do
      Multi.new()
      |> Multi.run(:limit, fn repo, _ ->
        case Limits.ensure_headroom(repo, scope, "packages") do
          :ok -> {:ok, :within_limit}
          error -> error
        end
      end)
      |> Multi.insert(:package, Package.changeset(%Package{}, Scoped.put_studio(attrs, scope)))
      |> Repo.transaction()
      |> case do
        {:ok, %{package: package}} -> {:ok, package}
        {:error, _step, reason, _} -> {:error, reason}
      end
    end
  end

  def update_package(%Scope{} = scope, id, attrs) do
    with :ok <- Authorization.authorize(scope, :"package.write"),
         {:ok, package} <- fetch_package(scope, id) do
      package |> Package.changeset(attrs) |> Repo.update()
    end
  end

  def change_package(package \\ %Package{}, attrs \\ %{}),
    do: Package.changeset(package, attrs)

  def restore_package(%Scope{} = scope, id) do
    with :ok <- Authorization.authorize(scope, :"package.write"),
         {:ok, package} <- Scoped.fetch(Package, scope, id) do
      package |> Ecto.Changeset.change(archived_at: nil) |> Repo.update()
    end
  end

  @doc "Retire a package. Existing quotes that reference it are unaffected."
  def archive_package(%Scope{} = scope, id) do
    with :ok <- Authorization.authorize(scope, :"package.write"),
         {:ok, package} <- Scoped.fetch(Package, scope, id) do
      package
      |> Ecto.Changeset.change(archived_at: DateTime.utc_now())
      |> Repo.update()
    end
  end
end
