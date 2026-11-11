defmodule Networth.Ledger.Reversal do
  @moduledoc "Reversing a transaction: a `reversal` with every entry negated."

  alias Networth.{Activity, DB, Params, Scope}
  alias Networth.Ledger.{History, Posting}

  def reverse(%Scope{} = scope, id, params \\ %{}) do
    with id when is_binary(id) <- Params.cast_id(id),
         {:ok, occurred_on} <- Params.date(params, "occurred_on", nil),
         {:ok, description} <- Params.string(params, "description", max: 500) do
      DB.transaction(fn ->
        original = lock(scope, id) || DB.rollback(:not_found)
        existing = reversal_of(original.id)

        cond do
          original.type == "reversal" ->
            DB.rollback({:invalid, %{"id" => "a reversal cannot be reversed"}})

          existing ->
            {:ok, reversal} = History.get(scope, existing.id)
            reversal

          true ->
            reversal = insert(scope, original, occurred_on || original.occurred_on, description)
            {:ok, original} = History.get(scope, original.id)

            Activity.record(scope, "transaction.reversed", "transaction", original.id,
              data: Map.put(History.summary(original), "reversal_id", reversal.id)
            )

            reversal
        end
      end)
    else
      {:error, _} = error -> error
      nil -> {:error, :not_found}
    end
  end

  @doc "Locks a transaction of the workspace for a reversal or correction."
  def lock(scope, id) do
    DB.one(
      "SELECT id, type, occurred_on FROM transactions WHERE id = $1 AND workspace_id = $2 FOR UPDATE",
      [id, scope.workspace_id]
    )
  end

  def reversal_of(id), do: DB.one("SELECT id FROM transactions WHERE reverses_id = $1", [id])

  @doc "Posts the reversal of `original`; must run in a transaction."
  def insert(scope, original, occurred_on, description) do
    entries =
      DB.all(
        """
        SELECT account_id, currency, account_kind, -amount AS amount, category_id
        FROM ledger_entries WHERE transaction_id = $1 ORDER BY id
        """,
        [original.id]
      )

    Posting.insert(scope, %{
      type: "reversal",
      occurred_on: occurred_on,
      description: description,
      reverses_id: original.id,
      entries: entries
    })
  end
end
