defmodule Networth.Ledger.Adjustment do
  @moduledoc "Reconciling an account with its real balance through an `adjustment`."

  alias Networth.{Accounts, Activity, DB, Money, Params, Scope, Workspaces}
  alias Networth.Ledger.Posting

  def adjust_balance(%Scope{} = scope, account_id, params) do
    with id when is_binary(id) <- Params.cast_id(account_id),
         {:ok, %{occurred_on: occurred_on, description: description}} <-
           Params.all(
             occurred_on: Params.date(params, "occurred_on", fn -> Workspaces.today(scope) end),
             description: Params.string(params, "description", max: 500)
           ) do
      DB.transaction(fn ->
        # FOR UPDATE keeps postings to this account out until we commit, so
        # the difference is computed against a stable balance.
        account =
          DB.one(
            """
            SELECT id, name, type, kind, currency, archived_at FROM accounts
            WHERE id = $1 AND workspace_id = $2 AND NOT system FOR UPDATE
            """,
            [id, scope.workspace_id]
          ) || DB.rollback(:not_found)

        if account.archived_at, do: DB.rollback({:invalid, %{"account_id" => %{code: :archived}}})

        actual =
          case Params.amount(params, "balance", account.currency, required: true) do
            {:ok, actual} -> actual
            {:error, reason} -> DB.rollback(reason)
          end

        sign = Accounts.sign(account.kind)

        %{sum: sum} =
          DB.one(
            """
            SELECT coalesce(sum(e.amount), 0)::bigint AS sum
            FROM ledger_entries e JOIN transactions t ON t.id = e.transaction_id
            WHERE e.account_id = $1 AND t.occurred_on <= $2
            """,
            [account.id, occurred_on]
          )

        case actual - sign * sum do
          0 -> nil
          difference -> post(scope, account, actual, difference, sign, occurred_on, description)
        end
      end)
    else
      {:error, _} = error -> error
      nil -> {:error, :not_found}
    end
  end

  defp post(scope, account, actual, difference, sign, occurred_on, description) do
    other = Accounts.system_account(scope.workspace_id, "adjustment", account.currency)
    debit = sign * difference

    adjustment =
      Posting.insert(scope, %{
        type: "adjustment",
        occurred_on: occurred_on,
        description: description,
        entries: [Posting.entry(account, debit), Posting.entry(other, -debit)]
      })

    Activity.record(scope, "account.balance_adjusted", "account", account.id,
      data: %{
        "account_name" => account.name,
        "transaction_id" => adjustment.id,
        "currency" => account.currency,
        "difference" => Money.format(difference, account.currency)
      },
      changes: %{
        "balance" => [
          Money.format(actual - difference, account.currency),
          Money.format(actual, account.currency)
        ]
      }
    )

    adjustment
  end
end
