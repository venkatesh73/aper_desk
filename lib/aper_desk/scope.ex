defmodule AperDesk.Scope do
  @moduledoc """
  The tenant and permission envelope every context function is called with.

  Contexts take a `%Scope{}` as their first argument rather than a bare
  `studio_id`. That is a deliberate constraint: it makes "which studio, acting
  as whom, with what role" impossible to forget, and it gives authorisation a
  single place to live instead of being scattered across LiveViews.

  A scope with `studio: nil` is anonymous (the landing page, the public
  directory, a gallery opened from a share link). A scope with
  `platform_admin?: true` is the internal console and is deliberately not
  studio-scoped.
  """

  alias AperDesk.Accounts.{Membership, Studio, User}

  @type role :: :owner | :photographer | :finance | :hr | :ops

  @type t :: %__MODULE__{
          user: User.t() | nil,
          studio: Studio.t() | nil,
          membership: Membership.t() | nil,
          role: role() | nil,
          platform_admin?: boolean(),
          currency: String.t(),
          time_zone: String.t()
        }

  defstruct user: nil,
            studio: nil,
            membership: nil,
            role: nil,
            platform_admin?: false,
            currency: "USD",
            time_zone: "Etc/UTC"

  @doc "An anonymous scope, for public pages."
  def public(opts \\ []) do
    %__MODULE__{
      currency: Keyword.get(opts, :currency, "USD"),
      time_zone: Keyword.get(opts, :time_zone, "Etc/UTC")
    }
  end

  @doc "Build a scope for a user acting inside one of their studios."
  def for_membership(%User{} = user, %Studio{} = studio, %Membership{} = membership) do
    %__MODULE__{
      user: user,
      studio: studio,
      membership: membership,
      role: role_atom(membership.role),
      platform_admin?: user.platform_admin,
      currency: studio.base_currency,
      time_zone: studio.time_zone
    }
  end

  # Mapped explicitly rather than with `String.to_existing_atom/1`.
  #
  # That function is the right instinct — never build an atom from a database
  # value — but it depends on the atom already existing, which depends on
  # whichever module declares it having been loaded. On a cold node, or in a
  # test that touches this path before it touches `AperDesk.Authorization`,
  # signing in raised `ArgumentError: not an already existing atom`. An explicit
  # table has no load-order dependency and no way to fail.
  #
  # An unrecognised role resolves to nil, which every permission check reads as
  # "no permissions" — the safe direction to fail.
  defp role_atom("owner"), do: :owner
  defp role_atom("photographer"), do: :photographer
  defp role_atom("finance"), do: :finance
  defp role_atom("hr"), do: :hr
  defp role_atom("ops"), do: :ops
  defp role_atom(_unknown), do: nil

  @doc "The studio id, or nil for an anonymous scope."
  def studio_id(%__MODULE__{studio: nil}), do: nil
  def studio_id(%__MODULE__{studio: %Studio{id: id}}), do: id

  @doc "The acting user's id, or nil."
  def user_id(%__MODULE__{user: nil}), do: nil
  def user_id(%__MODULE__{user: %User{id: id}}), do: id

  @doc "True when the scope is attached to a studio."
  def tenant?(%__MODULE__{studio: %Studio{}}), do: true
  def tenant?(%__MODULE__{}), do: false

  @doc """
  Raise unless the scope is studio-attached. Called at the top of every context
  function that touches tenant data, so a nil studio fails loudly at the
  boundary instead of quietly producing an unscoped query.
  """
  def require_studio!(%__MODULE__{studio: %Studio{}} = scope), do: scope

  def require_studio!(%__MODULE__{}) do
    raise ArgumentError, "this operation requires a studio-scoped scope"
  end
end
