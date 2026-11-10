defmodule Networth.Workspaces do
  @moduledoc """
  Workspaces, membership and invitations.

  A personal workspace is an ordinary workspace created at registration.
  Access to any workspace data goes through `authorize/2`.
  """

  alias Networth.{Categories, DB, Params, Scope, Users}

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

    with :ok <- require_owner(scope),
         {:ok, name} <- Params.string(params, "name", default: current.name),
         {:ok, timezone} <- timezone(params, current.timezone) do
      DB.query!("UPDATE workspaces SET name = $2, timezone = $3 WHERE id = $1", [
        scope.workspace_id,
        name,
        timezone
      ])

      {:ok, get(scope)}
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
      if DB.one("SELECT 1 AS one FROM pg_timezone_names WHERE name = $1", [tz]),
        do: {:ok, tz},
        else: Params.invalid("timezone", "is not a known IANA time zone")
    end
  end

  def list_members(%Scope{} = scope) do
    DB.all(
      """
      SELECT u.id AS user_id, u.email, u.name, m.role, m.inserted_at
      FROM workspace_members m JOIN users u ON u.id = m.user_id
      WHERE m.workspace_id = $1
      ORDER BY m.inserted_at, u.id
      """,
      [scope.workspace_id]
    )
  end

  def invite(%Scope{} = scope, params) do
    with :ok <- require_owner(scope),
         {:ok, email} <- Users.email(params),
         :ok <- not_a_member(scope.workspace_id, email) do
      case DB.query(
             """
             INSERT INTO workspace_invitations (workspace_id, email, invited_by)
             VALUES ($1, $2, $3) RETURNING *
             """,
             [scope.workspace_id, email, scope.user_id]
           ) do
        {:ok, result} ->
          {:ok, result |> DB.to_maps() |> hd()}

        {:error, error} ->
          case DB.constraint_violation(error) do
            {:unique_violation, "workspace_invitations_pending_index"} ->
              Params.invalid("email", "already has a pending invitation")

            _ ->
              raise error
          end
      end
    end
  end

  defp not_a_member(workspace_id, email) do
    member? =
      DB.one(
        """
        SELECT 1 AS one FROM workspace_members m JOIN users u ON u.id = m.user_id
        WHERE m.workspace_id = $1 AND u.email = $2
        """,
        [workspace_id, email]
      )

    if member?, do: Params.invalid("email", "is already a member"), else: :ok
  end

  def list_invitations(%Scope{} = scope) do
    with :ok <- require_owner(scope) do
      {:ok,
       DB.all(
         "SELECT * FROM workspace_invitations WHERE workspace_id = $1 AND accepted_at IS NULL ORDER BY id",
         [scope.workspace_id]
       )}
    end
  end

  def revoke_invitation(%Scope{} = scope, invitation_id) do
    with :ok <- require_owner(scope),
         id when is_binary(id) <- Params.cast_id(invitation_id),
         %{num_rows: 1} <-
           DB.query!(
             "DELETE FROM workspace_invitations WHERE id = $1 AND workspace_id = $2 AND accepted_at IS NULL",
             [id, scope.workspace_id]
           ) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  @doc "Pending invitations addressed to the user's email."
  def pending_invitations(user) do
    DB.all(
      """
      SELECT i.id, i.workspace_id, w.name AS workspace_name, i.inserted_at
      FROM workspace_invitations i JOIN workspaces w ON w.id = i.workspace_id
      WHERE i.email = $1 AND i.accepted_at IS NULL
      ORDER BY i.id
      """,
      [user.email]
    )
  end

  def accept_invitation(user, invitation_id) do
    with id when is_binary(id) <- Params.cast_id(invitation_id) do
      DB.transaction(fn ->
        invitation =
          DB.one(
            """
            SELECT * FROM workspace_invitations
            WHERE id = $1 AND email = $2 AND accepted_at IS NULL
            FOR UPDATE
            """,
            [id, user.email]
          ) || DB.rollback(:not_found)

        DB.query!(
          """
          INSERT INTO workspace_members (workspace_id, user_id, role) VALUES ($1, $2, 'member')
          ON CONFLICT DO NOTHING
          """,
          [invitation.workspace_id, user.id]
        )

        DB.query!(
          "UPDATE workspace_invitations SET accepted_by = $2, accepted_at = now() WHERE id = $1",
          [id, user.id]
        )

        {:ok, scope} = authorize(user.id, invitation.workspace_id)
        get(scope)
      end)
    else
      _ -> {:error, :not_found}
    end
  end

  defp require_owner(scope), do: if(Scope.owner?(scope), do: :ok, else: {:error, :forbidden})
end
