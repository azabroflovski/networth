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
    DB.query!("""
    TRUNCATE users, user_tokens, workspaces, workspace_members, workspace_invitations,
      accounts, categories, tags, transactions, ledger_entries, exchanges, transaction_tags,
      activity_log, budgets
    RESTART IDENTITY CASCADE
    """)

    Networth.RateLimit.reset_all()

    :ok
  end

  @doc "Registers a user and returns the user, their personal workspace and its scope."
  def register!(email \\ "user#{System.unique_integer([:positive])}@example.com") do
    {:ok, %{user: user, workspace: workspace}} =
      Users.register(%{"email" => email, "name" => "Test User", "password" => "correct horse"})

    {:ok, scope} = Workspaces.authorize(user.id, workspace.id)
    %{user: user, workspace: workspace, scope: scope}
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
