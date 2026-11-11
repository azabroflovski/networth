defmodule Networth.ConnCase do
  @moduledoc """
  HTTP tests: the database is reset like in `Networth.DataCase`, and
  requests go through `Networth.Web.Router`.
  """

  use ExUnit.CaseTemplate

  import Plug.Conn
  import Plug.Test

  alias Networth.Web.Router

  using do
    quote do
      import Plug.Conn
      import Plug.Test
      import Networth.{ConnCase, DataCase}

      alias Networth.{Accounts, Categories, DB, Ledger, Scope, Tags, Users, Workspaces}
      alias Networth.Web.Router
    end
  end

  setup do
    Networth.DataCase.reset_database()
    :ok
  end

  @doc "Sends a request; returns `{status, decoded body or nil}`."
  def request(method, path, body \\ nil, token \\ nil) do
    conn = method |> build(path, body, token) |> call()
    {conn.status, if(conn.resp_body == "", do: nil, else: Jason.decode!(conn.resp_body))}
  end

  @doc "A request conn with an optional JSON body and bearer token."
  def build(method, path, body \\ nil, token \\ nil) do
    conn =
      if body,
        do:
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json"),
        else: conn(method, path)

    if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
  end

  def call(conn), do: Router.call(conn, Router.init([]))

  @doc "Registers a user over HTTP; returns `{token, personal_workspace_id}`."
  def register(email) do
    {201, body} =
      request(:post, "/api/register", %{email: email, name: "U", password: "password123"})

    {body["token"], body["workspace"]["id"]}
  end
end
