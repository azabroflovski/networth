defmodule Networth.Web.RouterTest do
  use Networth.DataCase

  import Plug.Test
  import Plug.Conn

  alias Networth.Web.Router

  defp request(method, path, body \\ nil, token \\ nil) do
    conn =
      if body,
        do:
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json"),
        else: conn(method, path)

    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    conn = Router.call(conn, Router.init([]))
    {conn.status, if(conn.resp_body == "", do: nil, else: Jason.decode!(conn.resp_body))}
  end

  defp register(email) do
    {201, body} =
      request(:post, "/api/register", %{email: email, name: "U", password: "password123"})

    {body["token"], body["workspace"]["id"]}
  end

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

  test "authentication is required and tokens can be revoked" do
    {token, ws} = register("auth@example.com")

    assert {401, _} = request(:get, "/api/me")
    assert {401, _} = request(:get, "/api/workspaces/#{ws}/accounts", nil, "bogus")

    assert {200, %{"user" => %{"email" => "auth@example.com"}, "workspaces" => [_]}} =
             request(:get, "/api/me", nil, token)

    assert {200, %{"token" => token2}} =
             request(:post, "/api/login", %{email: "auth@example.com", password: "password123"})

    assert {401, %{"error" => "invalid_credentials"}} =
             request(:post, "/api/login", %{email: "auth@example.com", password: "nope"})

    for _ <- 1..4,
        do: request(:post, "/api/login", %{email: "auth@example.com", password: "nope"})

    conn =
      conn(
        :post,
        "/api/login",
        Jason.encode!(%{email: "auth@example.com", password: "password123"})
      )
      |> put_req_header("content-type", "application/json")
      |> Router.call(Router.init([]))

    assert conn.status == 429
    assert [retry_after] = get_resp_header(conn, "retry-after")
    assert String.to_integer(retry_after) > 0

    assert {204, nil} = request(:post, "/api/logout", nil, token)
    assert {401, _} = request(:get, "/api/me", nil, token)
    assert {200, _} = request(:get, "/api/me", nil, token2)
  end

  test "another user's workspace looks nonexistent" do
    {_alice, alice_ws} = register("alice@example.com")
    {bob, _} = register("bob@example.com")

    assert {404, %{"error" => "not_found"}} =
             request(:get, "/api/workspaces/#{alice_ws}/accounts", nil, bob)

    assert {404, _} =
             request(:post, "/api/workspaces/#{alice_ws}/transactions", %{type: "income"}, bob)
  end

  test "invitation flow over HTTP" do
    {alice, _} = register("alice@example.com")
    {bob, _} = register("bob@example.com")

    {201, %{"workspace" => %{"id" => family}}} =
      request(:post, "/api/workspaces", %{name: "Family"}, alice)

    {201, %{"invitation" => %{"id" => inv}}} =
      request(:post, "/api/workspaces/#{family}/invitations", %{email: "bob@example.com"}, alice)

    assert {200, %{"invitations" => [%{"id" => ^inv, "workspace_name" => "Family"}]}} =
             request(:get, "/api/invitations", nil, bob)

    assert {200, %{"workspace" => %{"id" => ^family, "role" => "member"}}} =
             request(:post, "/api/invitations/#{inv}/accept", nil, bob)

    assert {403, _} =
             request(
               :post,
               "/api/workspaces/#{family}/invitations",
               %{email: "c@example.com"},
               bob
             )

    assert {200, %{"members" => [_, _]}} =
             request(:get, "/api/workspaces/#{family}/members", nil, bob)
  end

  test "member management over HTTP" do
    {alice, _} = register("alice@example.com")
    {bob, _} = register("bob@example.com")

    {201, %{"workspace" => %{"id" => family}}} =
      request(:post, "/api/workspaces", %{name: "Family"}, alice)

    {201, %{"invitation" => %{"id" => inv}}} =
      request(:post, "/api/workspaces/#{family}/invitations", %{email: "bob@example.com"}, alice)

    {200, _} = request(:post, "/api/invitations/#{inv}/accept", nil, bob)

    {200, %{"members" => members}} =
      request(:get, "/api/workspaces/#{family}/members", nil, alice)

    ids = Map.new(members, &{&1["email"], &1["user_id"]})
    members_path = "/api/workspaces/#{family}/members"

    assert {409, %{"error" => "last_owner"}} =
             request(:delete, "#{members_path}/#{ids["alice@example.com"]}", nil, alice)

    assert {200, %{"member" => %{"role" => "owner"}}} =
             request(:patch, "#{members_path}/#{ids["bob@example.com"]}", %{role: "owner"}, alice)

    assert {204, nil} =
             request(:delete, "#{members_path}/#{ids["alice@example.com"]}", nil, alice)

    assert {404, _} = request(:get, "/api/workspaces/#{family}", nil, alice)

    assert {200, %{"members" => [%{"email" => "bob@example.com", "role" => "owner"}]}} =
             request(:get, members_path, nil, bob)
  end

  test "health check" do
    assert {200, %{"status" => "ok"}} = request(:get, "/health")
  end

  test "validation errors carry a code, details and a message" do
    {token, ws} = register("codes@example.com")

    {201, %{"account" => yen}} =
      request(
        :post,
        "/api/workspaces/#{ws}/accounts",
        %{name: "Yen", type: "cash", currency: "JPY"},
        token
      )

    assert {422, %{"error" => "invalid", "errors" => errors}} =
             request(
               :post,
               "/api/workspaces/#{ws}/transactions",
               %{type: "income", account_id: yen["id"], amount: "1.5", occurred_on: "soon"},
               token
             )

    assert errors == %{
             "occurred_on" => %{"code" => "invalid_date", "message" => "must be an ISO 8601 date"}
           }

    assert {422, %{"errors" => %{"amount" => amount_error}}} =
             request(
               :post,
               "/api/workspaces/#{ws}/transactions",
               %{type: "income", account_id: yen["id"], amount: "1.5"},
               token
             )

    assert amount_error == %{
             "code" => "too_many_decimals",
             "currency" => "JPY",
             "decimals" => 0,
             "message" => "JPY allows at most 0 decimal places"
           }
  end

  test "validation errors, malformed JSON and unknown routes" do
    {token, ws} = register("errors@example.com")

    {201, %{"account" => cash}} =
      request(
        :post,
        "/api/workspaces/#{ws}/accounts",
        %{name: "C", type: "cash", currency: "USD"},
        token
      )

    assert {422, %{"error" => "invalid", "errors" => %{"amount" => _}}} =
             request(
               :post,
               "/api/workspaces/#{ws}/transactions",
               %{type: "income", account_id: cash["id"], amount: 12.5},
               token
             )

    expense = %{type: "expense", account_id: cash["id"], amount: "1", idempotency_key: "k1"}
    assert {201, _} = request(:post, "/api/workspaces/#{ws}/transactions", expense, token)

    assert {409, %{"error" => "idempotency_key_reused"}} =
             request(:post, "/api/workspaces/#{ws}/transactions", %{expense | amount: "2"}, token)

    conn =
      conn(:post, "/api/register", "{not json")
      |> put_req_header("content-type", "application/json")

    assert_raise Plug.Parsers.ParseError, fn -> Router.call(conn, Router.init([])) end
    assert {400, _headers, body} = sent_resp(conn)
    assert Jason.decode!(body) == %{"error" => "malformed_json"}

    assert {404, %{"error" => "not_found"}} = request(:get, "/api/nope", nil, token)
  end
end
