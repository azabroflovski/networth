defmodule Networth.Ledger.History do
  @moduledoc "Reading transactions: one by id, a filtered page, and the snapshot for the activity log."

  alias Networth.{DB, Money, Params, Scope}
  alias Networth.Ledger.Posting

  @select """
  SELECT t.id, t.workspace_id, t.type, t.occurred_on, t.description, t.reverses_id, t.replaces_id,
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

  @not_reversed "t.type <> 'reversal' AND NOT EXISTS (SELECT 1 FROM transactions r WHERE r.reverses_id = t.id)"

  def list(%Scope{} = scope, params \\ %{}) do
    with {:ok, f} <-
           Params.all(
             account_id: Params.id(params, "account_id"),
             category_id: Params.id(params, "category_id"),
             tag_id: Params.id(params, "tag_id"),
             type:
               Params.one_of(
                 params,
                 "type",
                 Posting.postable_types() ++ ~w(opening_balance adjustment reversal)
               ),
             from: Params.date(params, "from", nil),
             to: Params.date(params, "to", nil),
             limit: Params.integer(params, "limit", 50, 1, 200),
             cursor: decode_cursor(params["cursor"])
           ) do
      include_reversed = params["include_reversed"] in [true, "true"]

      {conditions, args} =
        {["t.workspace_id = $1" | if(include_reversed, do: [], else: [@not_reversed])],
         [scope.workspace_id]}
        |> DB.where(
          f.account_id,
          &"EXISTS (SELECT 1 FROM ledger_entries e WHERE e.transaction_id = t.id AND e.account_id = #{&1})"
        )
        |> DB.where(
          f.category_id,
          &"""
          EXISTS (SELECT 1 FROM ledger_entries e WHERE e.transaction_id = t.id
            AND e.category_id IN (SELECT id FROM categories WHERE id = #{&1} OR parent_id = #{&1}))
          """
        )
        |> DB.where(
          f.tag_id,
          &"EXISTS (SELECT 1 FROM transaction_tags tt WHERE tt.transaction_id = t.id AND tt.tag_id = #{&1})"
        )
        |> DB.where(f.type, &"t.type = #{&1}")
        |> DB.where(f.from, &"t.occurred_on >= #{&1}")
        |> DB.where(f.to, &"t.occurred_on <= #{&1}")
        |> DB.where(f.cursor, fn [date, id] -> "(t.occurred_on, t.id) < (#{date}, #{id})" end)

      sql =
        @select <>
          " WHERE #{Enum.join(conditions, " AND ")}" <>
          " ORDER BY t.occurred_on DESC, t.id DESC LIMIT $#{length(args) + 1}"

      # One extra row tells whether there is a next page.
      {page, rest} = sql |> DB.all(args ++ [f.limit + 1]) |> Enum.split(f.limit)
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
      _ -> Params.invalid("cursor", :invalid_cursor)
    end
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

  @system_account_types ~w(income expense opening_balance exchange adjustment)

  @doc """
  What the activity log keeps about an operation: amounts on the user's
  accounts, not the system counterparts.
  """
  def summary(transaction) do
    %{
      "type" => transaction.type,
      "occurred_on" => Date.to_iso8601(transaction.occurred_on),
      "description" => transaction.description,
      "amounts" =>
        for e <- transaction.entries, e.account_type not in @system_account_types do
          %{
            "account_id" => e.account_id,
            "account_name" => e.account_name,
            "currency" => e.currency,
            "amount" => Money.format(e.amount, e.currency)
          }
        end
    }
  end
end
