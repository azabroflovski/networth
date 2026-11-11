defmodule Networth.Ledger.Correction do
  @moduledoc "Correcting an operation: reversal and the new version in one database transaction."

  alias Networth.{Activity, DB, Params, Scope}
  alias Networth.Ledger.{History, Posting, Reversal}

  def correct(%Scope{} = scope, id, params) do
    with {:ok, original} <- History.get(scope, id),
         {:ok, type} <- Params.one_of(params, "type", Posting.postable_types(), required: true),
         merged =
           Map.merge(
             %{
               "occurred_on" => Date.to_iso8601(original.occurred_on),
               "description" => original.description,
               "tag_ids" => original.tag_ids
             },
             params
           ),
         {:ok, attrs} <- Posting.common_attrs(scope, merged) do
      # The key fingerprints what the client sent, not the defaults filled in.
      attrs = %{attrs | idempotency_hash: attrs.idempotency_key && Params.request_hash(params)}

      DB.transaction(fn ->
        original = Reversal.lock(scope, original.id)

        cond do
          attrs.idempotency_key && key_used?(scope, attrs.idempotency_key) ->
            DB.rollback(:duplicate)

          original.type not in Posting.postable_types() ->
            DB.rollback({:invalid, %{"id" => %{code: :not_correctable}}})

          Reversal.reversal_of(original.id) ->
            DB.rollback(:already_reversed)

          true ->
            Reversal.insert(scope, original, original.occurred_on, nil)
            {:ok, before} = History.get(scope, original.id)

            corrected =
              Posting.post_new(scope, type, Map.put(attrs, :replaces_id, original.id), merged)

            Activity.record(scope, "transaction.corrected", "transaction", corrected.id,
              data: History.summary(corrected),
              changes: %{
                "amounts" => [
                  History.summary(before)["amounts"],
                  History.summary(corrected)["amounts"]
                ]
              }
            )

            corrected
        end
      end)
      |> Posting.replay_on_conflict(scope, attrs)
    end
  end

  defp key_used?(scope, key) do
    DB.one("SELECT 1 AS one FROM transactions WHERE workspace_id = $1 AND idempotency_key = $2", [
      scope.workspace_id,
      key
    ]) != nil
  end
end
