defmodule Networth.Ledger do
  @moduledoc """
  Double-entry ledger: posting financial operations, reversing them and
  reading their history.

  A transaction is one user-level operation (an expense, a transfer, ...).
  Posting it writes balanced ledger entries: in every currency the debits
  (positive amounts) equal the credits (negative amounts). Transactions and
  entries are never updated or deleted; a mistake is corrected by reversing
  the transaction and posting a new one.

  Categories are carried by the entries on income/expense accounts, one entry
  per line, so an expense can be split across several categories.

  `post/2` is the single entry point for creating operations from any input
  channel (HTTP today, other adapters later). It accepts string-keyed params
  with amounts as decimal strings in major units.
  """

  alias Networth.{Accounts, Categories, DB, Money, Params, Scope, Tags, Workspaces}

  @postable_types ~w(expense income transfer exchange)
  @max_lines 50
  @max_minor 9_223_372_036_854_775_807

  @doc """
  Posts a new operation. Params by type:

    * expense / income: account_id and either amount + category_id (optional)
      or lines: [%{"amount" => ..., "category_id" => ...}, ...] for a split
    * transfer: from_account_id, to_account_id, amount (same currency)
    * exchange: from_account_id, from_amount, to_account_id, to_amount

  Common: occurred_on (ISO date, default today in the workspace timezone),
  description, tag_ids, idempotency_key, and id (a client-generated UUIDv7;
  `{:error, :id_taken}` if it already exists).

  Repeating a request with the same idempotency_key returns the originally
  posted transaction; reusing the key with different params returns
  `{:error, :idempotency_key_reused}`.
  """
  def post(%Scope{} = scope, params) do
    with {:ok, type} <- Params.one_of(params, "type", @postable_types, required: true),
         {:ok, attrs} <- common_attrs(scope, params) do
      result =
        DB.transaction(fn ->
          with {:ok, posting} <- build(type, scope, params),
               :ok <- Tags.validate_ids(scope, attrs.tag_ids) do
            insert(scope, Map.merge(attrs, posting) |> Map.put(:type, type))
          else
            {:error, reason} -> DB.rollback(reason)
          end
        end)

      # ON CONFLICT only covers the key's index. A concurrent retry with the
      # same client id can collide on the primary key first, so id_taken is a
      # retry if the key exists.
      case result do
        {:error, :duplicate} -> replay(scope, attrs, result)
        {:error, :id_taken} when attrs.idempotency_key != nil -> replay(scope, attrs, result)
        other -> other
      end
    end
  end

  defp common_attrs(scope, params) do
    with {:ok, occurred_on} <-
           Params.date(params, "occurred_on", fn -> Workspaces.today(scope) end),
         {:ok, description} <- Params.string(params, "description", max: 500),
         {:ok, tag_ids} <- Params.ids(params, "tag_ids"),
         {:ok, id} <- client_id(params),
         {:ok, key} <- Params.string(params, "idempotency_key") do
      {:ok,
       %{
         occurred_on: occurred_on,
         description: description,
         tag_ids: tag_ids,
         id: id,
         idempotency_key: key,
         idempotency_hash: key && Params.request_hash(params)
       }}
    end
  end

  # A client may generate the id itself (offline input, AI drafts). It must be
  # a UUIDv7 so that inserts stay ordered in the primary key index.
  defp client_id(params) do
    case Params.id(params, "id") do
      {:ok, <<_::binary-14, ?7, _::binary>> = id} -> {:ok, id}
      {:ok, nil} -> {:ok, nil}
      _ -> Params.invalid("id", "must be a UUIDv7")
    end
  end

  defp replay(scope, attrs, failed) do
    existing =
      DB.one(
        "SELECT id, idempotency_hash FROM transactions WHERE workspace_id = $1 AND idempotency_key = $2",
        [scope.workspace_id, attrs.idempotency_key]
      )

    cond do
      is_nil(existing) -> failed
      existing.idempotency_hash == attrs.idempotency_hash -> get(scope, existing.id)
      true -> {:error, :idempotency_key_reused}
    end
  end

  defp build(type, scope, params) when type in ["expense", "income"] do
    with {:ok, account} <- account(scope, params, "account_id"),
         {:ok, lines} <- lines(scope, params, type, account.currency) do
      other = Accounts.system_account(scope.workspace_id, type, account.currency)
      total = lines |> Enum.map(& &1.amount) |> Enum.sum()

      entries =
        case type do
          "expense" ->
            Enum.map(lines, &entry(other, &1.amount, &1.category_id)) ++ [entry(account, -total)]

          "income" ->
            [entry(account, total) | Enum.map(lines, &entry(other, -&1.amount, &1.category_id))]
        end

      {:ok, %{entries: entries}}
    end
  end

  defp build("transfer", scope, params) do
    with {:ok, from} <- account(scope, params, "from_account_id"),
         {:ok, to} <- account(scope, params, "to_account_id"),
         :ok <- distinct_accounts(from, to),
         :ok <- same_currency(from, to),
         {:ok, amount} <-
           Params.amount(params, "amount", from.currency, required: true, positive: true) do
      {:ok, %{entries: [entry(to, amount), entry(from, -amount)]}}
    end
  end

  defp build("exchange", scope, params) do
    with {:ok, from} <- account(scope, params, "from_account_id"),
         {:ok, to} <- account(scope, params, "to_account_id"),
         :ok <-
           if(from.currency == to.currency,
             do:
               Params.invalid("to_account_id", "must be in a different currency; use a transfer"),
             else: :ok
           ),
         {:ok, from_amount} <-
           Params.amount(params, "from_amount", from.currency, required: true, positive: true),
         {:ok, to_amount} <-
           Params.amount(params, "to_amount", to.currency, required: true, positive: true) do
      from_exchange = Accounts.system_account(scope.workspace_id, "exchange", from.currency)
      to_exchange = Accounts.system_account(scope.workspace_id, "exchange", to.currency)

      rate =
        Money.rate(
          from_amount,
          Networth.Currencies.exponent!(from.currency),
          to_amount,
          Networth.Currencies.exponent!(to.currency)
        )

      {:ok,
       %{
         entries: [
           entry(from_exchange, from_amount),
           entry(from, -from_amount),
           entry(to, to_amount),
           entry(to_exchange, -to_amount)
         ],
         exchange: %{
           from: from,
           from_amount: from_amount,
           to: to,
           to_amount: to_amount,
           rate: rate
         }
       }}
    end
  end

  defp entry(account, amount, category_id \\ nil) do
    %{
      account_id: account.id,
      currency: account.currency,
      account_kind: account.kind,
      amount: amount,
      category_id: category_id
    }
  end

  # A plain expense/income is a single line built from the top-level
  # amount and category_id; a split passes "lines" instead.
  defp lines(scope, params, kind, currency) do
    case Map.fetch(params, "lines") do
      :error ->
        with {:ok, line} <- line(scope, params, kind, currency, ""), do: {:ok, [line]}

      {:ok, lines} when is_list(lines) and lines != [] and length(lines) <= @max_lines ->
        cond do
          Map.has_key?(params, "amount") or Map.has_key?(params, "category_id") ->
            Params.invalid("lines", "cannot be combined with amount or category_id")

          not Enum.all?(lines, &is_map/1) ->
            Params.invalid("lines", "must be a list of objects")

          true ->
            lines
            |> Enum.with_index()
            |> Enum.reduce_while({:ok, []}, fn {line, i}, {:ok, acc} ->
              case line(scope, line, kind, currency, "lines.#{i}.") do
                {:ok, line} -> {:cont, {:ok, [line | acc]}}
                error -> {:halt, error}
              end
            end)
            |> case do
              {:ok, acc} -> within_range(Enum.reverse(acc))
              error -> error
            end
        end

      _ ->
        Params.invalid("lines", "must be a list of 1 to #{@max_lines} lines")
    end
  end

  defp line(scope, params, kind, currency, prefix) do
    with {:ok, amount} <-
           Params.amount(params, "amount", currency, required: true, positive: true)
           |> prefix_error(prefix),
         {:ok, category_id} <- category(scope, params, kind) |> prefix_error(prefix) do
      {:ok, %{amount: amount, category_id: category_id}}
    end
  end

  defp within_range(lines) do
    if lines |> Enum.map(& &1.amount) |> Enum.sum() <= @max_minor,
      do: {:ok, lines},
      else: Params.invalid("lines", "total is too large")
  end

  defp prefix_error({:error, {:invalid, errors}}, prefix) when prefix != "" do
    {:error, {:invalid, Map.new(errors, fn {k, v} -> {prefix <> k, v} end)}}
  end

  defp prefix_error(result, _prefix), do: result

  defp account(scope, params, field) do
    with {:ok, id} <- Params.id(params, field, required: true) do
      Accounts.fetch_for_posting(scope, field, id)
    end
  end

  defp distinct_accounts(from, to) do
    if from.id == to.id,
      do: Params.invalid("to_account_id", "must differ from from_account_id"),
      else: :ok
  end

  defp same_currency(from, to) do
    if from.currency == to.currency,
      do: :ok,
      else: Params.invalid("to_account_id", "has a different currency; use an exchange")
  end

  defp category(scope, params, kind) do
    with {:ok, id} when not is_nil(id) <- Params.id(params, "category_id") do
      case Categories.get(scope, id) do
        {:ok, %{kind: ^kind, archived_at: nil}} -> {:ok, id}
        {:ok, %{kind: ^kind}} -> Params.invalid("category_id", "is archived")
        {:ok, _} -> Params.invalid("category_id", "must be an #{kind} category")
        {:error, :not_found} -> Params.invalid("category_id", "does not exist")
      end
    end
  end

  @doc false
  # Used by Accounts.create/2. `amount` is in the account's natural sign.
  def post_opening_balance(%Scope{} = scope, account, amount, occurred_on) do
    DB.transaction(fn ->
      equity = Accounts.system_account(scope.workspace_id, "opening_balance", account.currency)
      debit = if account.kind == "asset", do: amount, else: -amount

      insert(scope, %{
        type: "opening_balance",
        occurred_on: occurred_on,
        entries: [entry(account, debit), entry(equity, -debit)]
      })
    end)
  end

  defp insert(scope, attrs) do
    result =
      DB.query(
        """
        INSERT INTO transactions
          (id, workspace_id, type, occurred_on, description, reverses_id,
           idempotency_key, idempotency_hash, created_by)
        VALUES (coalesce($1, uuidv7()), $2, $3, $4, $5, $6, $7, $8, $9)
        ON CONFLICT (workspace_id, idempotency_key) DO NOTHING
        RETURNING id
        """,
        [
          attrs[:id],
          scope.workspace_id,
          attrs.type,
          attrs.occurred_on,
          attrs[:description],
          attrs[:reverses_id],
          attrs[:idempotency_key],
          attrs[:idempotency_hash],
          scope.user_id
        ]
      )

    id =
      case result do
        {:ok, %{rows: [[id]]}} ->
          id

        {:ok, %{rows: []}} ->
          DB.rollback(:duplicate)

        {:error, error} ->
          case DB.constraint_violation(error) do
            {:unique_violation, "transactions_pkey"} -> DB.rollback(:id_taken)
            _ -> raise error
          end
      end

    entries = attrs.entries

    DB.query!(
      """
      INSERT INTO ledger_entries
        (workspace_id, transaction_id, account_id, currency, account_kind, amount, category_id)
      SELECT $1, $2, account_id, currency, account_kind, amount, category_id
      FROM unnest($3::uuid[], $4::text[], $5::text[], $6::bigint[], $7::uuid[])
        AS e(account_id, currency, account_kind, amount, category_id)
      """,
      [
        scope.workspace_id,
        id,
        Enum.map(entries, & &1.account_id),
        Enum.map(entries, & &1.currency),
        Enum.map(entries, & &1.account_kind),
        Enum.map(entries, & &1.amount),
        Enum.map(entries, & &1.category_id)
      ]
    )

    if exchange = attrs[:exchange] do
      DB.query!(
        """
        INSERT INTO exchanges
          (transaction_id, workspace_id, from_account_id, from_amount, from_currency,
           to_account_id, to_amount, to_currency, rate)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        """,
        [
          id,
          scope.workspace_id,
          exchange.from.id,
          exchange.from_amount,
          exchange.from.currency,
          exchange.to.id,
          exchange.to_amount,
          exchange.to.currency,
          exchange.rate
        ]
      )
    end

    insert_tags(scope, id, attrs[:tag_ids] || [])

    {:ok, transaction} = get(scope, id)
    transaction
  end

  defp insert_tags(_scope, _id, []), do: :ok

  defp insert_tags(scope, id, tag_ids) do
    DB.query!(
      "INSERT INTO transaction_tags (workspace_id, transaction_id, tag_id) SELECT $1, $2, unnest($3::uuid[])",
      [scope.workspace_id, id, tag_ids]
    )
  end

  @doc """
  Reverses a posted transaction: posts a `reversal` transaction with every
  entry (including its category) negated, dated like the original unless
  occurred_on is given.

  Reversing an already reversed transaction returns the existing reversal,
  so a retried request is harmless. Reversals themselves cannot be reversed
  (post the operation again instead).
  """
  def reverse(%Scope{} = scope, id, params \\ %{}) do
    with id when is_binary(id) <- Params.cast_id(id),
         {:ok, occurred_on} <- Params.date(params, "occurred_on", nil),
         {:ok, description} <- Params.string(params, "description", max: 500) do
      DB.transaction(fn ->
        original =
          DB.one(
            "SELECT id, type, occurred_on FROM transactions WHERE id = $1 AND workspace_id = $2 FOR UPDATE",
            [id, scope.workspace_id]
          )

        existing = original && DB.one("SELECT id FROM transactions WHERE reverses_id = $1", [id])

        cond do
          is_nil(original) ->
            DB.rollback(:not_found)

          original.type == "reversal" ->
            DB.rollback({:invalid, %{"id" => "a reversal cannot be reversed"}})

          existing ->
            {:ok, reversal} = get(scope, existing.id)
            reversal

          true ->
            entries =
              DB.all(
                """
                SELECT account_id, currency, account_kind, -amount AS amount, category_id
                FROM ledger_entries WHERE transaction_id = $1 ORDER BY id
                """,
                [id]
              )

            insert(scope, %{
              type: "reversal",
              occurred_on: occurred_on || original.occurred_on,
              description: description,
              reverses_id: id,
              entries: entries
            })
        end
      end)
    else
      {:error, _} = error -> error
      nil -> {:error, :not_found}
    end
  end

  @ledger_fields ~w(type account_id from_account_id to_account_id amount from_amount to_amount
                    lines category_id occurred_on)

  @doc """
  Edits a posted transaction. Only the description can change, and the
  database records every change in transaction_changes. Amounts, accounts,
  categories and dates are changed by reversing and posting again.
  """
  def update(%Scope{} = scope, id, params) do
    with {:ok, transaction} <- get(scope, id),
         :ok <- reject_ledger_fields(params),
         {:ok, description} <- new_description(params) do
      if description == transaction.description do
        {:ok, transaction}
      else
        DB.transaction(fn ->
          DB.query!("SELECT set_config('networth.user_id', $1, true)", [scope.user_id])

          DB.query!(
            "UPDATE transactions SET description = $3 WHERE id = $1 AND workspace_id = $2",
            [
              transaction.id,
              scope.workspace_id,
              description
            ]
          )

          {:ok, transaction} = get(scope, transaction.id)
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

  @doc "Edit history of a transaction, oldest first."
  def changes(%Scope{} = scope, id) do
    with {:ok, transaction} <- get(scope, id) do
      {:ok,
       DB.all(
         """
         SELECT c.id, c.field, c.old_value, c.new_value, c.changed_by, u.name AS changed_by_name, c.inserted_at
         FROM transaction_changes c JOIN users u ON u.id = c.changed_by
         WHERE c.transaction_id = $1 AND c.workspace_id = $2
         ORDER BY c.id
         """,
         [transaction.id, scope.workspace_id]
       )}
    end
  end

  @doc "Replaces the tags of a transaction. Tags are not part of the ledger."
  def set_tags(%Scope{} = scope, id, params) do
    with {:ok, transaction} <- get(scope, id),
         {:ok, tag_ids} <- Params.ids(params, "tag_ids"),
         :ok <- Tags.validate_ids(scope, tag_ids) do
      DB.transaction(fn ->
        DB.query!("DELETE FROM transaction_tags WHERE transaction_id = $1", [transaction.id])
        insert_tags(scope, transaction.id, tag_ids)
        {:ok, transaction} = get(scope, transaction.id)
        transaction
      end)
    end
  end

  @select """
  SELECT t.id, t.workspace_id, t.type, t.occurred_on, t.description, t.reverses_id,
    (SELECT r.id FROM transactions r WHERE r.reverses_id = t.id) AS reversed_by_id,
    t.idempotency_key, t.created_by, t.inserted_at
  FROM transactions t
  """

  def get(%Scope{} = scope, id) do
    with id when is_binary(id) <- Params.cast_id(id),
         %{} = transaction <-
           DB.one(@select <> " WHERE t.id = $1 AND t.workspace_id = $2", [id, scope.workspace_id]) do
      {:ok, transaction |> List.wrap() |> preload() |> hd()}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Lists transactions, newest first (by occurred_on, then id). Filters:
  account_id, category_id (any line in it or its subcategories), tag_id,
  type, from, to. Paginated by `limit` and `cursor`: pass the returned
  `next_cursor` to get the next page; it is nil on the last page.
  """
  def list(%Scope{} = scope, params \\ %{}) do
    with {:ok, account_id} <- Params.id(params, "account_id"),
         {:ok, category_id} <- Params.id(params, "category_id"),
         {:ok, tag_id} <- Params.id(params, "tag_id"),
         {:ok, type} <-
           Params.one_of(params, "type", @postable_types ++ ~w(opening_balance reversal)),
         {:ok, from} <- Params.date(params, "from", nil),
         {:ok, to} <- Params.date(params, "to", nil),
         {:ok, limit} <- Params.integer(params, "limit", 50, 1, 200),
         {:ok, cursor} <- decode_cursor(params["cursor"]) do
      {conditions, args} =
        {["t.workspace_id = $1"], [scope.workspace_id]}
        |> where(
          account_id,
          &"EXISTS (SELECT 1 FROM ledger_entries e WHERE e.transaction_id = t.id AND e.account_id = #{&1})"
        )
        |> where(
          category_id,
          &"""
          EXISTS (SELECT 1 FROM ledger_entries e WHERE e.transaction_id = t.id
            AND e.category_id IN (SELECT id FROM categories WHERE id = #{&1} OR parent_id = #{&1}))
          """
        )
        |> where(
          tag_id,
          &"EXISTS (SELECT 1 FROM transaction_tags tt WHERE tt.transaction_id = t.id AND tt.tag_id = #{&1})"
        )
        |> where(type, &"t.type = #{&1}")
        |> where(from, &"t.occurred_on >= #{&1}")
        |> where(to, &"t.occurred_on <= #{&1}")
        |> where(cursor, fn [date, id] -> "(t.occurred_on, t.id) < (#{date}, #{id})" end)

      sql =
        @select <>
          " WHERE #{Enum.join(conditions, " AND ")}" <>
          " ORDER BY t.occurred_on DESC, t.id DESC LIMIT $#{length(args) + 1}"

      # One extra row tells whether there is a next page.
      {page, rest} = sql |> DB.all(args ++ [limit + 1]) |> Enum.split(limit)
      next_cursor = if rest != [], do: encode_cursor(List.last(page))

      {:ok, %{transactions: preload(page), next_cursor: next_cursor}}
    end
  end

  defp encode_cursor(t), do: Base.url_encode64("#{t.occurred_on}/#{t.id}", padding: false)

  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(cursor) do
    with true <- is_binary(cursor),
         {:ok, raw} <- Base.url_decode64(cursor, padding: false),
         [date, id] <- String.split(raw, "/"),
         {:ok, date} <- Date.from_iso8601(date),
         id when is_binary(id) <- Params.cast_id(id) do
      {:ok, {date, id}}
    else
      _ -> Params.invalid("cursor", "is invalid")
    end
  end

  defp where(acc, nil, _condition), do: acc

  defp where({conditions, args}, values, condition) when is_tuple(values) do
    values = Tuple.to_list(values)
    placeholders = Enum.map(1..length(values), &"$#{length(args) + &1}")
    {conditions ++ [condition.(placeholders)], args ++ values}
  end

  defp where({conditions, args}, value, condition) do
    {conditions ++ [condition.("$#{length(args) + 1}")], args ++ [value]}
  end

  defp preload([]), do: []

  defp preload(transactions) do
    ids = Enum.map(transactions, & &1.id)

    entries =
      DB.all(
        """
        SELECT e.transaction_id, e.account_id, a.name AS account_name, a.type AS account_type,
          e.currency, e.amount, e.category_id
        FROM ledger_entries e JOIN accounts a ON a.id = e.account_id
        WHERE e.transaction_id = ANY($1) ORDER BY e.id
        """,
        [ids]
      )
      |> Enum.group_by(& &1.transaction_id, &Map.delete(&1, :transaction_id))

    tags =
      DB.all(
        "SELECT transaction_id, tag_id FROM transaction_tags WHERE transaction_id = ANY($1) ORDER BY tag_id",
        [ids]
      )
      |> Enum.group_by(& &1.transaction_id, & &1.tag_id)

    exchanges =
      DB.all("SELECT * FROM exchanges WHERE transaction_id = ANY($1)", [ids])
      |> Map.new(&{&1.transaction_id, Map.drop(&1, [:transaction_id, :workspace_id])})

    Enum.map(transactions, fn t ->
      Map.merge(t, %{
        entries: Map.get(entries, t.id, []),
        tag_ids: Map.get(tags, t.id, []),
        exchange: Map.get(exchanges, t.id)
      })
    end)
  end
end
