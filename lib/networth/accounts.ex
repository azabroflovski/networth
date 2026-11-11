defmodule Networth.Accounts do
  @moduledoc """
  Financial accounts of a workspace.

  User accounts are assets (cash, bank, card, deposit, savings, receivable)
  or liabilities (credit_card, loan, payable). Personal debts are receivable
  (owed to me) and payable (I owe) accounts named after the counterparty. System accounts (income, expense, opening_balance,
  exchange) are created on demand, one per workspace and currency, and act as
  the other side of every ledger posting.

  Balances are always computed from ledger entries and returned in the
  account's natural sign: money held for assets, money owed for liabilities.
  """

  alias Networth.{Activity, DB, Ledger, Params, Scope, Workspaces}

  @user_types ~w(cash bank card deposit savings receivable credit_card loan payable)

  # Debit-normal kinds: their balance is the sum of their entries; for the
  # other kinds it is the negated sum (what is owed, earned or invested).
  @debit_normal ~w(asset expense)

  @doc """
  The sign that turns the sum of an account's entries into its balance in
  the natural sign: money held for assets, money owed for liabilities.
  Also the sign of a debit that increases the balance.
  """
  def sign(kind) when kind in @debit_normal, do: 1
  def sign(_kind), do: -1

  # With `on` (a placeholder), only operations dated up to that day count.
  defp select(on \\ nil) do
    entries =
      if on,
        do:
          "ledger_entries e JOIN transactions t ON t.id = e.transaction_id WHERE e.account_id = a.id AND t.occurred_on <= #{on}",
        else: "ledger_entries e WHERE e.account_id = a.id"

    """
    SELECT a.id, a.workspace_id, a.name, a.type, a.kind, a.currency, a.archived_at, a.inserted_at,
      (CASE WHEN a.kind IN (#{Enum.map_join(@debit_normal, ", ", &"'#{&1}'")}) THEN 1 ELSE -1 END)
        * coalesce((SELECT sum(e.amount) FROM #{entries}), 0)::bigint AS balance
    FROM accounts a
    """
  end

  def types, do: @user_types

  @doc "User accounts with their balances; with `on: date`, balances at the end of that day."
  def list(%Scope{} = scope, opts \\ []) do
    {sql, args} =
      case opts[:on] do
        nil -> {select(), [scope.workspace_id]}
        on -> {select("$2"), [scope.workspace_id, on]}
      end

    DB.all(
      sql <>
        " WHERE a.workspace_id = $1 AND NOT a.system ORDER BY a.archived_at NULLS FIRST, a.id",
      args
    )
  end

  def get(%Scope{} = scope, id) do
    with id when is_binary(id) <- Params.cast_id(id),
         %{} = account <-
           DB.one(select() <> " WHERE a.id = $1 AND a.workspace_id = $2 AND NOT a.system", [
             id,
             scope.workspace_id
           ]) do
      {:ok, account}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Creates an account. An optional `opening_balance` (natural sign, decimal
  string) is posted as an opening_balance transaction dated `opened_on`
  (default today in the workspace timezone).

  With an `idempotency_key`, a retried request returns the account created
  by the first one; the same key with other params is
  `{:error, :idempotency_key_reused}`.
  """
  def create(%Scope{} = scope, params) do
    with {:ok, %{name: name, type: type, currency: currency, opened_on: opened_on, key: key}} <-
           Params.all(
             name: Params.string(params, "name", required: true),
             type: Params.one_of(params, "type", @user_types, required: true),
             currency: Params.currency(params, "currency"),
             opened_on: Params.date(params, "opened_on", fn -> Workspaces.today(scope) end),
             key: Params.string(params, "idempotency_key")
           ),
         {:ok, opening_balance} <- Params.amount(params, "opening_balance", currency) do
      hash = key && Params.request_hash(params)

      result =
        DB.transaction(fn ->
          account =
            """
            INSERT INTO accounts (workspace_id, name, type, currency, idempotency_key, idempotency_hash)
            VALUES ($1, $2, $3, $4, $5, $6)
            ON CONFLICT (workspace_id, idempotency_key) DO NOTHING
            RETURNING *
            """
            |> DB.query([scope.workspace_id, name, type, currency, key, hash])
            |> handle_write() || DB.rollback(:duplicate)

          if opening_balance not in [nil, 0] do
            {:ok, _} = Ledger.post_opening_balance(scope, account, opening_balance, opened_on)
          end

          {:ok, account} = get(scope, account.id)

          Activity.record(scope, "account.created", "account", account.id,
            data: %{
              "name" => account.name,
              "type" => account.type,
              "currency" => account.currency,
              "opening_balance" => Activity.money(account.balance, account.currency)
            }
          )

          account
        end)

      # ON CONFLICT only covers the key's index. A concurrent retry can collide
      # on the name index first, so a name conflict is a retry if the key exists.
      case result do
        {:error, :duplicate} -> replay(scope, key, hash, result)
        {:error, {:invalid, %{"name" => _}}} when key != nil -> replay(scope, key, hash, result)
        other -> other
      end
    end
  end

  defp replay(scope, key, hash, failed) do
    existing =
      DB.one(
        "SELECT id, idempotency_hash FROM accounts WHERE workspace_id = $1 AND idempotency_key = $2",
        [scope.workspace_id, key]
      )

    cond do
      is_nil(existing) -> failed
      existing.idempotency_hash == hash -> get(scope, existing.id)
      true -> {:error, :idempotency_key_reused}
    end
  end

  @doc "Renames and/or archives (`\"archived\" => true`) an account."
  def update(%Scope{} = scope, id, params) do
    with {:ok, account} <- get(scope, id),
         {:ok, %{name: name, archived: archived}} <-
           Params.all(
             name: Params.string(params, "name", default: account.name),
             archived: Params.boolean(params, "archived")
           ) do
      DB.transaction(fn ->
        """
        UPDATE accounts SET name = $3,
          archived_at = CASE WHEN $4::boolean IS NULL THEN archived_at
                             WHEN $4 THEN coalesce(archived_at, now()) END
        WHERE id = $1 AND workspace_id = $2
        """
        |> DB.query([account.id, scope.workspace_id, name, archived])
        |> handle_write()

        {:ok, updated} = get(scope, account.id)
        changes = Activity.diff(editable(account), editable(updated), [:name, :archived])

        if changes != %{} do
          Activity.record(scope, "account.updated", "account", account.id,
            changes: changes,
            data: %{"name" => updated.name}
          )
        end

        updated
      end)
    end
  end

  defp editable(account), do: %{name: account.name, archived: account.archived_at != nil}

  @doc """
  Loads a user account for posting and locks it against concurrent archiving.
  Must run inside a transaction.
  """
  def fetch_for_posting(%Scope{} = scope, field, id) do
    account =
      DB.one(
        """
        SELECT id, name, type, kind, currency, archived_at FROM accounts
        WHERE id = $1 AND workspace_id = $2 AND NOT system
        FOR SHARE
        """,
        [id, scope.workspace_id]
      )

    cond do
      is_nil(account) -> Params.invalid(field, :not_found)
      account.archived_at -> Params.invalid(field, :archived)
      true -> {:ok, account}
    end
  end

  @doc "Returns the system account of `type` for the currency, creating it if needed."
  def system_account(workspace_id, type, currency)
      when type in ~w(income expense opening_balance exchange adjustment) do
    DB.query!(
      """
      INSERT INTO accounts (workspace_id, name, type, currency) VALUES ($1, $2, $3, $4)
      ON CONFLICT (workspace_id, type, currency) WHERE system DO NOTHING
      """,
      [workspace_id, "#{type} #{currency}", type, currency]
    )

    DB.one(
      "SELECT id, name, type, kind, currency FROM accounts WHERE workspace_id = $1 AND type = $2 AND currency = $3 AND system",
      [workspace_id, type, currency]
    )
  end

  defp handle_write({:ok, result}), do: result |> DB.to_maps() |> List.first()

  defp handle_write({:error, error}) do
    case DB.constraint_violation(error) do
      {:unique_violation, "accounts_name_index"} ->
        DB.rollback({:invalid, %{"name" => %{code: :already_exists}}})

      _ ->
        raise error
    end
  end
end
