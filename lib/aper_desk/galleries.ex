defmodule AperDesk.Galleries do
  @moduledoc """
  Client delivery galleries: uploads, sharing, selections, expiry.

  Storage is the plan's main pricing lever, so the cap has to hold on the
  request that would exceed it. `add_media/3` reserves headroom under a row
  lock in the same transaction as the insert — see `AperDesk.Billing.Limits`
  for why a read-then-write is not sufficient.

  Client access is by hashed share token, never by gallery id. Only the hash is
  stored, so a leaked backup does not hand anyone a working link to a couple's
  wedding photographs.
  """

  import Ecto.Query

  alias AperDesk.Authorization
  alias AperDesk.Billing.Limits
  alias AperDesk.Events

  alias AperDesk.Galleries.Notifier
  alias AperDesk.Galleries.Workers.DeriveMediaWorker

  alias AperDesk.Galleries.{
    Gallery,
    GalleryAccessCode,
    GalleryMedia,
    GallerySelection,
    GalleryShare
  }

  alias AperDesk.Repo
  alias AperDesk.Scope
  alias AperDesk.Scoped
  alias AperDesk.Visibility
  alias AperDesk.Storage
  alias Ecto.Multi

  ## Galleries

  def list_galleries(%Scope{} = scope, opts \\ []) do
    with :ok <- Authorization.authorize(scope, :"gallery.read") do
      {:ok,
       Gallery
       |> from(as: :gallery)
       |> Scoped.for_studio(scope)
       |> Visibility.galleries(scope)
       |> then(fn q ->
         case opts[:status] do
           nil -> q
           status -> where(q, [g], g.status == ^status)
         end
       end)
       |> order_by([g], desc: g.inserted_at)
       |> Scoped.paginate(opts)
       |> Repo.all()}
    end
  end

  def fetch_gallery(%Scope{} = scope, id) do
    with :ok <- Authorization.authorize(scope, :"gallery.read"),
         {:ok, gallery} <- Scoped.fetch(Gallery, scope, id) do
      if Visibility.visible?(scope, gallery), do: {:ok, gallery}, else: {:error, :unauthorized}
    end
  end

  @doc "Create a gallery, subject to the plan's active-gallery limit."
  def create_gallery(%Scope{} = scope, attrs) do
    with :ok <- Authorization.authorize(scope, :"gallery.write") do
      Multi.new()
      |> Multi.run(:limit, fn repo, _ ->
        case Limits.ensure_headroom(repo, scope, "active_galleries") do
          :ok -> {:ok, :within_limit}
          error -> error
        end
      end)
      |> Multi.insert(:gallery, Gallery.changeset(%Gallery{}, Scoped.put_studio(attrs, scope)))
      |> Repo.transaction()
      |> unwrap(:gallery)
    end
  end

  @doc "Update a gallery's title, description and delivery settings."
  def update_gallery(%Scope{} = scope, id, attrs) do
    with :ok <- Authorization.authorize(scope, :"gallery.write"),
         {:ok, gallery} <- Scoped.fetch(Gallery, scope, id),
         {:ok, updated} <- gallery |> Gallery.changeset(attrs) |> Repo.update() do
      # The watermark is burned into the preview, so changing the setting is a
      # request to rebuild every preview in the gallery. Doing nothing here is
      # what would make the toggle a lie for everything already uploaded.
      if updated.watermark_enabled != gallery.watermark_enabled do
        rederive(updated)
      end

      {:ok, updated}
    end
  end

  @doc "Queue every frame in a gallery for fresh derivatives."
  def rederive(%Gallery{} = gallery) do
    GalleryMedia
    |> where([m], m.gallery_id == ^gallery.id)
    |> select([m], m.id)
    |> Repo.all()
    |> Enum.each(&Oban.insert(DeriveMediaWorker.enqueue(&1)))
  end

  @doc """
  Attach an uploaded file.

  The storage check and the insert share a transaction and a row lock, so two
  simultaneous uploads cannot both consume the last of the allowance. The
  gallery's byte total is maintained by trigger, so this never writes it.
  """
  def add_media(%Scope{} = scope, gallery_id, attrs) do
    with :ok <- Authorization.authorize(scope, :"gallery.write"),
         {:ok, gallery} <- Scoped.fetch(Gallery, scope, gallery_id) do
      byte_size = attrs["byte_size"] || attrs[:byte_size] || 0

      Multi.new()
      |> Multi.run(:storage, fn repo, _ ->
        case Limits.ensure_storage(repo, scope, byte_size) do
          :ok -> {:ok, :within_limit}
          error -> error
        end
      end)
      |> Multi.insert(:media, fn _ ->
        GalleryMedia.changeset(
          %GalleryMedia{},
          attrs
          |> Scoped.put_studio(scope)
          |> Map.put("gallery_id", gallery.id)
        )
      end)
      # Same transaction as the row, so a frame cannot be committed with no work
      # scheduled to process it, and a rolled-back upload cannot leave a job
      # pointing at a row that never existed.
      |> Oban.insert(:derive, fn %{media: media} ->
        DeriveMediaWorker.enqueue(media.id)
      end)
      |> Repo.transaction()
      |> unwrap(:media)
    end
  end

  @doc """
  Detach a file and delete the object behind it.

  The row goes first. If the object delete then fails the studio is left paying
  for bytes it can no longer see, which a sweep can reclaim later; doing it the
  other way round would leave a row pointing at a file that is already gone,
  and the gallery would render broken images with no way back.
  """
  def remove_media(%Scope{} = scope, media_id) do
    with :ok <- Authorization.authorize(scope, :"gallery.write"),
         {:ok, media} <- Scoped.fetch(GalleryMedia, scope, media_id),
         {:ok, media} <- Repo.delete(media) do
      for key <- Enum.reject([media.storage_key, media.thumb_key, media.preview_key], &is_nil/1) do
        Storage.delete(key)
      end

      {:ok, media}
    end
  end

  def list_media(%Scope{} = scope, gallery_id) do
    with :ok <- Authorization.authorize(scope, :"gallery.read") do
      GalleryMedia
      |> Scoped.for_studio(scope)
      |> where([m], m.gallery_id == ^gallery_id)
      |> order_by([m], asc: m.position, asc: m.filename)
      |> Repo.all()
    end
  end

  @doc """
  Deliver the gallery to the client, opening the plan's delivery window.

  The window length comes from the plan, so the 60/180/365-day tiers stay a
  pricing decision rather than a constant in the code.
  """
  def deliver_gallery(%Scope{} = scope, id) do
    with :ok <- Authorization.authorize(scope, :"gallery.write"),
         {:ok, gallery} <- Scoped.fetch(Gallery, scope, id) do
      days = Limits.gallery_window_days(Repo, scope)

      Multi.new()
      |> Multi.update(:gallery, Gallery.deliver_changeset(gallery, days))
      |> Events.record(:gallery, "gallery.delivered", "Gallery delivered to client", scope)
      |> Repo.transaction()
      |> unwrap(:gallery)
    end
  end

  @doc "Extend one gallery's window — the paid add-on."
  def extend_gallery(%Scope{} = scope, id, days) do
    with :ok <- Authorization.authorize(scope, :"gallery.write"),
         {:ok, gallery} <- Scoped.fetch(Gallery, scope, id) do
      gallery |> Gallery.extend_changeset(days) |> Repo.update()
    end
  end

  @doc """
  Archive galleries whose window has closed.

  Files stay recoverable for the retention period before the purge worker
  deletes them, which is the promise the pricing page makes.
  """
  def archive_expired(now \\ DateTime.utc_now(), recovery_days \\ 30) do
    galleries =
      Repo.all(
        from g in Gallery,
          where: g.status == "delivered" and is_nil(g.archived_at) and g.expires_at < ^now
      )

    Enum.map(galleries, fn gallery ->
      gallery |> Gallery.archive_changeset(recovery_days, now) |> Repo.update()
    end)
  end

  @doc """
  Mark a gallery purged once its files are gone.

  Separate from deleting the objects because the two cannot be made atomic: the
  storage delete is a network call and the row is a transaction. The files go
  first, so a crash between them leaves a row saying "archived" pointing at
  nothing — recoverable by running the purge again — rather than a row saying
  "purged" while the studio is still billed for the bytes.
  """
  def mark_purged(%Gallery{} = gallery) do
    gallery
    |> Ecto.Changeset.change(status: "purged", purge_after: nil)
    |> Repo.update()
  end

  @doc "Galleries whose recovery window has also passed, ready for the purge worker."
  def purgeable(now \\ DateTime.utc_now()) do
    Repo.all(
      from g in Gallery,
        where: g.status == "archived" and not is_nil(g.purge_after) and g.purge_after < ^now
    )
  end

  ## Sharing

  @doc "Create a share link. Returns `{:ok, share, token}` — the token is shown once."
  def share_gallery(%Scope{} = scope, gallery_id, attrs) do
    with :ok <- Authorization.authorize(scope, :"gallery.write"),
         {:ok, gallery} <- Scoped.fetch(Gallery, scope, gallery_id) do
      changeset =
        GalleryShare.changeset(%GalleryShare{}, Map.put(attrs, "gallery_id", gallery.id))

      token = Ecto.Changeset.get_change(changeset, :token)

      case Repo.insert(changeset) do
        {:ok, share} -> {:ok, share, token}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  @doc "The live share links for one gallery, newest first."
  def list_shares(%Scope{} = scope, gallery_id) do
    with :ok <- Authorization.authorize(scope, :"gallery.read"),
         {:ok, _gallery} <- Scoped.fetch(Gallery, scope, gallery_id) do
      {:ok,
       Repo.all(
         from s in GalleryShare,
           where: s.gallery_id == ^gallery_id and is_nil(s.revoked_at),
           order_by: [desc: s.inserted_at]
       )}
    end
  end

  def revoke_share(%Scope{} = scope, share_id) do
    with :ok <- Authorization.authorize(scope, :"gallery.write"),
         share when not is_nil(share) <- Repo.get(GalleryShare, share_id),
         {:ok, _gallery} <- Scoped.fetch(Gallery, scope, share.gallery_id) do
      share |> GalleryShare.revoke_changeset() |> Repo.update()
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  Open a gallery from a client's share link.

  Checks the share is live and the gallery has not expired. Returns
  `{:ok, gallery, share}` and records the visit.

  Use `resolve_shared_gallery/1` where the same open may be evaluated more than
  once — a LiveView mounts twice, and counting that as two visits tells the
  studio the client came back when they did not.
  """
  def open_shared_gallery(token) when is_binary(token) do
    with {:ok, _gallery, share} <- resolve_shared_gallery(token) do
      record_visit(share)
    end
  end

  @doc "Resolve a share token without recording a visit. See `open_shared_gallery/1`."
  def resolve_shared_gallery(token) when is_binary(token) do
    hash = GalleryShare.hash_token(token)
    now = DateTime.utc_now()

    case Repo.one(
           from s in GalleryShare, where: s.token_hash == ^hash, preload: [gallery: :studio]
         ) do
      nil ->
        {:error, :not_found}

      share ->
        cond do
          not GalleryShare.usable?(share, now) -> {:error, :revoked}
          Gallery.expired?(share.gallery, now) -> {:error, :expired}
          share.gallery.status == "archived" -> {:error, :archived}
          true -> {:ok, share.gallery, share}
        end
    end
  end

  @doc """
  Resolve one file behind a share link.

  Every check the gallery page makes is made again here, because this is a
  separate request and the link may have been revoked since the page was
  drawn. A media id from another gallery is `:not_found` rather than
  `:forbidden` — saying which would confirm the id exists.
  """
  def fetch_shared_media(token, media_id, unlocked \\ []) do
    with {:ok, gallery, share} <- resolve_shared_gallery(token) do
      if gated?(gallery, unlocked) do
        {:error, :gated}
      else
        case Repo.get(GalleryMedia, media_id) do
          %GalleryMedia{} = media when media.gallery_id == gallery.id ->
            {:ok, media, gallery, share}

          _other ->
            {:error, :not_found}
        end
      end
    end
  end

  ## Client selections

  @doc """
  Record a client's favourite or album pick.

  Re-tapping a heart is a no-op rather than a duplicate row, thanks to the
  `(media_id, share_id, kind)` unique index — a client tapping twice on a slow
  connection must not create two selections.
  """
  def select_media(%GalleryShare{} = share, media_id, kind \\ "favourite", note \\ nil) do
    if share.can_select do
      %GallerySelection{}
      |> GallerySelection.changeset(%{
        gallery_id: share.gallery_id,
        media_id: media_id,
        share_id: share.id,
        kind: kind,
        note: note
      })
      |> Repo.insert()
      |> case do
        {:ok, selection} -> {:ok, selection}
        {:error, changeset} -> if duplicate?(changeset), do: :ok, else: {:error, changeset}
      end
    else
      {:error, :not_permitted}
    end
  end

  def deselect_media(%GalleryShare{} = share, media_id, kind \\ "favourite") do
    Repo.delete_all(
      from s in GallerySelection,
        where: s.media_id == ^media_id and s.share_id == ^share.id and s.kind == ^kind
    )

    :ok
  end

  def list_selections(%Scope{} = scope, gallery_id, kind \\ "favourite") do
    with :ok <- Authorization.authorize(scope, :"gallery.read") do
      with {:ok, _gallery} <- Scoped.fetch(Gallery, scope, gallery_id) do
        {:ok,
         Repo.all(
           from s in GallerySelection,
             where: s.gallery_id == ^gallery_id and s.kind == ^kind,
             preload: [:media, :share]
         )}
      end
    end
  end

  @doc """
  Count a download against the gallery's limit.

  The guard is in the WHERE clause, so a client refreshing a download link
  cannot exceed the limit by racing themselves.
  """
  def record_download(%Gallery{} = gallery) do
    now = DateTime.utc_now()

    query =
      if gallery.download_limit do
        from g in Gallery,
          where:
            g.id == ^gallery.id and g.download_enabled and
              g.download_count < ^gallery.download_limit
      else
        from g in Gallery, where: g.id == ^gallery.id and g.download_enabled
      end

    case Repo.update_all(select(query, [g], g),
           inc: [download_count: 1],
           set: [updated_at: now]
         ) do
      {1, [gallery]} -> {:ok, gallery}
      _ -> {:error, :download_limit_reached}
    end
  end

  ## Access codes

  @doc "Email a one-time code for a gallery that requires verification."
  def issue_access_code(gallery_id, email) do
    changeset =
      GalleryAccessCode.changeset(%GalleryAccessCode{}, %{gallery_id: gallery_id, email: email})

    code = Ecto.Changeset.get_change(changeset, :code)

    case Repo.insert(changeset) do
      {:ok, record} -> {:ok, code, record}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Verify a code.

  Every attempt is counted, whether it succeeds or not, so brute force runs out
  of attempts rather than out of patience. The counter is on the row, so it
  survives restarts and holds across web nodes.
  """
  def verify_access_code(gallery_id, email, code) do
    now = DateTime.utc_now()

    query =
      from c in GalleryAccessCode,
        where: c.gallery_id == ^gallery_id and c.email == ^email and is_nil(c.consumed_at),
        order_by: [desc: c.inserted_at],
        limit: 1

    case Repo.one(query) do
      nil ->
        {:error, :invalid_code}

      record ->
        if GalleryAccessCode.usable?(record, now) do
          record |> GalleryAccessCode.attempt_changeset() |> Repo.update()

          if GalleryAccessCode.valid_code?(record, code) do
            record |> GalleryAccessCode.consume_changeset() |> Repo.update()
            :ok
          else
            {:error, :invalid_code}
          end
        else
          {:error, :expired_or_exhausted}
        end
    end
  end

  ## The gate in front of a gated gallery

  @doc """
  Whether this link still needs a code before it opens anything.

  `unlocked` is the list of gallery ids the browser has already proved itself
  for, carried in the session.
  """
  def gated?(%Gallery{requires_otp: false}, _unlocked), do: false
  def gated?(%Gallery{} = gallery, unlocked), do: gallery.id not in List.wrap(unlocked)

  @doc """
  Ask for a one-time code.

  The code goes to the address the *studio* named on the share, never to the
  address typed into the form. Sending it to whatever the visitor asks for
  would make the gate prove only that they own an inbox, which is not a fact
  about whether they should see the photographs.

  A mismatched address gets the same answer as a matching one. Anything else
  turns the form into an oracle for "is this the couple's email".
  """
  def request_access_code(token, email) when is_binary(token) and is_binary(email) do
    with {:ok, gallery, share} <- resolve_shared_gallery(token) do
      cond do
        not gallery.requires_otp -> {:error, :not_gated}
        is_nil(share.email) -> {:error, :no_recipient}
        not same_address?(share.email, email) -> :ok
        true -> send_access_code(gallery, share)
      end
    end
  end

  @doc """
  Redeem a code and return the gallery it opens.

  Verification is always against the share's own address, so a code issued for
  the couple cannot be redeemed by someone who typed a different address into
  the form alongside it.
  """
  def redeem_access_code(token, email, code)
      when is_binary(token) and is_binary(email) and is_binary(code) do
    with {:ok, gallery, share} <- resolve_shared_gallery(token) do
      if is_nil(share.email) or not same_address?(share.email, email) do
        {:error, :invalid_code}
      else
        case verify_access_code(gallery.id, share.email, code) do
          :ok -> {:ok, gallery}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  # One code per minute per gallery. Without this the form is a button that
  # mails a stranger's inbox as fast as it can be clicked, and the person being
  # mailed is the client, not the person clicking.
  defp send_access_code(gallery, share) do
    if recent_code?(gallery.id, share.email) do
      :ok
    else
      with {:ok, code, _record} <- issue_access_code(gallery.id, share.email) do
        Notifier.deliver_access_code(
          share.email,
          gallery.studio.name,
          gallery.title,
          code
        )

        :ok
      end
    end
  end

  defp recent_code?(gallery_id, email) do
    cutoff = DateTime.add(DateTime.utc_now(), -60, :second)

    Repo.exists?(
      from c in GalleryAccessCode,
        where:
          c.gallery_id == ^gallery_id and c.email == ^email and
            is_nil(c.consumed_at) and c.inserted_at > ^cutoff
    )
  end

  defp same_address?(a, b) when is_binary(a) and is_binary(b) do
    String.downcase(String.trim(a)) == String.downcase(String.trim(b))
  end

  defp same_address?(_a, _b), do: false

  ## Internals

  defp record_visit(share) do
    {:ok, share} = share |> GalleryShare.seen_changeset() |> Repo.update()
    {:ok, share.gallery, share}
  end

  defp duplicate?(%Ecto.Changeset{errors: errors}),
    do: Enum.any?(errors, fn {field, _} -> field in [:media_id, :share_id, :kind] end)

  defp unwrap({:ok, changes}, key), do: {:ok, Map.fetch!(changes, key)}
  defp unwrap({:error, _step, %Ecto.Changeset{} = changeset, _}, _key), do: {:error, changeset}
  defp unwrap({:error, _step, reason, _}, _key), do: {:error, reason}
end
