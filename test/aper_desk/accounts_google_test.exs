defmodule AperDesk.AccountsGoogleTest do
  @moduledoc """
  Google sign-in linking rules.

  These are the decisions that decide whether someone can take over an account,
  so they are asserted directly rather than left to the OAuth round trip.
  """

  use AperDesk.DataCase, async: true

  import AperDesk.Fixtures

  alias AperDesk.Accounts
  alias AperDesk.Accounts.{User, UserIdentity}

  defp profile(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    Map.merge(
      %{
        sub: "google-sub-#{n}",
        email: "person#{n}@example.com",
        email_verified: true,
        name: "Person #{n}",
        picture: nil
      },
      overrides
    )
  end

  describe "first sign-in" do
    test "creates the user, a studio and the link" do
      p = profile()

      assert {:ok, user, :created} = Accounts.sign_in_with_google(p)
      assert user.email == p.email
      assert [studio] = Accounts.list_studios_for_user(user)
      assert {:ok, scope} = Accounts.scope_for(user, studio.id)
      assert scope.role == :owner
      assert [identity] = Accounts.list_identities(user)
      assert identity.provider_uid == p.sub
    end

    test "the created account has no password, and password login is refused" do
      p = profile()
      {:ok, user, :created} = Accounts.sign_in_with_google(p)

      assert is_nil(Repo.get!(User, user.id).hashed_password)

      assert {:error, :invalid_credentials} =
               Accounts.authenticate(p.email, "any password at all")
    end

    test "treats the email as confirmed, because Google verified it" do
      {:ok, user, :created} = Accounts.sign_in_with_google(profile())
      assert Repo.get!(User, user.id).confirmed_at
    end
  end

  describe "returning sign-in" do
    test "matches on the provider subject, not the email" do
      p = profile()
      {:ok, user, :created} = Accounts.sign_in_with_google(p)

      # The person changed the address on their Google account. Matching by
      # email would create a second account for them.
      assert {:ok, same, :existing} =
               Accounts.sign_in_with_google(%{
                 p
                 | email: "changed#{System.unique_integer()}@example.com"
               })

      assert same.id == user.id
      assert Repo.aggregate(UserIdentity, :count) == 1
    end
  end

  describe "linking to an existing password account" do
    test "links when Google says the email is verified" do
      %{user: user} = studio_fixture()

      assert {:ok, linked, :linked} =
               Accounts.sign_in_with_google(profile(%{email: user.email}))

      assert linked.id == user.id
      assert [identity] = Accounts.list_identities(user)
      assert identity.provider == "google"
    end

    test "refuses to link an unverified email" do
      %{user: user} = studio_fixture()

      # Anyone can create a Google account claiming an address. Only Google
      # saying it verified the address makes it evidence of ownership.
      assert {:error, :email_not_verified} =
               Accounts.sign_in_with_google(profile(%{email: user.email, email_verified: false}))

      assert Accounts.list_identities(user) == []
    end

    test "refuses to create an account from an unverified email" do
      before = Repo.aggregate(User, :count)

      assert {:error, :email_not_verified} =
               Accounts.sign_in_with_google(profile(%{email_verified: false}))

      assert Repo.aggregate(User, :count) == before
    end

    test "refuses a profile with no email" do
      assert {:error, :no_email} =
               Accounts.sign_in_with_google(profile(%{email: nil, email_verified: true}))
    end
  end

  describe "identity uniqueness" do
    test "one Google account cannot be linked to two users" do
      p = profile()
      {:ok, first, :created} = Accounts.sign_in_with_google(p)
      %{user: other} = studio_fixture()

      assert {:error, changeset} =
               Repo.insert(
                 UserIdentity.changeset(%UserIdentity{}, %{
                   user_id: other.id,
                   provider: "google",
                   provider_uid: p.sub
                 })
               )

      assert "is already linked to another account" in errors_on(changeset).provider
      assert [_only_one] = Accounts.list_identities(first)
    end
  end
end
