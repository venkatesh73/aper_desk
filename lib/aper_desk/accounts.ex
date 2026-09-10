defmodule AperDesk.Accounts do
  @moduledoc """
  Identity, tenancy and the seats that connect them.

  Registration and studio creation happen in one transaction: a user without a
  studio has nowhere to land, and a studio without an owner is unreachable, so
  neither is allowed to exist on its own.
  """

  import Ecto.Query

  alias AperDesk.Accounts.{Membership, Studio, User, UserInvitation, UserToken}
  alias AperDesk.Authorization
  alias AperDesk.Repo
  alias AperDesk.Scope
  alias Ecto.Multi

  ## Registration and sign-in

  @doc """
  Register a user and create the studio they will own, atomically.

  Returns `{:ok, %{user: user, studio: studio, membership: membership}}`.
  """
  def register_owner(user_attrs, studio_attrs) do
    Multi.new()
    |> Multi.insert(:user, User.registration_changeset(%User{}, user_attrs))
    |> Multi.insert(:studio, Studio.changeset(%Studio{}, studio_attrs))
    |> Multi.insert(:membership, fn %{user: user, studio: studio} ->
      Membership.changeset(%Membership{}, %{
        user_id: user.id,
        studio_id: studio.id,
        role: "owner",
        status: "active"
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  def register_user(attrs), do: %User{} |> User.registration_changeset(attrs) |> Repo.insert()

  def change_user_registration(user \\ %User{}, attrs \\ %{}),
    do: User.registration_changeset(user, attrs)

  @doc """
  Look up a user by email and verify their password.

  Returns `{:error, :invalid_credentials}` for both an unknown address and a
  wrong password — telling them apart is an account-enumeration oracle. When
  the address is unknown, `User.valid_password?/2` still runs a dummy hash so
  the timing does not leak the difference either.
  """
  def authenticate(email, password) when is_binary(email) and is_binary(password) do
    user = get_user_by_email(email)

    if User.valid_password?(user || %User{}, password) do
      {:ok, user}
    else
      {:error, :invalid_credentials}
    end
  end

  def get_user_by_email(email) when is_binary(email),
    do: Repo.get_by(User, email: email |> String.trim() |> String.downcase())

  def get_user(id), do: Repo.get(User, id)
  def get_user!(id), do: Repo.get!(User, id)

  def update_profile(%User{} = user, attrs),
    do: user |> User.profile_changeset(attrs) |> Repo.update()

  def update_password(%User{} = user, attrs) do
    Multi.new()
    |> Multi.update(:user, User.password_changeset(user, attrs))
    # Changing a password ends every other session. If the change was prompted
    # by a suspected compromise, leaving the attacker's session alive defeats
    # the point of changing it.
    |> Multi.delete_all(:tokens, from(t in UserToken, where: t.user_id == ^user.id))
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  def confirm_user(%User{} = user), do: user |> User.confirm_changeset() |> Repo.update()

  ## Tokens

  @doc "Mint a token, returning the plaintext to send and the stored record."
  def create_token(%User{} = user, context, opts \\ []) do
    {token, changeset} = UserToken.build(user, context, opts)

    case Repo.insert(changeset) do
      {:ok, record} -> {:ok, token, record}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Record a token minted elsewhere, so it can be revoked.

  Used for Guardian refresh JWTs: the JWT is the credential, this row is what
  makes revoking it possible.
  """
  def store_token(%User{} = user, context, token, opts \\ []) do
    user
    |> UserToken.build_from(context, token, opts)
    |> Repo.insert()
  end

  @doc """
  Exchange a plaintext token for its user.

  The lookup is by hash, so a leaked database gives an attacker nothing to
  replay. Expired and revoked tokens are rejected here rather than filtered in
  the query, so the reason is available for logging.
  """
  def fetch_user_by_token(token, context) when is_binary(token) do
    hash = UserToken.hash(token)

    query =
      from t in UserToken,
        where: t.token_hash == ^hash and t.context == ^context,
        preload: [:user]

    case Repo.one(query) do
      nil ->
        {:error, :invalid_token}

      record ->
        if UserToken.usable?(record, DateTime.utc_now()) do
          {:ok, record.user, record}
        else
          {:error, :expired_token}
        end
    end
  end

  def revoke_token(%UserToken{} = token),
    do: token |> UserToken.revoke_changeset() |> Repo.update()

  def revoke_token(token, context) when is_binary(token) do
    hash = UserToken.hash(token)

    {count, _} =
      Repo.delete_all(from t in UserToken, where: t.token_hash == ^hash and t.context == ^context)

    if count > 0, do: :ok, else: {:error, :invalid_token}
  end

  def revoke_all_tokens(%User{} = user, context) do
    Repo.delete_all(from t in UserToken, where: t.user_id == ^user.id and t.context == ^context)
    :ok
  end

  @doc "Delete tokens that have already expired. Called by the nightly sweep."
  def purge_expired_tokens(now \\ DateTime.utc_now()) do
    {count, _} =
      Repo.delete_all(
        from t in UserToken, where: not is_nil(t.expires_at) and t.expires_at < ^now
      )

    count
  end

  ## Studios and scope

  def get_studio(id), do: Repo.get(Studio, id)
  def get_studio_by_slug(slug), do: Repo.get_by(Studio, slug: slug)

  def update_studio(%Scope{} = scope, attrs) do
    with :ok <- Authorization.authorize(scope, :"studio.write") do
      scope.studio |> Studio.changeset(attrs) |> Repo.update()
    end
  end

  @doc "Every studio the user holds an active seat in, for the studio switcher."
  def list_studios_for_user(%User{} = user) do
    Repo.all(
      from s in Studio,
        join: m in Membership,
        on: m.studio_id == s.id,
        where: m.user_id == ^user.id and m.status == "active" and is_nil(s.archived_at),
        order_by: s.name,
        select: s
    )
  end

  @doc """
  Build the scope for a user acting in a studio.

  Returns `{:error, :no_membership}` when they hold no active seat, which is
  what makes a stale studio id in a session or a JWT harmless.
  """
  def scope_for(%User{} = user, studio_id) do
    query =
      from m in Membership,
        where: m.user_id == ^user.id and m.studio_id == ^studio_id and m.status == "active",
        preload: [:studio]

    case Repo.one(query) do
      nil -> {:error, :no_membership}
      membership -> {:ok, Scope.for_membership(user, membership.studio, membership)}
    end
  end

  @doc "The scope for a user's default studio — the first they joined."
  def default_scope_for(%User{} = user) do
    case list_studios_for_user(user) do
      [] -> {:error, :no_membership}
      [studio | _] -> scope_for(user, studio.id)
    end
  end

  ## Memberships

  def list_members(%Scope{} = scope) do
    with :ok <- Authorization.authorize(scope, :"member.read") do
      {:ok,
       Repo.all(
         from m in Membership,
           where: m.studio_id == ^Scope.studio_id(scope) and m.status != "left",
           preload: [:user],
           order_by: [asc: m.role, asc: m.inserted_at]
       )}
    end
  end

  def update_member(%Scope{} = scope, membership_id, attrs) do
    with :ok <- Authorization.authorize(scope, :"member.write"),
         {:ok, membership} <- fetch_membership(scope, membership_id),
         :ok <- ensure_not_last_owner(scope, membership, attrs) do
      membership |> Membership.changeset(attrs) |> Repo.update()
    end
  end

  @doc """
  Remove someone from the studio.

  A membership is marked `left` rather than deleted: their name still has to
  render on the jobs they shot and the invoices they raised, and a deleted row
  would turn all of that history into "Unknown".
  """
  def remove_member(%Scope{} = scope, membership_id) do
    with :ok <- Authorization.authorize(scope, :"member.write"),
         {:ok, membership} <- fetch_membership(scope, membership_id),
         :ok <- ensure_not_last_owner(scope, membership, %{status: "left"}) do
      membership |> Membership.changeset(%{status: "left"}) |> Repo.update()
    end
  end

  def touch_last_active(%Membership{} = membership) do
    Repo.update_all(
      from(m in Membership, where: m.id == ^membership.id),
      set: [last_active_at: DateTime.utc_now()]
    )

    :ok
  end

  ## Invitations

  @doc "Invite someone to a seat. Returns `{:ok, token, invitation}` — send the token."
  def invite_member(%Scope{} = scope, attrs) do
    with :ok <- Authorization.authorize(scope, :"invitation.write") do
      {token, changeset} =
        UserInvitation.build(Scope.studio_id(scope), attrs, Scope.user_id(scope))

      case Repo.insert(changeset) do
        {:ok, invitation} -> {:ok, token, invitation}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  def list_invitations(%Scope{} = scope) do
    with :ok <- Authorization.authorize(scope, :"invitation.read") do
      {:ok,
       Repo.all(
         from i in UserInvitation,
           where: i.studio_id == ^Scope.studio_id(scope) and is_nil(i.accepted_at),
           order_by: [desc: i.inserted_at]
       )}
    end
  end

  @doc """
  Accept an invitation as `user`.

  The membership insert and the invitation stamp share a transaction, so a
  crash between them cannot leave an invitation that is spent but granted
  nothing — or a seat that can be claimed twice.
  """
  def accept_invitation(token, %User{} = user) when is_binary(token) do
    hash = UserInvitation.hash(token)

    case Repo.get_by(UserInvitation, token_hash: hash) do
      nil ->
        {:error, :invalid_token}

      %UserInvitation{accepted_at: %DateTime{}} ->
        # Distinguished from expiry because the UI says different things: a
        # spent invitation means "you already joined", an expired one means
        # "ask them to send another".
        {:error, :already_accepted}

      invitation ->
        if UserInvitation.usable?(invitation, DateTime.utc_now()) do
          do_accept(invitation, user)
        else
          {:error, :expired_token}
        end
    end
  end

  defp do_accept(invitation, user) do
    Multi.new()
    |> Multi.insert(
      :membership,
      Membership.changeset(%Membership{}, %{
        user_id: user.id,
        studio_id: invitation.studio_id,
        role: invitation.role,
        status: "active"
      })
    )
    |> Multi.update(:invitation, UserInvitation.accept_changeset(invitation))
    |> Repo.transaction()
    |> case do
      {:ok, %{membership: membership}} -> {:ok, membership}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  def revoke_invitation(%Scope{} = scope, invitation_id) do
    with :ok <- Authorization.authorize(scope, :"invitation.write"),
         invitation when not is_nil(invitation) <-
           Repo.get_by(UserInvitation, id: invitation_id, studio_id: Scope.studio_id(scope)) do
      Repo.delete(invitation)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  ## Internals

  defp fetch_membership(%Scope{} = scope, id) do
    case Repo.get_by(Membership, id: id, studio_id: Scope.studio_id(scope)) do
      nil -> {:error, :not_found}
      membership -> {:ok, membership}
    end
  end

  # Demoting or removing the last owner would leave a studio nobody can
  # administer — including nobody who can cancel its subscription.
  defp ensure_not_last_owner(%Scope{} = scope, %Membership{role: "owner"} = membership, attrs) do
    leaving? = Map.get(attrs, :status, Map.get(attrs, "status")) in ["left", "suspended"]
    demoted? = (Map.get(attrs, :role) || Map.get(attrs, "role")) not in [nil, "owner"]

    if leaving? or demoted? do
      owners =
        Repo.aggregate(
          from(m in Membership,
            where:
              m.studio_id == ^Scope.studio_id(scope) and m.role == "owner" and
                m.status == "active" and m.id != ^membership.id
          ),
          :count
        )

      if owners == 0, do: {:error, :last_owner}, else: :ok
    else
      :ok
    end
  end

  defp ensure_not_last_owner(_scope, _membership, _attrs), do: :ok
end
