defmodule Networth.Ledger.Editing do
  @moduledoc """
  Changes to a posted transaction that do not touch money: its description
  (recorded by the database in the activity log) and its tags.
  """

  alias Networth.{Activity, DB, Params, Scope, Tags}
  alias Networth.Ledger.{History, Posting}

  @ledger_fields ~w(type account_id from_account_id to_account_id amount from_amount to_amount
                    lines category_id occurred_on)

  def update(%Scope{} = scope, id, params) do
    with {:ok, transaction} <- History.get(scope, id),
         :ok <- reject_ledger_fields(params),
         {:ok, description} <- new_description(params) do
      if description == transaction.description do
        {:ok, transaction}
      else
        DB.transaction(fn ->
          # The transactions_guard trigger records the edit with this author.
          DB.query!("SELECT set_config('networth.user_id', $1, true)", [scope.user_id])

          DB.query!(
            "UPDATE transactions SET description = $3 WHERE id = $1 AND workspace_id = $2",
            [
              transaction.id,
              scope.workspace_id,
              description
            ]
          )

          {:ok, transaction} = History.get(scope, transaction.id)
          transaction
        end)
      end
    end
  end

  defp reject_ledger_fields(params) do
    case Enum.find(@ledger_fields, &Map.has_key?(params, &1)) do
      nil ->
        :ok

      field ->
        Params.invalid(field, "cannot be changed; reverse the transaction and post a new one")
    end
  end

  # An explicit null or blank string clears the description.
  defp new_description(params) do
    if Map.has_key?(params, "description"),
      do: Params.string(params, "description", max: 500),
      else: Params.invalid("description", "is required")
  end

  def set_tags(%Scope{} = scope, id, params) do
    with {:ok, transaction} <- History.get(scope, id),
         {:ok, tag_ids} <- Params.ids(params, "tag_ids"),
         :ok <- Tags.validate_ids(scope, tag_ids) do
      DB.transaction(fn ->
        DB.query!("DELETE FROM transaction_tags WHERE transaction_id = $1", [transaction.id])
        Posting.insert_tags(scope, transaction.id, tag_ids)
        {:ok, updated} = History.get(scope, transaction.id)

        if updated.tag_ids != transaction.tag_ids do
          Activity.record(scope, "transaction.tags_changed", "transaction", transaction.id,
            changes: Activity.diff(transaction, updated, [:tag_ids])
          )
        end

        updated
      end)
    end
  end
end
