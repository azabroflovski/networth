defmodule Networth.DataCase do
  @moduledoc """
  Tests that run against the real test database. Tables are truncated before
  each test, so these cases must not run concurrently with each other.
  """

  use ExUnit.CaseTemplate

  alias Networth.{Accounts, DB, Ledger, Users, Workspaces}

  using do
    quote do
      import Networth.DataCase
      alias Networth.{Accounts, Categories, DB, Ledger, Scope, Tags, Users, Workspaces}
    end
  end

  setup do
    reset_database()
    :ok
  end

  @doc """
  Empties every table except reference data. The list comes from the
  database, so a new table is cleaned without touching this code.
  """
  def reset_database do
    %{tables: tables} =
      DB.one("""
      SELECT string_agg(quote_ident(tablename), ', ') AS tables FROM pg_tables
      WHERE schemaname = 'public' AND tablename NOT IN ('currencies', 'schema_migrations')
      """)

    DB.query!("TRUNCATE #{tables} RESTART IDENTITY CASCADE")
    Networth.RateLimit.reset_all()
  end

  @doc "Registers a user and returns the user, their personal workspace and its scope."
  def register!(email \\ "user#{System.unique_integer([:positive])}@example.com") do
    {:ok, %{user: user, workspace: workspace}} =
      Users.register(%{"email" => email, "name" => "Test User", "password" => "correct horse"})

    {:ok, scope} = Workspaces.authorize(user.id, workspace.id)
    %{user: user, workspace: workspace, scope: scope}
  end

  @doc "A user with cash UZS (1 000 000), an empty UZS card and cash USD (500)."
  def ledger_setup(_context) do
    ctx = register!()

    cash =
      account!(ctx.scope, %{
        "name" => "Cash UZS",
        "currency" => "UZS",
        "opening_balance" => "1000000"
      })

    card = account!(ctx.scope, %{"name" => "Card UZS", "type" => "card", "currency" => "UZS"})

    usd =
      account!(ctx.scope, %{"name" => "Cash USD", "currency" => "USD", "opening_balance" => "500"})

    Map.merge(ctx, %{cash: cash, card: card, usd: usd})
  end

  @doc "A well-formed UUID that no row has."
  def missing_id, do: "00000000-0000-7000-8000-000000000000"

  def account!(scope, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          "name" => "Account #{System.unique_integer([:positive])}",
          "type" => "cash",
          "currency" => "USD"
        },
        attrs
      )

    {:ok, account} = Accounts.create(scope, attrs)
    account
  end

  def post!(scope, attrs) do
    {:ok, transaction} = Ledger.post(scope, attrs)
    transaction
  end

  def balance(scope, account_id) do
    {:ok, account} = Accounts.get(scope, account_id)
    account.balance
  end

  def category_id(scope, name) do
    Enum.find(Networth.Categories.list(scope), &(&1.name == name)).id
  end

  @doc "Sum of all entries per currency in the workspace; must always be zero."
  def ledger_totals(scope) do
    DB.all(
      "SELECT currency, sum(amount)::bigint AS total FROM ledger_entries WHERE workspace_id = $1 GROUP BY currency ORDER BY currency",
      [scope.workspace_id]
    )
  end
end
