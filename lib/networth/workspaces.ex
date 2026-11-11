defmodule Networth.Workspaces do
  @moduledoc """
  Workspaces, membership and invitations.

  A personal workspace is an ordinary workspace created at registration.
  Access to any workspace data goes through `authorize/2`.
  """

  alias Networth.{Activity, Categories, DB, Params, Scope, Users}

  require Logger

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

    with :ok <- require_owner(scope),
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

  @doc """
  Schedules the workspace for deletion after the configured delay (7 days).
  Owner only; `confirm` must equal the workspace name. Until then the
  workspace works as usual and the deletion can be cancelled.
  """
  def schedule_deletion(%Scope{} = scope, params) do
    workspace = get(scope)
    days = Application.fetch_env!(:networth, :workspace_deletion_delay_days)

    with :ok <- require_owner(scope),
         :ok <-
           if(params["confirm"] == workspace.name,
             do: :ok,
             else: Params.invalid("confirm", "must match the workspace name")
           ) do
      DB.transaction(fn ->
        %{num_rows: scheduled} =
          DB.query!(
            """
            UPDATE workspaces SET deletion_scheduled_at = now() + make_interval(days => $2)
            WHERE id = $1 AND deletion_scheduled_at IS NULL
            """,
            [scope.workspace_id, days]
          )

        workspace = get(scope)

        if scheduled == 1 do
          Activity.record(scope, "workspace.deletion_scheduled", "workspace", scope.workspace_id,
            data: %{"deletion_scheduled_at" => workspace.deletion_scheduled_at}
          )
        end

        workspace
      end)
    end
  end

  def cancel_deletion(%Scope{} = scope) do
    with :ok <- require_owner(scope) do
      DB.transaction(fn ->
        %{num_rows: cancelled} =
          DB.query!(
            "UPDATE workspaces SET deletion_scheduled_at = NULL WHERE id = $1 AND deletion_scheduled_at IS NOT NULL",
            [scope.workspace_id]
          )

        if cancelled == 1 do
          Activity.record(scope, "workspace.deletion_cancelled", "workspace", scope.workspace_id)
        end

        get(scope)
      end)
    end
  end

  @doc """
  Physically deletes every workspace whose deletion time has passed, with all
  its data. Returns the number of purged workspaces.
  """
  def purge_due_deletions do
    "SELECT id FROM workspaces WHERE deletion_scheduled_at <= now()"
    |> DB.all()
    |> Enum.count(&(purge(&1.id) == {:ok, true}))
  end

  # One failing workspace must not stop the others; the next run retries it.
  defp purge(id) do
    purge!(id)
  rescue
    error ->
      Logger.error("Failed to purge workspace #{id}: #{Exception.message(error)}")
      {:error, error}
  end

  # Children first; in each table one statement deletes all rows, so
  # references between rows of the same table are checked once at its end.
  @purge_order ~w(activity_events transaction_tags exchanges ledger_entries transactions
                  budgets accounts categories tags workspace_invitations workspace_members)

  defp purge!(id) do
    DB.transaction(fn ->
      # Locking the row blocks new rows referencing the workspace until we
      # commit, and re-checks that the deletion was not cancelled meanwhile.
      if DB.one(
           "SELECT id FROM workspaces WHERE id = $1 AND deletion_scheduled_at <= now() FOR UPDATE",
           [id]
         ) do
        # Lets the append-only triggers allow deleting this workspace's rows only.
        DB.query!("SELECT set_config('networth.purge_workspace', $1, true)", [id])

        for table <- @purge_order,
            do: DB.query!("DELETE FROM #{table} WHERE workspace_id = $1", [id])

        DB.query!("DELETE FROM workspaces WHERE id = $1", [id])
        Logger.info("Purged workspace #{id}")
        true
      else
        false
      end
    end)
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

  @member_select """
  SELECT u.id AS user_id, u.email, u.name, m.role, m.inserted_at
  FROM workspace_members m JOIN users u ON u.id = m.user_id
  """

  def list_members(%Scope{} = scope) do
    DB.all(@member_select <> " WHERE m.workspace_id = $1 ORDER BY m.inserted_at, u.id", [
      scope.workspace_id
    ])
  end

  @doc """
  Changes a member's role (`owner` or `member`). Owner only. Ownership is
  handed over by making someone else an owner and then stepping down.
  """
  def update_member(%Scope{} = scope, user_id, params) do
    with :ok <- require_owner(scope),
         {:ok, role} <- Params.one_of(params, "role", ["owner", "member"], required: true) do
      change_membership(scope, user_id, fn member, owners ->
        if member.role == "owner" and role == "member" and owners == 1 do
          {:error, :last_owner}
        else
          DB.query!(
            "UPDATE workspace_members SET role = $3 WHERE workspace_id = $1 AND user_id = $2",
            [scope.workspace_id, member.user_id, role]
          )

          updated = member_details(scope, member.user_id)

          if role != member.role do
            Activity.record(scope, "member.role_changed", "user", member.user_id,
              changes: %{"role" => [member.role, role]},
              data: %{"name" => updated.name, "email" => updated.email}
            )
          end

          updated
        end
      end)
    end
  end

  @doc """
  Removes a member. Owners can remove anyone; any member can remove
  themselves (leave the workspace). The last owner can do neither.
  The removed user's financial records stay: they belong to the workspace.
  """
  def remove_member(%Scope{} = scope, user_id) do
    with :ok <- if(Params.cast_id(user_id) == scope.user_id, do: :ok, else: require_owner(scope)),
         {:ok, :removed} <-
           change_membership(scope, user_id, fn member, owners ->
             if member.role == "owner" and owners == 1 do
               {:error, :last_owner}
             else
               details = member_details(scope, member.user_id)

               DB.query!(
                 "DELETE FROM workspace_members WHERE workspace_id = $1 AND user_id = $2",
                 [
                   scope.workspace_id,
                   member.user_id
                 ]
               )

               action =
                 if member.user_id == scope.user_id, do: "member.left", else: "member.removed"

               Activity.record(scope, action, "user", member.user_id,
                 data: %{"name" => details.name, "email" => details.email}
               )

               :removed
             end
           end) do
      :ok
    end
  end

  defp member_details(scope, user_id) do
    DB.one(@member_select <> " WHERE m.workspace_id = $1 AND m.user_id = $2", [
      scope.workspace_id,
      user_id
    ])
  end

  # Membership changes lock the workspace row so that concurrent changes are
  # serialized and the owner count read here stays true until commit.
  # The workspace_members_has_owner trigger enforces the same rule in the database.
  defp change_membership(scope, user_id, fun) do
    with id when is_binary(id) <- Params.cast_id(user_id) do
      DB.transaction(fn ->
        DB.query!("SELECT 1 FROM workspaces WHERE id = $1 FOR UPDATE", [scope.workspace_id])

        member =
          DB.one(
            "SELECT user_id, role FROM workspace_members WHERE workspace_id = $1 AND user_id = $2",
            [
              scope.workspace_id,
              id
            ]
          ) || DB.rollback(:not_found)

        %{owners: owners} =
          DB.one(
            "SELECT count(*) AS owners FROM workspace_members WHERE workspace_id = $1 AND role = 'owner'",
            [scope.workspace_id]
          )

        case fun.(member, owners) do
          {:error, reason} -> DB.rollback(reason)
          result -> result
        end
      end)
    else
      _ -> {:error, :not_found}
    end
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
          invitation = result |> DB.to_maps() |> hd()

          Activity.record(scope, "invitation.created", "invitation", invitation.id,
            data: %{"email" => email}
          )

          {:ok, invitation}

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
         {:ok, :ok} <-
           DB.transaction(fn ->
             %{rows: rows} =
               DB.query!(
                 """
                 DELETE FROM workspace_invitations
                 WHERE id = $1 AND workspace_id = $2 AND accepted_at IS NULL
                 RETURNING email
                 """,
                 [id, scope.workspace_id]
               )

             case rows do
               [[email]] ->
                 Activity.record(scope, "invitation.revoked", "invitation", id,
                   data: %{"email" => email}
                 )

               [] ->
                 DB.rollback(:not_found)
             end
           end) do
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

        Activity.record(scope, "member.joined", "user", user.id,
          data: %{"name" => user.name, "email" => user.email}
        )

        get(scope)
      end)
    else
      _ -> {:error, :not_found}
    end
  end

  defp require_owner(scope), do: if(Scope.owner?(scope), do: :ok, else: {:error, :forbidden})
end
