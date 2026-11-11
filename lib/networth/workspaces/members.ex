defmodule Networth.Workspaces.Members do
  @moduledoc """
  Workspace members and roles. Every workspace keeps at least one owner:
  changes lock the workspace row, and the workspace_members_has_owner
  trigger enforces the rule in the database as well.
  """

  alias Networth.{Activity, DB, Params, Scope}

  @member_select """
  SELECT u.id AS user_id, u.email, u.name, m.role, m.inserted_at
  FROM workspace_members m JOIN users u ON u.id = m.user_id
  """

  def list_members(%Scope{} = scope) do
    DB.all(@member_select <> " WHERE m.workspace_id = $1 ORDER BY m.inserted_at, u.id", [
      scope.workspace_id
    ])
  end

  def update_member(%Scope{} = scope, user_id, params) do
    with :ok <- Scope.require_owner(scope),
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

  def remove_member(%Scope{} = scope, user_id) do
    with :ok <-
           if(Params.cast_id(user_id) == scope.user_id, do: :ok, else: Scope.require_owner(scope)),
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
end
