defmodule AperDesk.RoleEnforcementTest do
  @moduledoc """
  Every scoped read is refused for a role that may not perform it.

  The permission table is only worth having if the contexts actually consult
  it. Several of these functions did not: `Crm.overdue_leads/1` and
  `Crm.pipeline_summary/1` returned real leads to an HR user who has no
  `lead.read` at all, and the dashboard put a client's name on their screen.

  This is a table test rather than one case per function because the failure
  mode is *forgetting*, and a list is the only shape that makes the omission
  visible when the next context function is added.
  """
  use AperDesk.DataCase, async: true

  import AperDesk.Fixtures

  alias AperDesk.{Accounts, Authorization, Repo}

  setup do
    %{studio: studio, scope: owner_scope} = studio_fixture()
    plan_fixture(studio)
    %{studio: studio, owner_scope: owner_scope}
  end

  defp scope_for_role(studio, role) do
    {:ok, user} =
      Accounts.register_user(%{
        "name" => "#{role}",
        "email" => "#{role}-#{System.unique_integer([:positive])}@example.com",
        "password" => "a sufficiently long passphrase"
      })

    Repo.insert!(
      Accounts.Membership.changeset(%Accounts.Membership{}, %{
        user_id: user.id,
        studio_id: studio.id,
        role: to_string(role),
        status: "active"
      })
    )

    {:ok, scope} = Accounts.scope_for(user, studio.id)
    scope
  end

  # {module, function, extra args, the permission it must demand}
  @guarded [
    {AperDesk.Crm, :list_leads, [], :"lead.read"},
    {AperDesk.Crm, :overdue_leads, [], :"lead.read"},
    {AperDesk.Crm, :pipeline_summary, [], :"lead.read"},
    {AperDesk.Crm, :list_tags, [], :"lead.read"},
    {AperDesk.Crm, :list_contacts, [], :"contact.read"},
    {AperDesk.Finance, :list_invoices, [], :"invoice.read"},
    {AperDesk.Finance, :overdue_invoices, [], :"invoice.read"},
    {AperDesk.Finance, :outstanding_total, [], :"invoice.read"},
    {AperDesk.Finance, :list_payouts, [], :"payout.read"},
    {AperDesk.Galleries, :list_galleries, [], :"gallery.read"},
    {AperDesk.Sales, :list_quotes, [], :"quote.read"},
    {AperDesk.Sales, :list_templates, [], :"contract.read"},
    {AperDesk.Catalog, :list_packages, [], :"package.read"},
    {AperDesk.Comms, :list_templates, [], :"comms.read"},
    {AperDesk.Comms, :list_forms, [], :"comms.read"},
    {AperDesk.Comms, :list_accounts, [], :"comms.read"},
    {AperDesk.Automation, :list_workflows, [], :"workflow.read"},
    {AperDesk.Automation, :list_sequences, [], :"workflow.read"},
    {AperDesk.Accounts, :list_members, [], :"member.read"},
    {AperDesk.Accounts, :list_invitations, [], :"invitation.read"},
    {AperDesk.Scheduling, :list_jobs, [], :"job.read"},
    {AperDesk.Scheduling, :holds_expiring, [], :"assignment.read"}
  ]

  for role <- [:photographer, :finance, :hr, :ops] do
    test "a #{role} is refused every read their role does not carry", %{studio: studio} do
      scope = scope_for_role(studio, unquote(role))

      for {module, function, args, permission} <- @guarded,
          not Authorization.can?(scope, permission) do
        result = apply(module, function, [scope | args])

        assert match?({:error, :unauthorized}, result),
               "#{inspect(module)}.#{function}/#{length(args) + 1} returned #{inspect(result)} " <>
                 "to a #{unquote(role)} who does not hold #{permission}"
      end
    end

    test "a #{role} is allowed every read their role does carry", %{studio: studio} do
      scope = scope_for_role(studio, unquote(role))

      for {module, function, args, permission} <- @guarded,
          Authorization.can?(scope, permission) do
        result = apply(module, function, [scope | args])

        refute match?({:error, :unauthorized}, result),
               "#{inspect(module)}.#{function}/#{length(args) + 1} refused a #{unquote(role)} " <>
                 "who does hold #{permission}"
      end
    end
  end

  test "HR never sees a client's name, however it is reached", %{
    studio: studio,
    owner_scope: owner_scope
  } do
    contact = contact_fixture(owner_scope, %{"name" => "Zelda Confidential"})

    {:ok, _lead} =
      AperDesk.Crm.create_lead(owner_scope, %{"title" => "A wedding", "contact_id" => contact.id})

    hr = scope_for_role(studio, :hr)

    # The three routes the dashboard used to take, one of which leaked.
    assert {:error, :unauthorized} = AperDesk.Crm.list_leads(hr)
    assert {:error, :unauthorized} = AperDesk.Crm.overdue_leads(hr)
    assert {:error, :unauthorized} = AperDesk.Crm.pipeline_summary(hr)
    assert {:error, :unauthorized} = AperDesk.Crm.list_contacts(hr)
  end
end
