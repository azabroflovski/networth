defmodule Networth.Web.AuthTest do
  @moduledoc "Signing up and in, tokens, public paths and request ids."
  use Networth.ConnCase

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
    assert Jason.decode!(conn.resp_body) == %{"error" => "rate_limited"}
    assert [retry_after] = get_resp_header(conn, "retry-after")
    assert String.to_integer(retry_after) > 0

    assert {204, nil} = request(:post, "/api/logout", nil, token)
    assert {401, _} = request(:get, "/api/me", nil, token)
    assert {200, _} = request(:get, "/api/me", nil, token2)
  end

  test "every path requires a token except the public ones" do
    {token, ws} = register("paths@example.com")

    for path <- ["/api/me", "/api/workspaces", "/api/nope", "/api/workspaces/#{ws}/accounts"] do
      assert {401, %{"error" => "unauthorized"}} = request(:get, path), path
    end

    assert {200, _} = request(:get, "/api/currencies")
    assert {200, _} = request(:get, "/health")

    assert {401, _} =
             request(:post, "/api/login", %{email: "paths@example.com", password: "nope"})

    assert {404, %{"error" => "not_found"}} =
             request(:get, "/api/workspaces/#{ws}/nope", nil, token)

    assert {404, %{"error" => "not_found"}} =
             request(:get, "/api/workspaces/not-a-uuid/accounts", nil, token)
  end

  test "health check" do
    assert {200, %{"status" => "ok"}} = request(:get, "/health")
  end

  test "every response carries a request id" do
    conn = Router.call(conn(:get, "/health"), Router.init([]))
    assert [id] = get_resp_header(conn, "x-request-id")
    assert byte_size(id) > 0
  end
end
