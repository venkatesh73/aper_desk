defmodule AperDesk.Visibility do
  @moduledoc """
  Which rows a role may see *within* the studio it already belongs to.

  `AperDesk.Scoped` answers "is this the right tenant". This answers the
  narrower question the permission table cannot: a photographer holds
  `lead.read`, but holding it does not mean seeing the whole studio's pipeline.
  `AperDesk.Authorization` is a table of verbs and has no room for "only their
  own", so that policy lives here rather than as an `if role ==` scattered
  through four contexts.

  Only the photographer is narrowed today. Owner, finance, HR and ops each see
  the studio-wide set of whatever their permissions let them read, because
  their jobs are studio-wide: finance chasing only its own invoices would be
  meaningless.

  "Own" is defined per entity because it has to be:

    * a **lead** is theirs if they are its owner
    * a **shoot** is theirs if they are assigned to it — jobs have no owner
      column, and the crew list is the only honest answer
    * a **gallery** is theirs if they own it, or it belongs to a shoot they
      were on, because the person who covered the day is the person who
      delivers it

  Anything not narrowed here is visible studio-wide on purpose. Contacts are
  the notable one: a photographer needs to look up the phone number of a client
  whose lead belongs to somebody else, and a directory nobody can search is
  worse than useless.
  """

  import Ecto.Query

  alias AperDesk.Scope

  @narrowed_roles [:photographer]

  @doc "Whether this scope sees only its own work rather than the studio's."
  def own_work_only?(%Scope{role: role}), do: role in @narrowed_roles

  @doc "The roles that are narrowed, for the settings screen to explain itself."
  def narrowed_roles, do: @narrowed_roles

  @doc "Narrow a lead query to the ones this scope may see."
  def leads(query, %Scope{} = scope) do
    if own_work_only?(scope) do
      where(query, [l], l.owner_id == ^Scope.user_id(scope))
    else
      query
    end
  end

  @doc """
  Narrow a job query.

  A job has no owner column, so "mine" means "I am on the crew". Released
  assignments do not count — being taken off a shoot is how a studio removes
  someone from it, and it would not work if the row still granted sight of it.
  """
  def jobs(query, %Scope{} = scope) do
    if own_work_only?(scope) do
      user_id = Scope.user_id(scope)

      where(
        query,
        [j],
        exists(
          from a in AperDesk.Scheduling.Assignment,
            where:
              a.job_id == parent_as(:job).id and a.user_id == ^user_id and
                is_nil(a.released_at),
            select: 1
        )
      )
    else
      query
    end
  end

  @doc "Narrow a gallery query: theirs, or attached to a shoot they were on."
  def galleries(query, %Scope{} = scope) do
    if own_work_only?(scope) do
      user_id = Scope.user_id(scope)

      where(
        query,
        [g],
        g.owner_id == ^user_id or
          exists(
            from a in AperDesk.Scheduling.Assignment,
              where:
                a.job_id == parent_as(:gallery).job_id and a.user_id == ^user_id and
                  is_nil(a.released_at),
              select: 1
          )
      )
    else
      query
    end
  end

  @doc """
  Whether this scope may see one already-loaded row.

  For the fetch paths, where the row is read by id and narrowing the query
  would turn "not yours" into "not found". Both answers end the request, but
  only one of them is true.
  """
  def visible?(%Scope{} = scope, row) do
    not own_work_only?(scope) or owns?(scope, row)
  end

  defp owns?(%Scope{} = scope, %AperDesk.Crm.Lead{} = lead),
    do: lead.owner_id == Scope.user_id(scope)

  defp owns?(%Scope{} = scope, %AperDesk.Scheduling.Job{} = job),
    do: assigned?(scope, job.id)

  defp owns?(%Scope{} = scope, %AperDesk.Galleries.Gallery{} = gallery),
    do: gallery.owner_id == Scope.user_id(scope) or assigned?(scope, gallery.job_id)

  # Anything without an ownership rule is studio-wide by design.
  defp owns?(%Scope{}, _row), do: true

  defp assigned?(_scope, nil), do: false

  defp assigned?(%Scope{} = scope, job_id) do
    AperDesk.Repo.exists?(
      from a in AperDesk.Scheduling.Assignment,
        where:
          a.job_id == ^job_id and a.user_id == ^Scope.user_id(scope) and is_nil(a.released_at)
    )
  end
end
