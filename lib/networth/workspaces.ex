defmodule Networth.Workspaces do
  @moduledoc """
  Workspaces: creating, access (`authorize/2`), settings. Membership,
  invitations and deletion live in `workspaces/` and are reached through
  this module.

  A personal workspace is an ordinary workspace created at registration.
  Access to any workspace data goes through `authorize/2`.
  """

  alias Networth.{Activity, Categories, DB, Params, Scope}
  alias Networth.Workspaces.{Deletion, Invitations, Members}

  @doc "Creates a workspace owned by `user_id`, seeded with default categories."
  def create(user_id, params) do
    with {:ok, name} <- Params.string(params, "name", required: true),
         {:ok, timezone} <- timezone(params, "UTC") do
      DB.transaction(fn ->
        workspace =
          DB.one("INSERT INTO workspaces (name, timezone) VALUES ($1, $2) RETURNING *", [
            name,
            timezone
          ])

        DB.query!(
          "INSERT INTO workspace_members (workspace_id, user_id, role) VALUES ($1, $2, 'owner')",
          [workspace.id, user_id]
        )

        Categories.create_defaults(workspace.id)

        scope = %Scope{user_id: user_id, workspace_id: workspace.id, role: "owner"}
        data = %{"name" => workspace.name, "timezone" => workspace.timezone}
        Activity.record(scope, "workspace.created", "workspace", workspace.id, data: data)

        Map.put(workspace, :role, "owner")
      end)
    end
  end

  @doc """
  Returns the scope for acting in a workspace. Non-members get `:not_found`,
  so the existence of other workspaces is not revealed.
  """
  def authorize(user_id, workspace_id) do
    with id when is_binary(id) <- Params.cast_id(workspace_id),
         %{role: role} <-
           DB.one(
             "SELECT role FROM workspace_members WHERE workspace_id = $1 AND user_id = $2",
             [id, user_id]
           ) do
      {:ok, %Scope{user_id: user_id, workspace_id: id, role: role}}
    else
      _ -> {:error, :not_found}
    end
  end

  def list_for_user(user_id) do
    DB.all(
      """
      SELECT w.*, m.role FROM workspaces w
      JOIN workspace_members m ON m.workspace_id = w.id
      WHERE m.user_id = $1
      ORDER BY w.id
      """,
      [user_id]
    )
  end

  def get(%Scope{} = scope) do
    "SELECT * FROM workspaces WHERE id = $1"
    |> DB.one([scope.workspace_id])
    |> Map.put(:role, scope.role)
  end

  @doc "Changes name and/or timezone. Owner only."
  def update(%Scope{} = scope, params) do
    current = get(scope)

    with :ok <- Scope.require_owner(scope),
         {:ok, name} <- Params.string(params, "name", default: current.name),
         {:ok, timezone} <- timezone(params, current.timezone) do
      DB.transaction(fn ->
        DB.query!("UPDATE workspaces SET name = $2, timezone = $3 WHERE id = $1", [
          scope.workspace_id,
          name,
          timezone
        ])

        updated = get(scope)
        changes = Activity.diff(current, updated, [:name, :timezone])

        if changes != %{} do
          Activity.record(scope, "workspace.updated", "workspace", scope.workspace_id,
            changes: changes
          )
        end

        updated
      end)
    end
  end

  @doc "Today's date in the workspace timezone."
  def today(%Scope{} = scope) do
    %{today: today} =
      DB.one(
        "SELECT (now() AT TIME ZONE timezone)::date AS today FROM workspaces WHERE id = $1",
        [
          scope.workspace_id
        ]
      )

    today
  end

  defp timezone(params, default) do
    with {:ok, tz} <- Params.string(params, "timezone", default: default) do
      if MapSet.member?(timezones(), tz),
        do: {:ok, tz},
        else: Params.invalid("timezone", "is not a known IANA time zone")
    end
  end

  # pg_timezone_names reads the time zone files on every query (~40 ms), and
  # the list only changes with a PostgreSQL upgrade, so it is cached.
  defp timezones do
    case :persistent_term.get({__MODULE__, :timezones}, nil) do
      nil ->
        names =
          "SELECT name FROM pg_timezone_names" |> DB.all() |> MapSet.new(& &1.name)

        :persistent_term.put({__MODULE__, :timezones}, names)
        names

      names ->
        names
    end
  end

  defdelegate list_members(scope), to: Members

  @doc """
  Changes a member's role (`owner` or `member`). Owner only. Ownership is
  handed over by making someone else an owner and then stepping down.
  """
  defdelegate update_member(scope, user_id, params), to: Members

  @doc """
  Removes a member. Owners can remove anyone; any member can remove
  themselves (leave the workspace). The last owner can do neither.
  The removed user's financial records stay: they belong to the workspace.
  """
  defdelegate remove_member(scope, user_id), to: Members

  defdelegate invite(scope, params), to: Invitations
  defdelegate list_invitations(scope), to: Invitations
  defdelegate revoke_invitation(scope, invitation_id), to: Invitations

  @doc "Pending invitations addressed to the user's email."
  defdelegate pending_invitations(user), to: Invitations

  defdelegate accept_invitation(user, invitation_id), to: Invitations

  @doc """
  Schedules the workspace for deletion after the configured delay (7 days).
  Owner only; `confirm` must equal the workspace name. Until then the
  workspace works as usual and the deletion can be cancelled.
  """
  defdelegate schedule_deletion(scope, params), to: Deletion

  defdelegate cancel_deletion(scope), to: Deletion

  @doc """
  Physically deletes every workspace whose deletion time has passed, with all
  its data. Returns the number of purged workspaces.
  """
  defdelegate purge_due_deletions(), to: Deletion
end
