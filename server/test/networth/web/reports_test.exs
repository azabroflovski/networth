defmodule Networth.Web.ReportsTest do
  @moduledoc "Reports and budgets over HTTP."
  use Networth.ConnCase

  test "reports" do
    {token, ws} = register("reports@example.com")

    {201, %{"account" => cash}} =
      request(
        :post,
        "/api/workspaces/#{ws}/accounts",
        %{
          name: "Cash",
          type: "cash",
          currency: "UZS",
          opening_balance: "1000",
          opened_on: "2026-10-01"
        },
        token
      )

    {201, _} =
      request(
        :post,
        "/api/workspaces/#{ws}/transactions",
        %{type: "expense", account_id: cash["id"], amount: "250.50", occurred_on: "2026-10-05"},
        token
      )

    period = "from=2026-10-01&to=2026-10-31"

    assert {200, %{"report" => %{"currencies" => [uzs]}}} =
             request(:get, "/api/workspaces/#{ws}/reports/income-expense?#{period}", nil, token)

    assert %{
             "currency" => "UZS",
             "net" => "-250.50",
             "expense" => %{
               "total" => "250.50",
               "categories" => [%{"category_id" => nil, "total" => "250.50"}]
             },
             "income" => %{"total" => "0.00", "categories" => []}
           } = uzs

    assert {200, %{"report" => %{"currencies" => [net_worth]}}} =
             request(:get, "/api/workspaces/#{ws}/reports/net-worth?on=2026-10-04", nil, token)

    assert net_worth == %{
             "currency" => "UZS",
             "assets" => "1000.00",
             "liabilities" => "0.00",
             "net" => "1000.00"
           }

    assert {200,
            %{"report" => %{"on" => "2026-10-04", "accounts" => [%{"balance" => "1000.00"}]}}} =
             request(:get, "/api/workspaces/#{ws}/reports/balances?on=2026-10-04", nil, token)

    assert {200, %{"activity" => activity}} =
             request(
               :get,
               "/api/workspaces/#{ws}/accounts/#{cash["id"]}/activity?#{period}",
               nil,
               token
             )

    assert Map.take(activity, ~w(opening_balance inflow outflow closing_balance)) == %{
             "opening_balance" => "0.00",
             "inflow" => "1000.00",
             "outflow" => "250.50",
             "closing_balance" => "749.50"
           }

    assert {422, %{"errors" => %{"from" => _}}} =
             request(:get, "/api/workspaces/#{ws}/reports/income-expense", nil, token)
  end

  test "budgets over HTTP" do
    {token, ws} = register("budget@example.com")

    {201, %{"account" => cash}} =
      request(
        :post,
        "/api/workspaces/#{ws}/accounts",
        %{name: "C", type: "cash", currency: "UZS"},
        token
      )

    {200, %{"categories" => categories}} =
      request(:get, "/api/workspaces/#{ws}/categories", nil, token)

    food = Enum.find(categories, &(&1["name"] == "Food"))["id"]

    assert {200, %{"budget" => %{"month" => "2026-11", "amount" => "500.00"}}} =
             request(
               :put,
               "/api/workspaces/#{ws}/budgets",
               %{category_id: food, currency: "UZS", amount: "500", month: "2026-11"},
               token
             )

    {201, _} =
      request(
        :post,
        "/api/workspaces/#{ws}/transactions",
        %{
          type: "expense",
          account_id: cash["id"],
          amount: "125",
          category_id: food,
          occurred_on: "2026-11-02"
        },
        token
      )

    assert {200, %{"report" => %{"month" => "2026-11", "budgets" => [budget]}}} =
             request(:get, "/api/workspaces/#{ws}/reports/budget?month=2026-11", nil, token)

    assert budget == %{
             "category_id" => food,
             "name" => "Food",
             "currency" => "UZS",
             "limit" => "500.00",
             "spent" => "125.00",
             "remaining" => "375.00",
             "percent" => 25
           }

    assert {200, %{"budgets" => [_]}} = request(:get, "/api/workspaces/#{ws}/budgets", nil, token)
  end
end
