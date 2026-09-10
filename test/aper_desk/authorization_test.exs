defmodule AperDesk.AuthorizationTest do
  @moduledoc """
  The permission table is the one place role rules live, so it is worth
  asserting the shape of it directly — including that unknown permissions are
  denied, which is what makes new permissions safe to add.
  """

  use ExUnit.Case, async: true

  alias AperDesk.Accounts.{Membership, Studio, User}
  alias AperDesk.Authorization
  alias AperDesk.Scope

  defp scope(role) do
    Scope.for_membership(
      %User{id: Ecto.UUID.generate(), name: "T", platform_admin: false},
      %Studio{id: Ecto.UUID.generate(), base_currency: "USD", time_zone: "Etc/UTC"},
      %Membership{role: to_string(role)}
    )
  end

  test "an owner can do everything" do
    assert Authorization.can?(scope(:owner), :"billing.write")
    assert Authorization.can?(scope(:owner), :"gallery.write")
  end

  test "a photographer sees client work but not money" do
    photographer = scope(:photographer)
    assert Authorization.can?(photographer, :"lead.read")
    assert Authorization.can?(photographer, :"gallery.write")
    refute Authorization.can?(photographer, :"invoice.write")
    refute Authorization.can?(photographer, :"billing.write")
  end

  test "finance sees money but not client galleries" do
    finance = scope(:finance)
    assert Authorization.can?(finance, :"invoice.write")
    assert Authorization.can?(finance, :"payout.write")
    refute Authorization.can?(finance, :"gallery.read")
  end

  test "hr sees people but not client data" do
    hr = scope(:hr)
    assert Authorization.can?(hr, :"member.write")
    refute Authorization.can?(hr, :"lead.write")
    refute Authorization.can?(hr, :"gallery.read")
  end

  test "an unknown permission is denied for every role" do
    for role <- [:photographer, :finance, :hr, :ops] do
      refute Authorization.can?(scope(role), :"nuclear.launch"),
             "#{role} should not hold an undeclared permission"
    end
  end

  test "an anonymous scope holds nothing" do
    refute Authorization.can?(Scope.public(), :"lead.read")
    assert Authorization.authorize(Scope.public(), :"lead.read") == {:error, :unauthorized}
  end

  test "a platform admin bypasses the table" do
    assert Authorization.can?(%Scope{platform_admin?: true}, :"billing.write")
  end
end
