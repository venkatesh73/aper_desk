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
  alias AperDesk.Catalog.{Package, PackageMedia}
  alias AperDesk.Repo
  alias AperDesk.Scope
  alias AperDesk.Scoped
  alias AperDesk.Storage
  alias Ecto.Multi

  def list_packages(%Scope{} = scope, opts \\ []) do
    with :ok <- Authorization.authorize(scope, :"package.read") do
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
    with :ok <- Authorization.authorize(scope, :"package.read") do
      case Package |> Scoped.for_studio(scope) |> preload([:items, :media]) |> Repo.get(id) do
        nil -> {:error, :not_found}
        package -> {:ok, package}
      end
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

  ## Sample work

  @doc "How many pieces of sample work one package may carry."
  @media_limit 12

  def media_limit, do: @media_limit

  @doc """
  Attach a piece of sample work to a package.

  The count check and the insert share a transaction, and the count is taken
  under a lock on the package row. Two uploads finishing at the same moment
  would otherwise both read eleven and both insert, which is how a "maximum of
  twelve" quietly becomes thirteen.

  Size is validated by `PackageMedia.changeset/2` against the bytes actually
  written, not against what the browser claimed.
  """
  def add_media(%Scope{} = scope, package_id, attrs) do
    with :ok <- Authorization.authorize(scope, :"package.write"),
         {:ok, package} <- Scoped.fetch(Package, scope, package_id) do
      Multi.new()
      |> Multi.run(:lock, fn repo, _ ->
        {:ok,
         repo.one(from p in Package, where: p.id == ^package.id, lock: "FOR UPDATE", select: p.id)}
      end)
      |> Multi.run(:headroom, fn repo, _ ->
        used = repo.aggregate(from(m in PackageMedia, where: m.package_id == ^package.id), :count)

        if used < @media_limit,
          do: {:ok, used},
          else: {:error, {:media_limit, @media_limit}}
      end)
      |> Multi.insert(:media, fn %{headroom: used} ->
        PackageMedia.changeset(
          %PackageMedia{},
          attrs
          |> Scoped.put_studio(scope)
          |> Map.put("package_id", package.id)
          |> Map.put_new("position", used)
        )
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{media: media}} -> {:ok, media}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  @doc """
  Detach a piece of sample work and delete the file behind it.

  The row goes first, for the same reason it does in `Galleries.remove_media/2`:
  an orphaned object costs disk until a sweep finds it, while a row pointing at
  a file that is already gone is a broken image on the studio's own shopfront.
  """
  def remove_media(%Scope{} = scope, media_id) do
    with :ok <- Authorization.authorize(scope, :"package.write"),
         {:ok, media} <- Scoped.fetch(PackageMedia, scope, media_id),
         {:ok, media} <- Repo.delete(media) do
      if media.storage_key, do: Storage.delete(media.storage_key)
      {:ok, media}
    end
  end

  def list_media(%Scope{} = scope, package_id) do
    with :ok <- Authorization.authorize(scope, :"package.read") do
      PackageMedia
      |> Scoped.for_studio(scope)
      |> where([m], m.package_id == ^package_id)
      |> order_by([m], asc: m.position, asc: m.filename)
      |> Repo.all()
    end
  end
end
