defmodule Networth.Budgets do
  @moduledoc """
  Monthly spending limits per expense category and currency.

  A limit applies from its month until a limit for the same category and
  currency set for a later month; amount 0 ends it. Spending comes from
  `Reports.income_expense/2`, so subcategories, splits, reversals and fees
  count exactly as in reports. A budget on a top-level category covers its
  subcategories.
  """

  alias Networth.{Activity, Categories, DB, Params, Reports, Scope, Workspaces}

  @doc "All limits with their history, newest month first."
  def list(%Scope{} = scope) do
    DB.all(
      "SELECT * FROM budgets WHERE workspace_id = $1 ORDER BY category_id, currency, starts_on DESC",
      [scope.workspace_id]
    )
  end

  @doc """
  Sets the limit for a category and currency from `month` ("YYYY-MM",
  default: the current month in the workspace timezone) onwards.
  """
  def set(%Scope{} = scope, params) do
    with {:ok, %{category_id: category_id, currency: currency, month: month}} <-
           Params.all(
             category_id: Params.id(params, "category_id", required: true),
             currency: Params.currency(params, "currency"),
             month: month(scope, params)
           ),
         {:ok, %{amount: amount}} <-
           Params.all(
             category: expense_category(scope, category_id),
             amount: non_negative_amount(params, currency)
           ) do
      DB.transaction(fn ->
        previous = effective_limit(scope, category_id, currency, month)

        budget =
          DB.one(
            """
            INSERT INTO budgets (workspace_id, category_id, currency, starts_on, amount, updated_by)
            VALUES ($1, $2, $3, $4, $5, $6)
            ON CONFLICT (workspace_id, category_id, currency, starts_on)
            DO UPDATE SET amount = EXCLUDED.amount, updated_by = EXCLUDED.updated_by, updated_at = now()
            RETURNING *
            """,
            [scope.workspace_id, category_id, currency, month, amount, scope.user_id]
          )

        {:ok, category} = Categories.get(scope, category_id)
        format = &(&1 && Activity.money(&1, currency))

        Activity.record(scope, "budget.set", "category", category_id,
          changes: %{"limit" => [format.(previous), format.(amount)]},
          data: %{
            "category_name" => category.name,
            "currency" => currency,
            "month" => Calendar.strftime(month, "%Y-%m")
          }
        )

        budget
      end)
    end
  end

  # The limit in effect for the month before this change, or nil.
  defp effective_limit(scope, category_id, currency, month) do
    case DB.one(
           """
           SELECT amount FROM budgets
           WHERE workspace_id = $1 AND category_id = $2 AND currency = $3 AND starts_on <= $4
           ORDER BY starts_on DESC LIMIT 1
           """,
           [scope.workspace_id, category_id, currency, month]
         ) do
      %{amount: 0} -> nil
      %{amount: amount} -> amount
      nil -> nil
    end
  end

  defp non_negative_amount(params, currency) do
    with {:ok, amount} <- Params.amount(params, "amount", currency, required: true) do
      if amount < 0, do: Params.invalid("amount", :negative), else: {:ok, amount}
    end
  end

  defp expense_category(scope, id) do
    case Categories.get(scope, id) do
      {:ok, %{kind: "expense", archived_at: nil} = category} -> {:ok, category}
      {:ok, %{kind: "expense"}} -> Params.invalid("category_id", :archived)
      {:ok, _} -> Params.invalid("category_id", :wrong_kind, %{expected: "expense"})
      {:error, :not_found} -> Params.invalid("category_id", :not_found)
    end
  end

  @doc """
  Limits in effect for `month` with spending: limit, spent, remaining
  (negative when over budget) and percent spent (rounded down).
  """
  def report(%Scope{} = scope, params) do
    with {:ok, month} <- month(scope, params) do
      last_day = Date.end_of_month(month)

      limits =
        DB.all(
          """
          SELECT * FROM (
            SELECT DISTINCT ON (category_id, currency) category_id, currency, amount
            FROM budgets WHERE workspace_id = $1 AND starts_on <= $2
            ORDER BY category_id, currency, starts_on DESC
          ) b WHERE amount > 0
          """,
          [scope.workspace_id, month]
        )

      {:ok, %{currencies: currencies}} =
        Reports.income_expense(scope, %{
          "from" => Date.to_iso8601(month),
          "to" => Date.to_iso8601(last_day)
        })

      spent =
        for %{currency: currency, expense: %{categories: tops}} <- currencies,
            top <- tops,
            category <- [top | top.subcategories],
            into: %{},
            do: {{currency, category.category_id}, category.total}

      names = scope |> Categories.list() |> Map.new(&{&1.id, &1.name})

      budgets =
        limits
        |> Enum.map(fn %{category_id: id, currency: currency, amount: limit} ->
          spent = Map.get(spent, {currency, id}, 0)

          %{
            category_id: id,
            name: names[id],
            currency: currency,
            limit: limit,
            spent: spent,
            remaining: limit - spent,
            percent: div(spent * 100, limit)
          }
        end)
        |> Enum.sort_by(&{&1.name, &1.currency})

      {:ok, %{month: month, budgets: budgets}}
    end
  end

  defp month(scope, params) do
    case Map.get(params, "month") do
      nil ->
        {:ok, scope |> Workspaces.today() |> Date.beginning_of_month()}

      value when is_binary(value) ->
        case Date.from_iso8601(value <> "-01") do
          {:ok, date} when byte_size(value) == 7 -> {:ok, date}
          _ -> Params.invalid("month", :invalid_month)
        end

      _ ->
        Params.invalid("month", :invalid_month)
    end
  end
end
