defmodule Networth.Web.JSON do
  @moduledoc """
  Shapes domain data for API responses. Money amounts are rendered as
  decimal strings in major units together with their currency.
  """

  alias Networth.{Currencies, Money}

  def user(u), do: Map.take(u, [:id, :email, :name, :inserted_at])

  def workspace(w), do: Map.take(w, [:id, :name, :timezone, :role, :inserted_at])

  def member(m), do: Map.take(m, [:user_id, :email, :name, :role, :inserted_at])

  def invitation(i), do: Map.take(i, [:id, :workspace_id, :workspace_name, :email, :inserted_at])

  def currency(c), do: Map.take(c, [:code, :exponent, :name])

  def account(a) do
    a
    |> Map.take([:id, :name, :type, :kind, :currency, :archived_at, :inserted_at])
    |> Map.put(:balance, money(a.balance, a.currency))
  end

  def category(c),
    do: Map.take(c, [:id, :parent_id, :kind, :name, :system, :archived_at, :inserted_at])

  def tag(t), do: Map.take(t, [:id, :name, :color, :inserted_at])

  def transaction(t) do
    t
    |> Map.take([
      :id,
      :type,
      :occurred_on,
      :description,
      :tag_ids,
      :reverses_id,
      :reversed_by_id,
      :idempotency_key,
      :created_by,
      :inserted_at
    ])
    |> Map.put(:entries, Enum.map(t.entries, &entry/1))
    |> Map.put(:exchange, t.exchange && exchange(t.exchange))
  end

  def transaction_change(c) do
    Map.take(c, [:id, :field, :old_value, :new_value, :changed_by, :changed_by_name, :inserted_at])
  end

  defp entry(e) do
    e
    |> Map.take([:account_id, :account_name, :account_type, :currency, :category_id])
    |> Map.put(:amount, money(e.amount, e.currency))
  end

  defp exchange(x) do
    %{
      from_account_id: x.from_account_id,
      from_amount: money(x.from_amount, x.from_currency),
      from_currency: x.from_currency,
      to_account_id: x.to_account_id,
      to_amount: money(x.to_amount, x.to_currency),
      to_currency: x.to_currency,
      rate: Decimal.to_string(x.rate, :normal)
    }
  end

  def income_expense(report) do
    %{
      from: report.from,
      to: report.to,
      currencies:
        Enum.map(report.currencies, fn c ->
          %{
            currency: c.currency,
            income: breakdown(c.income, c.currency),
            expense: breakdown(c.expense, c.currency),
            net: money(c.net, c.currency)
          }
        end)
    }
  end

  defp breakdown(b, currency) do
    %{
      total: money(b.total, currency),
      categories:
        Enum.map(b.categories, fn c ->
          %{
            category_id: c.category_id,
            name: c.name,
            total: money(c.total, currency),
            subcategories: Enum.map(c.subcategories, &%{&1 | total: money(&1.total, currency)})
          }
        end)
    }
  end

  def balances(report), do: %{on: report.on, accounts: Enum.map(report.accounts, &account/1)}

  def account_activity(r) do
    currency = r.account.currency

    %{
      account: account(r.account),
      from: r.from,
      to: r.to,
      opening_balance: money(r.opening_balance, currency),
      inflow: money(r.inflow, currency),
      outflow: money(r.outflow, currency),
      closing_balance: money(r.closing_balance, currency)
    }
  end

  defp money(amount, currency), do: Money.format(amount, Currencies.exponent!(currency))
end
