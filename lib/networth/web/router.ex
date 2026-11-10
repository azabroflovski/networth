defmodule Networth.Web.Router do
  @moduledoc """
  JSON API. Handlers only authenticate, call a domain function and render
  its result; all rules live in the domain modules.
  """

  use Plug.Router
  use Plug.ErrorHandler

  alias Networth.{Accounts, Categories, Currencies, Ledger, Reports, Tags, Users, Workspaces}
  alias Networth.Web.JSON, as: View

  plug :match
  plug Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason
  plug :dispatch

  # Auth

  post "/api/register" do
    case Users.register(conn.body_params) do
      {:ok, %{user: user, workspace: workspace}} ->
        send_json(conn, 201, %{
          user: View.user(user),
          workspace: View.workspace(workspace),
          token: Users.create_token(user.id)
        })

      error ->
        render_error(error, conn)
    end
  end

  post "/api/login" do
    case Users.authenticate(conn.body_params["email"], conn.body_params["password"]) do
      {:ok, user} ->
        send_json(conn, 200, %{user: View.user(user), token: Users.create_token(user.id)})

      error ->
        render_error(error, conn)
    end
  end

  post "/api/logout" do
    authenticated(conn, fn _user ->
      conn |> bearer_token() |> Users.delete_token()
      send_resp(conn, 204, "")
    end)
  end

  get "/api/me" do
    authenticated(conn, fn user ->
      send_json(conn, 200, %{
        user: View.user(user),
        workspaces: Enum.map(Workspaces.list_for_user(user.id), &View.workspace/1)
      })
    end)
  end

  get "/api/currencies" do
    send_json(conn, 200, %{currencies: Enum.map(Currencies.list(), &View.currency/1)})
  end

  # Workspaces and membership

  get "/api/workspaces" do
    authenticated(conn, fn user ->
      send_json(conn, 200, %{
        workspaces: Enum.map(Workspaces.list_for_user(user.id), &View.workspace/1)
      })
    end)
  end

  post "/api/workspaces" do
    authenticated(conn, fn user ->
      Workspaces.create(user.id, conn.body_params)
      |> render(conn, 201, :workspace, &View.workspace/1)
    end)
  end

  get "/api/invitations" do
    authenticated(conn, fn user ->
      send_json(conn, 200, %{
        invitations: Enum.map(Workspaces.pending_invitations(user), &View.invitation/1)
      })
    end)
  end

  post "/api/invitations/:id/accept" do
    authenticated(conn, fn user ->
      Workspaces.accept_invitation(user, id) |> render(conn, 200, :workspace, &View.workspace/1)
    end)
  end

  get "/api/workspaces/:wid" do
    in_workspace(conn, wid, fn scope ->
      send_json(conn, 200, %{workspace: View.workspace(Workspaces.get(scope))})
    end)
  end

  patch "/api/workspaces/:wid" do
    in_workspace(conn, wid, fn scope ->
      Workspaces.update(scope, conn.body_params)
      |> render(conn, 200, :workspace, &View.workspace/1)
    end)
  end

  get "/api/workspaces/:wid/members" do
    in_workspace(conn, wid, fn scope ->
      send_json(conn, 200, %{members: Enum.map(Workspaces.list_members(scope), &View.member/1)})
    end)
  end

  patch "/api/workspaces/:wid/members/:user_id" do
    in_workspace(conn, wid, fn scope ->
      Workspaces.update_member(scope, user_id, conn.body_params)
      |> render(conn, 200, :member, &View.member/1)
    end)
  end

  delete "/api/workspaces/:wid/members/:user_id" do
    in_workspace(conn, wid, fn scope ->
      Workspaces.remove_member(scope, user_id) |> render_empty(conn)
    end)
  end

  get "/api/workspaces/:wid/invitations" do
    in_workspace(conn, wid, fn scope ->
      Workspaces.list_invitations(scope) |> render_list(conn, :invitations, &View.invitation/1)
    end)
  end

  post "/api/workspaces/:wid/invitations" do
    in_workspace(conn, wid, fn scope ->
      Workspaces.invite(scope, conn.body_params)
      |> render(conn, 201, :invitation, &View.invitation/1)
    end)
  end

  delete "/api/workspaces/:wid/invitations/:id" do
    in_workspace(conn, wid, fn scope ->
      Workspaces.revoke_invitation(scope, id) |> render_empty(conn)
    end)
  end

  # Accounts

  get "/api/workspaces/:wid/accounts" do
    in_workspace(conn, wid, fn scope ->
      send_json(conn, 200, %{accounts: Enum.map(Accounts.list(scope), &View.account/1)})
    end)
  end

  post "/api/workspaces/:wid/accounts" do
    in_workspace(conn, wid, fn scope ->
      Accounts.create(scope, conn.body_params) |> render(conn, 201, :account, &View.account/1)
    end)
  end

  get "/api/workspaces/:wid/accounts/:id" do
    in_workspace(conn, wid, fn scope ->
      Accounts.get(scope, id) |> render(conn, 200, :account, &View.account/1)
    end)
  end

  patch "/api/workspaces/:wid/accounts/:id" do
    in_workspace(conn, wid, fn scope ->
      Accounts.update(scope, id, conn.body_params) |> render(conn, 200, :account, &View.account/1)
    end)
  end

  get "/api/workspaces/:wid/accounts/:id/activity" do
    in_workspace(conn, wid, fn scope ->
      conn = fetch_query_params(conn)

      Reports.account_activity(scope, id, conn.query_params)
      |> render(conn, 200, :activity, &View.account_activity/1)
    end)
  end

  # Reports

  get "/api/workspaces/:wid/reports/income-expense" do
    in_workspace(conn, wid, fn scope ->
      conn = fetch_query_params(conn)

      Reports.income_expense(scope, conn.query_params)
      |> render(conn, 200, :report, &View.income_expense/1)
    end)
  end

  get "/api/workspaces/:wid/reports/balances" do
    in_workspace(conn, wid, fn scope ->
      conn = fetch_query_params(conn)
      Reports.balances(scope, conn.query_params) |> render(conn, 200, :report, &View.balances/1)
    end)
  end

  # Transactions

  get "/api/workspaces/:wid/transactions" do
    in_workspace(conn, wid, fn scope ->
      conn = fetch_query_params(conn)

      case Ledger.list(scope, conn.query_params) do
        {:ok, %{transactions: transactions, next_cursor: next_cursor}} ->
          send_json(conn, 200, %{
            transactions: Enum.map(transactions, &View.transaction/1),
            next_cursor: next_cursor
          })

        error ->
          render_error(error, conn)
      end
    end)
  end

  post "/api/workspaces/:wid/transactions" do
    in_workspace(conn, wid, fn scope ->
      Ledger.post(scope, conn.body_params) |> render(conn, 201, :transaction, &View.transaction/1)
    end)
  end

  get "/api/workspaces/:wid/transactions/:id" do
    in_workspace(conn, wid, fn scope ->
      Ledger.get(scope, id) |> render(conn, 200, :transaction, &View.transaction/1)
    end)
  end

  patch "/api/workspaces/:wid/transactions/:id" do
    in_workspace(conn, wid, fn scope ->
      Ledger.update(scope, id, conn.body_params)
      |> render(conn, 200, :transaction, &View.transaction/1)
    end)
  end

  get "/api/workspaces/:wid/transactions/:id/changes" do
    in_workspace(conn, wid, fn scope ->
      Ledger.changes(scope, id) |> render_list(conn, :changes, &View.transaction_change/1)
    end)
  end

  post "/api/workspaces/:wid/transactions/:id/reverse" do
    in_workspace(conn, wid, fn scope ->
      Ledger.reverse(scope, id, conn.body_params)
      |> render(conn, 201, :transaction, &View.transaction/1)
    end)
  end

  put "/api/workspaces/:wid/transactions/:id/tags" do
    in_workspace(conn, wid, fn scope ->
      Ledger.set_tags(scope, id, conn.body_params)
      |> render(conn, 200, :transaction, &View.transaction/1)
    end)
  end

  # Categories and tags

  get "/api/workspaces/:wid/categories" do
    in_workspace(conn, wid, fn scope ->
      send_json(conn, 200, %{categories: Enum.map(Categories.list(scope), &View.category/1)})
    end)
  end

  post "/api/workspaces/:wid/categories" do
    in_workspace(conn, wid, fn scope ->
      Categories.create(scope, conn.body_params) |> render(conn, 201, :category, &View.category/1)
    end)
  end

  patch "/api/workspaces/:wid/categories/:id" do
    in_workspace(conn, wid, fn scope ->
      Categories.update(scope, id, conn.body_params)
      |> render(conn, 200, :category, &View.category/1)
    end)
  end

  get "/api/workspaces/:wid/tags" do
    in_workspace(conn, wid, fn scope ->
      send_json(conn, 200, %{tags: Enum.map(Tags.list(scope), &View.tag/1)})
    end)
  end

  post "/api/workspaces/:wid/tags" do
    in_workspace(conn, wid, fn scope ->
      Tags.create(scope, conn.body_params) |> render(conn, 201, :tag, &View.tag/1)
    end)
  end

  patch "/api/workspaces/:wid/tags/:id" do
    in_workspace(conn, wid, fn scope ->
      Tags.update(scope, id, conn.body_params) |> render(conn, 200, :tag, &View.tag/1)
    end)
  end

  delete "/api/workspaces/:wid/tags/:id" do
    in_workspace(conn, wid, fn scope -> Tags.delete(scope, id) |> render_empty(conn) end)
  end

  match _ do
    send_json(conn, 404, %{error: "not_found"})
  end

  # Helpers

  defp authenticated(conn, fun) do
    case bearer_token(conn) && Users.get_by_token(bearer_token(conn)) do
      %{} = user -> fun.(user)
      _ -> send_json(conn, 401, %{error: "unauthorized"})
    end
  end

  defp in_workspace(conn, workspace_id, fun) do
    authenticated(conn, fn user ->
      case Workspaces.authorize(user.id, workspace_id) do
        {:ok, scope} -> fun.(scope)
        {:error, reason} -> render_error({:error, reason}, conn)
      end
    end)
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> nil
    end
  end

  defp render({:ok, data}, conn, status, key, view),
    do: send_json(conn, status, %{key => view.(data)})

  defp render(error, conn, _status, _key, _view), do: render_error(error, conn)

  defp render_list({:ok, items}, conn, key, view),
    do: send_json(conn, 200, %{key => Enum.map(items, view)})

  defp render_list(error, conn, _key, _view), do: render_error(error, conn)

  defp render_empty(:ok, conn), do: send_resp(conn, 204, "")
  defp render_empty(error, conn), do: render_error(error, conn)

  defp render_error({:error, {:invalid, errors}}, conn),
    do: send_json(conn, 422, %{error: "invalid", errors: errors})

  defp render_error({:error, :invalid_credentials}, conn),
    do: send_json(conn, 401, %{error: "invalid_credentials"})

  defp render_error({:error, :not_found}, conn), do: send_json(conn, 404, %{error: "not_found"})
  defp render_error({:error, :forbidden}, conn), do: send_json(conn, 403, %{error: "forbidden"})

  defp render_error({:error, :id_taken}, conn), do: send_json(conn, 409, %{error: "id_taken"})

  defp render_error({:error, :last_owner}, conn),
    do: send_json(conn, 409, %{error: "last_owner"})

  defp render_error({:error, :idempotency_key_reused}, conn),
    do: send_json(conn, 409, %{error: "idempotency_key_reused"})

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode_to_iodata!(body))
  end

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{reason: reason}) do
    {status, error} =
      case reason do
        %Plug.Parsers.ParseError{} -> {400, "malformed_json"}
        %Plug.Parsers.UnsupportedMediaTypeError{} -> {415, "unsupported_media_type"}
        _ -> {conn.status, "internal_error"}
      end

    send_json(conn, status, %{error: error})
  end
end
