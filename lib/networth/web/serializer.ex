defmodule Networth.Web.Serializer do
  @moduledoc """
  Shapes domain data for API responses. Money amounts are rendered as
  decimal strings in major units together with their currency.
  """

  alias Networth.Money

  def user(u), do: Map.take(u, [:id, :email, :name, :inserted_at])

  def workspace(w),
    do: Map.take(w, [:id, :name, :timezone, :role, :deletion_scheduled_at, :inserted_at])

  def member(m), do: Map.take(m, [:user_id, :email, :name, :role, :inserted_at])

  def invitation(i), do: Map.take(i, [:id, :workspace_id, :workspace_name, :email, :inserted_at])

  def currency(c), do: Map.take(c, [:code, :exponent, :name])

  def account(a) do
    a
    |> Map.take([:id, :name, :type, :kind, :currency, :archived_at, :inserted_at])
    |> Map.put(:balance, Money.format(a.balance, a.currency))
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
      :replaces_id,
      :idempotency_key,
      :created_by,
      :inserted_at
    ])
    |> Map.put(:entries, Enum.map(t.entries, &entry/1))
    |> Map.put(:exchange, t.exchange && exchange(t.exchange))
  end

  def activity_event(e) do
    e
    |> Map.take([:id, :action, :subject_type, :subject_id, :changes, :data, :inserted_at])
    |> Map.put(:actor, %{id: e.actor_id, name: e.actor_name})
  end

  defp entry(e) do
    e
    |> Map.take([:account_id, :account_name, :account_type, :currency, :category_id])
    |> Map.put(:amount, Money.format(e.amount, e.currency))
  end

  defp exchange(x) do
    %{
      from_account_id: x.from_account_id,
      from_amount: Money.format(x.from_amount, x.from_currency),
      from_currency: x.from_currency,
      to_account_id: x.to_account_id,
      to_amount: Money.format(x.to_amount, x.to_currency),
      to_currency: x.to_currency,
      rate: Decimal.to_string(x.rate, :normal),
      fee_amount: Money.format(x.fee_amount, x.from_currency)
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
            net: Money.format(c.net, c.currency)
          }
        end)
    }
  end

  defp breakdown(b, currency) do
    %{
      total: Money.format(b.total, currency),
      categories:
        Enum.map(b.categories, fn c ->
          %{
            category_id: c.category_id,
            name: c.name,
            total: Money.format(c.total, currency),
            subcategories:
              Enum.map(c.subcategories, &%{&1 | total: Money.format(&1.total, currency)})
          }
        end)
    }
  end

  def budget(b) do
    b
    |> Map.take([:id, :category_id, :currency, :updated_by, :updated_at])
    |> Map.merge(%{
      month: Calendar.strftime(b.starts_on, "%Y-%m"),
      amount: Money.format(b.amount, b.currency)
    })
  end

  def budget_report(report) do
    %{
      month: Calendar.strftime(report.month, "%Y-%m"),
      budgets:
        Enum.map(report.budgets, fn b ->
          %{
            category_id: b.category_id,
            name: b.name,
            currency: b.currency,
            limit: Money.format(b.limit, b.currency),
            spent: Money.format(b.spent, b.currency),
            remaining: Money.format(b.remaining, b.currency),
            percent: b.percent
          }
        end)
    }
  end

  def net_worth(report) do
    %{
      on: report.on,
      currencies:
        Enum.map(report.currencies, fn c ->
          %{
            currency: c.currency,
            assets: Money.format(c.assets, c.currency),
            liabilities: Money.format(c.liabilities, c.currency),
            net: Money.format(c.net, c.currency)
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
      opening_balance: Money.format(r.opening_balance, currency),
      inflow: Money.format(r.inflow, currency),
      outflow: Money.format(r.outflow, currency),
      closing_balance: Money.format(r.closing_balance, currency)
    }
  end

  @doc """
  Validation errors for the client: per field the stable `code`, its
  details and an English `message`. Clients translate by `code`.
  """
  def validation_errors(errors) do
    Map.new(errors, fn {field, %{code: code} = error} ->
      {field, error |> Map.put(:message, message(code, error))}
    end)
  end

  defp message(:required, _), do: "is required"
  defp message(:blank, _), do: "can't be blank"
  defp message(:too_long, %{max: max}), do: "is too long (max #{max})"
  defp message(:not_string, _), do: "must be a string"
  defp message(:not_list, _), do: "must be a list"
  defp message(:not_boolean, _), do: "must be a boolean"

  defp message(:invalid_choice, %{allowed: allowed}),
    do: "must be one of: #{Enum.join(allowed, ", ")}"

  defp message(:invalid_id, _), do: "must be a UUID"
  defp message(:invalid_uuid_v7, _), do: "must be a UUIDv7"
  defp message(:invalid_date, _), do: "must be an ISO 8601 date"
  defp message(:invalid_month, _), do: "must be YYYY-MM"

  defp message(:out_of_range, %{min: min, max: max}),
    do: "must be an integer between #{min} and #{max}"

  defp message(:invalid_amount, _), do: "must be a decimal string, e.g. \"12.50\""

  defp message(:too_many_decimals, %{currency: c, decimals: d}),
    do: "#{c} allows at most #{d} decimal places"

  defp message(:not_positive, _), do: "must be greater than zero"
  defp message(:negative, _), do: "must not be negative"
  defp message(:too_large, _), do: "is too large"
  defp message(:unsupported_currency, _), do: "is not a supported currency"
  defp message(:invalid_email, _), do: "is not a valid email"

  defp message(:invalid_length, %{min: min, max: max}),
    do: "must be #{min} to #{max} characters long"

  defp message(:invalid_timezone, _), do: "is not a known IANA time zone"
  defp message(:invalid_color, _), do: "must be a hex color like #1a2b3c"
  defp message(:invalid_count, %{min: min, max: max}), do: "must contain #{min} to #{max} items"
  defp message(:invalid_cursor, _), do: "is invalid"
  defp message(:not_found, _), do: "does not exist"
  defp message(:archived, _), do: "is archived"
  defp message(:already_exists, _), do: "already exists"
  defp message(:already_invited, _), do: "already has a pending invitation"
  defp message(:already_member, _), do: "is already a member"
  defp message(:wrong_kind, %{expected: kind}), do: "must be an #{kind} category"
  defp message(:not_top_level, _), do: "must be a top-level category"
  defp message(:parent_kind_mismatch, _), do: "must match the parent category"
  defp message(:same_account, _), do: "must differ from from_account_id"
  defp message(:currency_mismatch, _), do: "has a different currency; use an exchange"
  defp message(:same_currency, _), do: "has the same currency; use a transfer"

  defp message(:conflicting_fields, %{fields: fields}),
    do: "cannot be combined with #{Enum.join(fields, ", ")}"

  defp message(:requires_fee, _), do: "requires a fee"
  defp message(:immutable, _), do: "cannot be changed; correct the transaction instead"
  defp message(:not_reversible, _), do: "a reversal cannot be reversed"

  defp message(:not_correctable, _),
    do: "only expense, income, transfer and exchange can be corrected"

  defp message(:before_from, _), do: "must not be before from"
  defp message(:confirmation_mismatch, _), do: "must match the workspace name"
  # A code without its own text still gets a readable message rather than a crash.
  defp message(code, _), do: code |> to_string() |> String.replace("_", " ")
end
