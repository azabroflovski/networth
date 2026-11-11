defmodule Networth.Workspaces.Invitations do
  @moduledoc """
  Invitations by email. Only the user registered with the invited email can
  accept; accepting makes them a member.
  """

  alias Networth.{Activity, DB, Params, Scope, Users, Workspaces}

  def invite(%Scope{} = scope, params) do
    with :ok <- Scope.require_owner(scope),
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
    with :ok <- Scope.require_owner(scope) do
      {:ok,
       DB.all(
         "SELECT * FROM workspace_invitations WHERE workspace_id = $1 AND accepted_at IS NULL ORDER BY id",
         [scope.workspace_id]
       )}
    end
  end

  def revoke_invitation(%Scope{} = scope, invitation_id) do
    with :ok <- Scope.require_owner(scope),
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

        {:ok, scope} = Workspaces.authorize(user.id, invitation.workspace_id)

        Activity.record(scope, "member.joined", "user", user.id,
          data: %{"name" => user.name, "email" => user.email}
        )

        Workspaces.get(scope)
      end)
    else
      _ -> {:error, :not_found}
    end
  end
end
