defmodule AperDesk.Accounts do
  @moduledoc """
  Identity, tenancy and the seats that connect them.

  Registration and studio creation happen in one transaction: a user without a
  studio has nowhere to land, and a studio without an owner is unreachable, so
  neither is allowed to exist on its own.
  """

  import Ecto.Query

  alias AperDesk.Accounts.{
    Membership,
    Notifier,
    Registration,
    Studio,
    User,
    UserIdentity,
    UserInvitation,
    UserToken
  }

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

  @doc """
  Register from the sign-up form.

  Takes a `Registration` changeset and returns the same shape back on failure,
  with database-level errors mapped onto the field the form actually shows. A
  taken email surfaces on `:email`, a taken studio slug on `:studio_name` —
  without this the caller would get a `User` or `Studio` changeset whose
  `:name` error could belong to either field.
  """
  def register_studio(%Ecto.Changeset{} = form) do
    if form.valid? do
      case register_owner(Registration.user_attrs(form), Registration.studio_attrs(form)) do
        {:ok, result} -> {:ok, result}
        {:error, changeset} -> {:error, merge_registration_errors(form, changeset)}
      end
    else
      {:error, %{form | action: :insert}}
    end
  end

  defp merge_registration_errors(form, %Ecto.Changeset{data: %User{}} = changeset) do
    Enum.reduce(changeset.errors, %{form | action: :insert}, fn
      {:email, {message, opts}}, acc -> Ecto.Changeset.add_error(acc, :email, message, opts)
      {_field, {message, opts}}, acc -> Ecto.Changeset.add_error(acc, :name, message, opts)
    end)
  end

  defp merge_registration_errors(form, %Ecto.Changeset{data: %Studio{}} = changeset) do
    Enum.reduce(changeset.errors, %{form | action: :insert}, fn {_field, {message, opts}}, acc ->
      Ecto.Changeset.add_error(acc, :studio_name, message, opts)
    end)
  end

  defp merge_registration_errors(form, _changeset),
    do: Ecto.Changeset.add_error(%{form | action: :insert}, :name, "could not be created")

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

  ## Federated sign-in

  @doc """
  Sign in from a Google profile, creating the account on first use.

  Three cases, in order:

    1. The Google identity is already linked — sign that user in. This is the
       only path that works regardless of email, which is the point of storing
       the provider's subject id rather than matching on address.
    2. No link, but a verified email matches an existing account — link them.
       **Only when Google reports the email verified.** Linking on an unverified
       address would let anyone able to create a Google account claiming an
       address take over the AperDesk account using it.
    3. Nothing matches — create the user, their studio and the link together.

  An unverified email that matches no account is refused rather than used to
  create one, because the address is the only thing tying that account to a
  person and we have no evidence it is theirs.
  """
  def sign_in_with_google(%{sub: sub} = profile) when is_binary(sub) do
    case Repo.get_by(UserIdentity, provider: "google", provider_uid: sub) do
      %UserIdentity{} = identity ->
        identity |> UserIdentity.used_changeset() |> Repo.update()
        {:ok, Repo.get!(User, identity.user_id), :existing}

      nil ->
        link_or_create(profile)
    end
  end

  defp link_or_create(%{email_verified: false, email: email}) when is_binary(email),
    do: {:error, :email_not_verified}

  defp link_or_create(%{email: nil}), do: {:error, :no_email}

  defp link_or_create(%{email: email} = profile) do
    case get_user_by_email(email) do
      %User{} = user ->
        with {:ok, _identity} <- link_identity(user, profile) do
          {:ok, user, :linked}
        end

      nil ->
        create_from_google(profile)
    end
  end

  defp link_identity(%User{} = user, profile) do
    %UserIdentity{}
    |> UserIdentity.changeset(%{
      user_id: user.id,
      provider: "google",
      provider_uid: profile.sub,
      email: profile.email,
      name: profile.name,
      avatar_url: profile[:picture],
      last_used_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  # Creates the user, their studio and the Google link in one transaction.
  #
  # A federated user has no password: `hashed_password` stays null, and
  # `User.valid_password?/2` already refuses those while still running a dummy
  # hash — so a password login against a Google-only account is rejected without
  # revealing that the account exists.
  defp create_from_google(profile) do
    studio_name = profile.name || profile.email |> String.split("@") |> List.first()

    Multi.new()
    |> Multi.insert(
      :user,
      User.oauth_registration_changeset(%User{}, %{
        name: profile.name || profile.email,
        email: profile.email,
        avatar_url: profile[:picture]
      })
    )
    |> Multi.insert(:studio, fn _ ->
      Studio.changeset(%Studio{}, %{name: "#{studio_name}'s studio"})
    end)
    |> Multi.insert(:membership, fn %{user: user, studio: studio} ->
      Membership.changeset(%Membership{}, %{
        user_id: user.id,
        studio_id: studio.id,
        role: "owner",
        status: "active"
      })
    end)
    |> Multi.insert(:identity, fn %{user: user} ->
      UserIdentity.changeset(%UserIdentity{}, %{
        user_id: user.id,
        provider: "google",
        provider_uid: profile.sub,
        email: profile.email,
        name: profile.name,
        avatar_url: profile[:picture],
        last_used_at: DateTime.utc_now()
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user, :created}
      {:error, _step, changeset, _} -> {:error, changeset}
    end
  end

  @doc "The federated identities linked to a user, for the settings screen."
  def list_identities(%User{} = user),
    do: Repo.all(from i in UserIdentity, where: i.user_id == ^user.id)

  ## Password reset

  @doc """
  Start a password reset.

  Always returns `:ok`, whether or not the address belongs to an account. A
  caller that could tell the difference would be an account-enumeration oracle:
  "no such user" on a reset form confirms which addresses are registered just as
  effectively as a login error would.

  Any existing reset tokens for the user are revoked first, so an older link
  someone has lying around stops working the moment a new one is requested.
  """
  def deliver_reset_password_instructions(email, url_builder)
      when is_binary(email) and is_function(url_builder, 1) do
    case get_user_by_email(email) do
      nil ->
        :ok

      user ->
        revoke_all_tokens(user, "reset_password")
        {:ok, token, _record} = create_token(user, "reset_password")
        Notifier.deliver_reset_password(user, url_builder.(token))
        :ok
    end
  end

  @doc "The user a reset link belongs to, if it is still valid."
  def fetch_user_by_reset_token(token) when is_binary(token) do
    case fetch_user_by_token(token, "reset_password") do
      {:ok, user, _record} -> {:ok, user}
      error -> error
    end
  end

  @doc """
  Set a new password from a reset link.

  The reset token is consumed and every session ended in the same transaction as
  the password change — if the point of the reset was that someone else had the
  old password, leaving their session alive defeats it.
  """
  def reset_password(token, attrs) when is_binary(token) do
    with {:ok, user} <- fetch_user_by_reset_token(token),
         {:ok, user} <- update_password(user, attrs) do
      revoke_all_tokens(user, "reset_password")
      Notifier.deliver_password_changed(user)
      {:ok, user}
    end
  end

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

  @doc """
  Finish first-run setup.

  Owner-only: currency and time zone change how every existing quote, invoice
  and shoot is read, so this is not a setting a photographer seat should be able
  to change on everyone else's behalf.
  """
  def complete_setup(%Scope{} = scope, attrs) do
    with :ok <- Authorization.authorize(scope, :"studio.write") do
      scope.studio |> Studio.setup_changeset(attrs) |> Repo.update()
    end
  end

  @doc "Whether the studio still needs first-run setup."
  def needs_setup?(%Scope{studio: %Studio{} = studio}), do: not Studio.configured?(studio)
  def needs_setup?(%Scope{}), do: false

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
