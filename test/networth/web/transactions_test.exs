defmodule Networth.Web.TransactionsTest do
  @moduledoc "Posting, correcting and reading operations over HTTP."
  use Networth.ConnCase

  test "end-to-end: register, create accounts, post operations, read balances" do
    {token, ws} = register("e2e@example.com")

    {201, %{"account" => cash}} =
      request(
        :post,
        "/api/workspaces/#{ws}/accounts",
        %{name: "Cash", type: "cash", currency: "UZS", opening_balance: "1000000"},
        token
      )

    assert cash["balance"] == "1000000.00"

    {200, %{"categories" => categories}} =
      request(:get, "/api/workspaces/#{ws}/categories", nil, token)

    food = Enum.find(categories, &(&1["name"] == "Food"))["id"]

    {201, %{"transaction" => tx}} =
      request(
        :post,
        "/api/workspaces/#{ws}/transactions",
        %{
          type: "expense",
          account_id: cash["id"],
          amount: "200000",
          category_id: food,
          description: "Groceries"
        },
        token
      )

    assert tx["type"] == "expense"
    assert Enum.map(tx["entries"], & &1["amount"]) == ["200000.00", "-200000.00"]

    {200, %{"account" => %{"balance" => "800000.00"}}} =
      request(:get, "/api/workspaces/#{ws}/accounts/#{cash["id"]}", nil, token)

    {201, %{"transaction" => reversal}} =
      request(:post, "/api/workspaces/#{ws}/transactions/#{tx["id"]}/reverse", %{}, token)

    assert reversal["reverses_id"] == tx["id"]

    assert {201, %{"transaction" => ^reversal}} =
             request(:post, "/api/workspaces/#{ws}/transactions/#{tx["id"]}/reverse", %{}, token)

    {200, %{"transactions" => list, "next_cursor" => nil}} =
      request(
        :get,
        "/api/workspaces/#{ws}/transactions?type=expense&include_reversed=true",
        nil,
        token
      )

    assert [%{"id" => id, "reversed_by_id" => rid}] = list
    assert {id, rid} == {tx["id"], reversal["id"]}
  end

  test "correct, delete and adjust over HTTP" do
    {token, ws} = register("ux@example.com")

    {201, %{"account" => cash}} =
      request(
        :post,
        "/api/workspaces/#{ws}/accounts",
        %{name: "C", type: "cash", currency: "USD", opening_balance: "100"},
        token
      )

    txs = "/api/workspaces/#{ws}/transactions"
    expense = %{type: "expense", account_id: cash["id"], amount: "30"}
    {201, %{"transaction" => tx}} = request(:post, txs, expense, token)

    assert {201, %{"transaction" => %{"replaces_id" => replaces, "id" => fixed}}} =
             request(:post, "#{txs}/#{tx["id"]}/correct", %{expense | amount: "20"}, token)

    assert replaces == tx["id"]

    assert {409, %{"error" => "already_reversed"}} =
             request(:post, "#{txs}/#{tx["id"]}/correct", expense, token)

    assert {204, nil} = request(:delete, "#{txs}/#{fixed}", nil, token)
    assert {204, nil} = request(:delete, "#{txs}/#{fixed}", nil, token)

    assert {200, %{"transactions" => [%{"type" => "opening_balance"}]}} =
             request(:get, txs, nil, token)

    adjust = "/api/workspaces/#{ws}/accounts/#{cash["id"]}/adjust"

    assert {201, %{"transaction" => %{"type" => "adjustment"}}} =
             request(:post, adjust, %{balance: "95.50"}, token)

    assert {200, %{"transaction" => nil}} = request(:post, adjust, %{balance: "95.50"}, token)

    assert {200, %{"account" => %{"balance" => "95.50"}}} =
             request(:get, "/api/workspaces/#{ws}/accounts/#{cash["id"]}", nil, token)
  end

  test "editing a description and reading its history" do
    {token, ws} = register("edit@example.com")

    {201, %{"account" => cash}} =
      request(
        :post,
        "/api/workspaces/#{ws}/accounts",
        %{name: "C", type: "cash", currency: "USD"},
        token
      )

    {201, %{"transaction" => tx}} =
      request(
        :post,
        "/api/workspaces/#{ws}/transactions",
        %{type: "expense", account_id: cash["id"], amount: "5", description: "Cofee"},
        token
      )

    path = "/api/workspaces/#{ws}/transactions/#{tx["id"]}"

    assert {200, %{"transaction" => %{"description" => "Coffee"}}} =
             request(:patch, path, %{description: "Coffee"}, token)

    assert {422, %{"errors" => %{"amount" => _}}} = request(:patch, path, %{amount: "6"}, token)

    assert {200,
            %{
              "events" => [
                %{"action" => "transaction.description_changed", "changes" => changes} | _
              ]
            }} =
             request(:get, "/api/workspaces/#{ws}/activity?subject_id=#{tx["id"]}", nil, token)

    assert changes == %{"description" => ["Cofee", "Coffee"]}
  end

  test "exchange details are rendered with currencies and rate" do
    {token, ws} = register("fx@example.com")

    {201, %{"account" => usd}} =
      request(
        :post,
        "/api/workspaces/#{ws}/accounts",
        %{name: "USD", type: "cash", currency: "USD", opening_balance: "100"},
        token
      )

    {201, %{"account" => uzs}} =
      request(
        :post,
        "/api/workspaces/#{ws}/accounts",
        %{name: "UZS", type: "card", currency: "UZS"},
        token
      )

    {201, %{"transaction" => tx}} =
      request(
        :post,
        "/api/workspaces/#{ws}/transactions",
        %{
          type: "exchange",
          from_account_id: usd["id"],
          from_amount: "100",
          to_account_id: uzs["id"],
          to_amount: "1270000"
        },
        token
      )

    assert tx["exchange"] == %{
             "from_account_id" => usd["id"],
             "from_amount" => "100.00",
             "from_currency" => "USD",
             "to_account_id" => uzs["id"],
             "to_amount" => "1270000.00",
             "to_currency" => "UZS",
             "rate" => "12700",
             "fee_amount" => "0.00"
           }
  end
end
