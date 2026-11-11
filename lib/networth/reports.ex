defmodule Networth.Reports do
  @moduledoc """
  Read-only reports computed from ledger entries.

  Amounts are minor units per currency and are never converted. Periods are
  inclusive ranges of `occurred_on` dates. Reversals need no special handling:
  they negate the original entries (with their categories) and simply net out.
  """

  alias Networth.{Accounts, Categories, DB, Params, Scope, Workspaces}

  @doc """
  Income and expenses for a period, per currency: totals, net and a breakdown
  by top-level category with subcategories. Lines without a category are
  reported under `category_id: nil`.
  """
  def income_expense(%Scope{} = scope, params) do
    with {:ok, from, to} <- period(params) do
      rows =
        DB.all(
          """
          SELECT e.currency, e.account_kind AS kind, e.category_id, sum(e.amount)::bigint AS amount
          FROM ledger_entries e JOIN transactions t ON t.id = e.transaction_id
          WHERE e.workspace_id = $1 AND e.account_kind IN ('income', 'expense')
            AND t.occurred_on BETWEEN $2 AND $3
          GROUP BY e.currency, e.account_kind, e.category_id
          """,
          [scope.workspace_id, from, to]
        )

      categories = scope |> Categories.list() |> Map.new(&{&1.id, &1})

      currencies =
        rows
        |> Enum.group_by(& &1.currency)
        |> Enum.map(fn {currency, rows} ->
          income = breakdown(rows, "income", categories)
          expense = breakdown(rows, "expense", categories)

          %{
            currency: currency,
            income: income,
            expense: expense,
            net: income.total - expense.total
          }
        end)
        |> Enum.reject(&(&1.income.total == 0 and &1.expense.total == 0 and &1.net == 0))
        |> Enum.sort_by(& &1.currency)

      {:ok, %{from: from, to: to, currencies: currencies}}
    end
  end

  # Income entries are credits, so their natural (positive) amount is -amount.
  defp breakdown(rows, kind, categories) do
    sign = if kind == "expense", do: 1, else: -1

    lines =
      for %{kind: ^kind} = row <- rows, row.amount != 0 do
        category = categories[row.category_id]
        top_id = category && (category.parent_id || category.id)
        %{top_id: top_id, category: category, total: sign * row.amount}
      end

    tops =
      lines
      |> Enum.group_by(& &1.top_id)
      |> Enum.map(fn {top_id, lines} ->
        subcategories =
          for %{category: %{parent_id: parent} = c, total: total} <- lines,
              parent != nil,
              do: %{category_id: c.id, name: c.name, total: total}

        %{
          category_id: top_id,
          name: top_id && categories[top_id].name,
          total: lines |> Enum.map(& &1.total) |> Enum.sum(),
          subcategories: Enum.sort_by(subcategories, & &1.total, :desc)
        }
      end)
      |> Enum.reject(&(&1.total == 0 and &1.subcategories == []))
      |> Enum.sort_by(& &1.total, :desc)

    %{total: tops |> Enum.map(& &1.total) |> Enum.sum(), categories: tops}
  end

  @doc "Balances of all user accounts at the end of the given date (`on`)."
  def balances(%Scope{} = scope, params) do
    with {:ok, on} <- required_date(params, "on") do
      {:ok, %{on: on, accounts: Accounts.list(scope, on: on)}}
    end
  end

  @doc """
  Net worth at the end of `on` (default: today in the workspace timezone),
  per currency: assets, liabilities (as amounts owed) and net = assets −
  liabilities. Archived accounts count; currencies are never combined.
  """
  def net_worth(%Scope{} = scope, params) do
    with {:ok, on} <- Params.date(params, "on", fn -> Workspaces.today(scope) end),
         {:ok, %{accounts: accounts}} <- balances(scope, %{"on" => Date.to_iso8601(on)}) do
      currencies =
        accounts
        |> Enum.group_by(& &1.currency)
        |> Enum.map(fn {currency, accounts} ->
          assets = sum_balances(accounts, "asset")
          liabilities = sum_balances(accounts, "liability")

          %{
            currency: currency,
            assets: assets,
            liabilities: liabilities,
            net: assets - liabilities
          }
        end)
        |> Enum.sort_by(& &1.currency)

      {:ok, %{on: on, currencies: currencies}}
    end
  end

  defp sum_balances(accounts, kind) do
    for(%{kind: ^kind, balance: balance} <- accounts, do: balance) |> Enum.sum()
  end

  @doc """
  Movement on one account over a period, in the account's natural sign:
  balance before the period, money in, money out and balance at the end.
  """
  def account_activity(%Scope{} = scope, account_id, params) do
    with {:ok, account} <- Accounts.get(scope, account_id),
         {:ok, from, to} <- period(params) do
      sign = Accounts.sign(account.kind)

      totals =
        DB.one(
          """
          SELECT
            coalesce(sum(e.amount) FILTER (WHERE t.occurred_on < $2), 0)::bigint AS before,
            coalesce(sum(e.amount * $4) FILTER (WHERE t.occurred_on BETWEEN $2 AND $3 AND e.amount * $4 > 0), 0)::bigint AS inflow,
            coalesce(-sum(e.amount * $4) FILTER (WHERE t.occurred_on BETWEEN $2 AND $3 AND e.amount * $4 < 0), 0)::bigint AS outflow
          FROM ledger_entries e JOIN transactions t ON t.id = e.transaction_id
          WHERE e.account_id = $1 AND t.occurred_on <= $3
          """,
          [account.id, from, to, sign]
        )

      opening = sign * totals.before

      {:ok,
       %{
         account: account,
         from: from,
         to: to,
         opening_balance: opening,
         inflow: totals.inflow,
         outflow: totals.outflow,
         closing_balance: opening + totals.inflow - totals.outflow
       }}
    end
  end

  defp period(params) do
    with {:ok, %{from: from, to: to}} <-
           Params.all(from: required_date(params, "from"), to: required_date(params, "to")) do
      if Date.compare(from, to) == :gt,
        do: Params.invalid("to", :before_from),
        else: {:ok, from, to}
    end
  end

  defp required_date(params, key) do
    case Params.date(params, key, nil) do
      {:ok, nil} -> Params.invalid(key, :required)
      result -> result
    end
  end
end
