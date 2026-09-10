defmodule AperDesk.AccountsTest do
  use AperDesk.DataCase, async: true

  import AperDesk.Fixtures

  alias AperDesk.Accounts
  alias AperDesk.Accounts.User

  describe "register_owner/2" do
    test "creates user, studio and owner seat atomically" do
      %{user: user, studio: studio, scope: scope} = studio_fixture()
      assert user.id
      assert studio.slug =~ "aperture-"
      assert scope.role == :owner
    end

    test "a bad studio rolls the user back too" do
      before = Repo.aggregate(User, :count)

      assert {:error, _} =
               Accounts.register_owner(
                 %{
                   email: "x#{unique()}@example.com",
                   name: "X",
                   password: "a long enough passphrase"
                 },
                 %{name: "", base_currency: "USD", time_zone: "Etc/UTC"}
               )

      assert Repo.aggregate(User, :count) == before, "orphan user left behind"
    end
  end

  describe "authenticate/2" do
    test "accepts the right password" do
      %{user: user} = studio_fixture()
      assert {:ok, found} = Accounts.authenticate(user.email, "a sufficiently long passphrase")
      assert found.id == user.id
    end

    test "an unknown address and a wrong password are indistinguishable" do
      %{user: user} = studio_fixture()

      assert {:error, :invalid_credentials} = Accounts.authenticate(user.email, "wrong")
      assert {:error, :invalid_credentials} = Accounts.authenticate("ghost@example.com", "wrong")
    end
  end

  describe "scope_for/2" do
    test "refuses a studio the user has no seat in" do
      %{user: user} = studio_fixture()
      assert {:error, :no_membership} = Accounts.scope_for(user, Ecto.UUID.generate())
    end
  end

  describe "changing a password" do
    test "revokes every other session" do
      %{user: user} = studio_fixture()
      {:ok, token, _} = Accounts.create_token(user, "session")
      assert {:ok, _, _} = Accounts.fetch_user_by_token(token, "session")

      {:ok, user} = Accounts.update_password(user, %{password: "a completely new passphrase"})
      assert {:error, :invalid_token} = Accounts.fetch_user_by_token(token, "session")
      assert User.valid_password?(user, "a completely new passphrase")
    end
  end

  describe "tokens" do
    test "are stored hashed and are context-bound" do
      %{user: user} = studio_fixture()
      {:ok, token, record} = Accounts.create_token(user, "session")

      refute record.token_hash == token
      assert {:ok, _, _} = Accounts.fetch_user_by_token(token, "session")
      assert {:error, :invalid_token} = Accounts.fetch_user_by_token(token, "reset_password")
    end
  end

  describe "invitations" do
    test "grant the invited role and cannot be reused" do
      %{scope: scope} = studio_fixture()

      {:ok, token, invitation} =
        Accounts.invite_member(scope, %{email: " Second@Example.com ", role: "photographer"})

      assert invitation.email == "second@example.com", "email should be normalised"

      {:ok, invitee} =
        Accounts.register_user(%{
          email: "second@example.com",
          name: "Second",
          password: "yet another long passphrase"
        })

      assert {:ok, membership} = Accounts.accept_invitation(token, invitee)
      assert membership.role == "photographer"
      assert {:error, :already_accepted} = Accounts.accept_invitation(token, invitee)
    end
  end

  describe "the last owner" do
    test "cannot be demoted or removed" do
      %{scope: scope} = studio_fixture()
      {:ok, [owner]} = Accounts.list_members(scope)

      assert {:error, :last_owner} =
               Accounts.update_member(scope, owner.id, %{role: "photographer"})

      assert {:error, :last_owner} = Accounts.remove_member(scope, owner.id)
    end
  end

  describe "tenant isolation" do
    test "one studio cannot see or touch another's members" do
      %{scope: ours} = studio_fixture()
      %{scope: theirs} = studio_fixture()

      {:ok, our_members} = Accounts.list_members(ours)
      {:ok, their_members} = Accounts.list_members(theirs)

      assert length(our_members) == 1
      assert length(their_members) == 1

      assert {:error, :not_found} =
               Accounts.update_member(theirs, hd(our_members).id, %{title: "hacked"})
    end
  end
end
