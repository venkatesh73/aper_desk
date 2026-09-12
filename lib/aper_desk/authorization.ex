defmodule AperDesk.Authorization do
  @moduledoc """
  What each role may do.

  Permissions live in one table rather than as `if role == "owner"` scattered
  through contexts and LiveViews. That is what makes it possible to answer
  "what can a finance user actually see?" by reading one module, and to add a
  role without auditing the whole codebase.

  The five roles are the seats the product sells:

    * `owner` — everything, including billing and deleting the studio
    * `photographer` — their own work: leads, shoots, galleries. No money.
    * `finance` — invoices, payments, payouts, billing. No client galleries.
    * `hr` — people, contracts, day rates, leave. No client data.
    * `ops` — the day-to-day: leads, scheduling, galleries, comms. No money.

  A permission absent from a role's list is denied. New permissions are
  therefore closed by default, which is the safe direction to fail.
  """

  alias AperDesk.Scope

  @permissions %{
    owner: :all,
    photographer: ~w(
      studio.read
      lead.read lead.write job.read job.write assignment.read
      gallery.read gallery.write contact.read contact.write
      quote.read package.read comms.read comms.write
      workflow.read directory.read directory.write review.read
    )a,
    finance: ~w(
      studio.read
      invoice.read invoice.write payment.read payment.write
      payout.read payout.write expense.read expense.write
      quote.read quote.write contract.read billing.read billing.write
      lead.read job.read contact.read report.read
    )a,
    hr: ~w(
      studio.read
      member.read member.write invitation.read invitation.write
      assignment.read assignment.write payout.read
      job.read report.read
    )a,
    ops: ~w(
      studio.read
      lead.read lead.write job.read job.write assignment.read assignment.write
      gallery.read gallery.write contact.read contact.write
      package.read package.write quote.read quote.write contract.read contract.write
      comms.read comms.write workflow.read workflow.write form.read form.write
      report.read directory.read
    )a
  }

  @doc "Every permission any role can hold, for tests and the roles admin screen."
  def known_permissions do
    @permissions
    |> Map.values()
    |> Enum.reject(&(&1 == :all))
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end

  def permissions_for(role) when is_atom(role), do: Map.get(@permissions, role, [])

  @doc """
  Whether `scope` may perform `permission`.

  A platform admin passes everything — that is the internal console, and it is
  deliberately not studio-scoped.
  """
  def can?(%Scope{platform_admin?: true}, _permission), do: true
  def can?(%Scope{role: nil}, _permission), do: false

  def can?(%Scope{role: role}, permission) when is_atom(permission) do
    case Map.get(@permissions, role) do
      :all -> true
      nil -> false
      permissions -> permission in permissions
    end
  end

  @doc """
  Authorise or explain. Returns `:ok` or `{:error, :unauthorized}`.

  Contexts call this rather than `can?/2` so that forgetting to handle the
  denial is a match error at compile-adjacent speed, not a silently permitted
  action.
  """
  def authorize(%Scope{} = scope, permission) do
    if can?(scope, permission), do: :ok, else: {:error, :unauthorized}
  end

  @doc "Authorise or raise. For paths where the UI should never have offered the action."
  def authorize!(%Scope{} = scope, permission) do
    case authorize(scope, permission) do
      :ok ->
        scope

      {:error, :unauthorized} ->
        raise AperDesk.Authorization.UnauthorizedError,
          message: "#{scope.role || "anonymous"} may not #{permission}"
    end
  end

  @doc """
  Every role, in the order a permissions table should read them.

  Owner first because it is the superset, then the four that are genuinely
  different from each other.
  """
  def roles, do: [:owner, :photographer, :finance, :hr, :ops]

  @doc """
  Whether `role` holds `permission`, without needing a `%Scope{}`.

  This is what lets the settings screen draw the permission matrix from the
  same table the contexts are checked against, rather than from a hand-written
  copy that would be wrong the first time a permission moved.
  """
  def holds?(role, permission) when is_atom(role) and is_atom(permission) do
    case Map.get(@permissions, role) do
      :all -> true
      nil -> false
      permissions -> permission in permissions
    end
  end

  @doc "Whether the scope owns the studio it is acting in."
  def owner?(%Scope{role: :owner}), do: true
  def owner?(%Scope{}), do: false
end
