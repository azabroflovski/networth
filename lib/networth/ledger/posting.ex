defmodule Networth.Ledger.Posting do
  @moduledoc """
  Posting operations: validating params, building balanced entries and
  writing a transaction with its entries, exchange details and tags.
  Also the idempotency of posting (key, request hash, client ids).
  """

  alias Networth.{Accounts, Activity, Categories, DB, Money, Params, Scope, Tags, Workspaces}
  alias Networth.Ledger.History

  @postable_types ~w(expense income transfer exchange)
  @max_lines 50
  @max_minor 9_223_372_036_854_775_807

  @doc "Operation types a client can post (and correct)."
  def postable_types, do: @postable_types

  def post(%Scope{} = scope, params) do
    with {:ok, %{type: type, attrs: attrs}} <-
           Params.all(
             type: Params.one_of(params, "type", @postable_types, required: true),
             attrs: common_attrs(scope, params)
           ) do
      DB.transaction(fn ->
        transaction = post_new(scope, type, attrs, params)

        Activity.record(scope, "transaction.posted", "transaction", transaction.id,
          data: History.summary(transaction)
        )

        transaction
      end)
      |> replay_on_conflict(scope, attrs)
    end
  end

  @doc "Builds, validates and inserts a new operation; must run in a transaction."
  def post_new(scope, type, attrs, params) do
    with {:ok, posting} <- build(type, scope, params),
         :ok <- Tags.validate_ids(scope, attrs.tag_ids) do
      insert(scope, attrs |> Map.merge(posting) |> Map.put(:type, type))
    else
      {:error, reason} -> DB.rollback(reason)
    end
  end

  @doc """
  Turns a duplicate-key conflict into a replay of the original transaction.

  ON CONFLICT only covers the key's index. A concurrent retry with the same
  client id can collide on the primary key first, so id_taken is a retry if
  the key exists.
  """
  def replay_on_conflict(result, scope, attrs) do
    case result do
      {:error, :duplicate} -> replay(scope, attrs, result)
      {:error, :id_taken} when attrs.idempotency_key != nil -> replay(scope, attrs, result)
      other -> other
    end
  end

  @doc "Validated params shared by all operation types."
  def common_attrs(scope, params) do
    with {:ok, attrs} <-
           Params.all(
             occurred_on: Params.date(params, "occurred_on", fn -> Workspaces.today(scope) end),
             description: Params.string(params, "description", max: 500),
             tag_ids: Params.ids(params, "tag_ids"),
             id: client_id(params),
             idempotency_key: Params.string(params, "idempotency_key")
           ) do
      {:ok,
       Map.put(attrs, :idempotency_hash, attrs.idempotency_key && Params.request_hash(params))}
    end
  end

  # A client may generate the id itself (offline input, AI drafts). It must be
  # a UUIDv7 so that inserts stay ordered in the primary key index.
  defp client_id(params) do
    case Params.id(params, "id") do
      {:ok, <<_::binary-14, ?7, _::binary>> = id} -> {:ok, id}
      {:ok, nil} -> {:ok, nil}
      _ -> Params.invalid("id", :invalid_uuid_v7)
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
      existing.idempotency_hash == attrs.idempotency_hash -> History.get(scope, existing.id)
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
    with {:ok, %{from: from, to: to}} <- accounts(scope, params),
         :ok <- distinct_accounts(from, to),
         :ok <- same_currency(from, to),
         {:ok, amount} <-
           Params.amount(params, "amount", from.currency, required: true, positive: true) do
      {:ok, %{entries: [entry(to, amount), entry(from, -amount)]}}
    end
  end

  defp build("exchange", scope, params) do
    with {:ok, %{from: from, to: to}} <- accounts(scope, params),
         :ok <-
           if(from.currency == to.currency,
             do: Params.invalid("to_account_id", :same_currency),
             else: :ok
           ),
         {:ok, %{from_amount: from_amount, to_amount: to_amount, fee: fee}} <-
           Params.all(
             from_amount:
               Params.amount(params, "from_amount", from.currency, required: true, positive: true),
             to_amount:
               Params.amount(params, "to_amount", to.currency, required: true, positive: true),
             fee: exchange_fee(scope, params, from.currency)
           ) do
      from_exchange = Accounts.system_account(scope.workspace_id, "exchange", from.currency)
      to_exchange = Accounts.system_account(scope.workspace_id, "exchange", to.currency)

      rate =
        Money.rate(
          from_amount,
          Networth.Currencies.exponent!(from.currency),
          to_amount,
          Networth.Currencies.exponent!(to.currency)
        )

      fee_entries =
        if fee do
          expense = Accounts.system_account(scope.workspace_id, "expense", from.currency)
          [entry(expense, fee.amount, fee.category_id), entry(from, -fee.amount)]
        else
          []
        end

      {:ok,
       %{
         entries:
           [
             entry(from_exchange, from_amount),
             entry(from, -from_amount),
             entry(to, to_amount),
             entry(to_exchange, -to_amount)
           ] ++ fee_entries,
         exchange: %{
           from: from,
           from_amount: from_amount,
           to: to,
           to_amount: to_amount,
           rate: rate,
           fee_amount: if(fee, do: fee.amount, else: 0)
         }
       }}
    end
  end

  # The fee is taken from the source account in its currency, on top of
  # from_amount, and booked as an expense line (optionally categorized).
  defp exchange_fee(scope, params, currency) do
    with {:ok, amount} <- Params.amount(params, "fee", currency) do
      cond do
        amount in [nil, 0] and Map.get(params, "fee_category_id") != nil ->
          Params.invalid("fee_category_id", :requires_fee)

        amount in [nil, 0] ->
          {:ok, nil}

        amount < 0 ->
          Params.invalid("fee", :negative)

        true ->
          case category(scope, %{"category_id" => params["fee_category_id"]}, "expense") do
            {:ok, category_id} ->
              {:ok, %{amount: amount, category_id: category_id}}

            {:error, {:invalid, %{"category_id" => error}}} ->
              {:error, {:invalid, %{"fee_category_id" => error}}}
          end
      end
    end
  end

  @doc "One ledger entry on `account`; positive amount = debit."
  def entry(account, amount, category_id \\ nil) do
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
            Params.invalid("lines", :conflicting_fields, %{fields: ["amount", "category_id"]})

          not Enum.all?(lines, &is_map/1) ->
            Params.invalid("lines", :not_list)

          true ->
            checks =
              lines
              |> Enum.with_index()
              |> Enum.map(fn {line, i} ->
                {i, line(scope, line, kind, currency, "lines.#{i}.")}
              end)

            with {:ok, by_index} <- Params.all(checks) do
              by_index |> Enum.sort() |> Enum.map(&elem(&1, 1)) |> within_range()
            end
        end

      _ ->
        Params.invalid("lines", :invalid_count, %{min: 1, max: @max_lines})
    end
  end

  defp line(scope, params, kind, currency, prefix) do
    Params.all(
      amount: Params.amount(params, "amount", currency, required: true, positive: true),
      category_id: category(scope, params, kind)
    )
    |> prefix_error(prefix)
  end

  defp within_range(lines) do
    if lines |> Enum.map(& &1.amount) |> Enum.sum() <= @max_minor,
      do: {:ok, lines},
      else: Params.invalid("lines", :too_large)
  end

  defp prefix_error({:error, {:invalid, errors}}, prefix) when prefix != "" do
    {:error, {:invalid, Map.new(errors, fn {k, v} -> {prefix <> k, v} end)}}
  end

  defp prefix_error(result, _prefix), do: result

  defp accounts(scope, params) do
    Params.all(
      from: account(scope, params, "from_account_id"),
      to: account(scope, params, "to_account_id")
    )
  end

  defp account(scope, params, field) do
    with {:ok, id} <- Params.id(params, field, required: true) do
      Accounts.fetch_for_posting(scope, field, id)
    end
  end

  defp distinct_accounts(from, to) do
    if from.id == to.id,
      do: Params.invalid("to_account_id", :same_account),
      else: :ok
  end

  defp same_currency(from, to) do
    if from.currency == to.currency,
      do: :ok,
      else: Params.invalid("to_account_id", :currency_mismatch)
  end

  defp category(scope, params, kind) do
    with {:ok, id} when not is_nil(id) <- Params.id(params, "category_id") do
      case Categories.get(scope, id) do
        {:ok, %{kind: ^kind, archived_at: nil}} -> {:ok, id}
        {:ok, %{kind: ^kind}} -> Params.invalid("category_id", :archived)
        {:ok, _} -> Params.invalid("category_id", :wrong_kind, %{expected: kind})
        {:error, :not_found} -> Params.invalid("category_id", :not_found)
      end
    end
  end

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

  @doc """
  Writes a transaction, its entries, exchange details and tags; returns the
  loaded transaction. Must run in a transaction: a duplicate key or a taken
  client id rolls it back with `:duplicate` / `:id_taken`.
  """
  def insert(scope, attrs) do
    result =
      DB.query(
        """
        INSERT INTO transactions
          (id, workspace_id, type, occurred_on, description, reverses_id, replaces_id,
           idempotency_key, idempotency_hash, created_by)
        VALUES (coalesce($1, uuidv7()), $2, $3, $4, $5, $6, $7, $8, $9, $10)
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
          attrs[:replaces_id],
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
           to_account_id, to_amount, to_currency, rate, fee_amount)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
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
          exchange.rate,
          exchange.fee_amount
        ]
      )
    end

    insert_tags(scope, id, attrs[:tag_ids] || [])

    {:ok, transaction} = History.get(scope, id)
    transaction
  end

  def insert_tags(_scope, _id, []), do: :ok

  def insert_tags(scope, id, tag_ids) do
    DB.query!(
      "INSERT INTO transaction_tags (workspace_id, transaction_id, tag_id) SELECT $1, $2, unnest($3::uuid[])",
      [scope.workspace_id, id, tag_ids]
    )
  end
end
