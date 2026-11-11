defmodule Networth.Web.ErrorsTest do
  @moduledoc "Error responses: validation codes, malformed requests, unknown routes."
  use Networth.ConnCase

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
