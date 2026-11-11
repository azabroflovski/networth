defmodule Networth.Workspaces.Deletion do
  @moduledoc """
  Deleting a workspace: scheduled by its owner with a delay, cancellable,
  then purged with all its data by `Networth.Maintenance`. The only place
  where financial data is physically deleted.
  """

  alias Networth.{Activity, DB, Params, Scope, Workspaces}

  require Logger

  def schedule_deletion(%Scope{} = scope, params) do
    workspace = Workspaces.get(scope)
    days = Application.fetch_env!(:networth, :workspace_deletion_delay_days)

    with :ok <- Scope.require_owner(scope),
         :ok <-
           if(params["confirm"] == workspace.name,
             do: :ok,
             else: Params.invalid("confirm", :confirmation_mismatch)
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

        workspace = Workspaces.get(scope)

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
    with :ok <- Scope.require_owner(scope) do
      DB.transaction(fn ->
        %{num_rows: cancelled} =
          DB.query!(
            "UPDATE workspaces SET deletion_scheduled_at = NULL WHERE id = $1 AND deletion_scheduled_at IS NOT NULL",
            [scope.workspace_id]
          )

        if cancelled == 1 do
          Activity.record(scope, "workspace.deletion_cancelled", "workspace", scope.workspace_id)
        end

        Workspaces.get(scope)
      end)
    end
  end

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
  @purge_order ~w(activity_log transaction_tags exchanges ledger_entries transactions
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
end
