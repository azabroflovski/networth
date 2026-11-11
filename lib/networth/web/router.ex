defmodule Networth.Web.Router do
  @moduledoc """
  JSON API entry point: public routes, the signed-in user's routes, and
  everything inside a workspace forwarded to `Networth.Web.WorkspaceRouter`.

  Handlers only call a domain function and render its result; all rules
  live in the domain modules. Every path except the public ones requires a
  bearer token (`Networth.Web.Auth`).
  """

  use Plug.Router
  use Plug.ErrorHandler

  import Networth.Web.{Auth, Response}

  alias Networth.{Currencies, DB, Users, Workspaces}
  alias Networth.Web.JSON, as: View

  plug :match
  plug Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason
  plug :fetch_query_params
  plug :authenticate
  plug :dispatch

  # Public

  get "/health" do
    case DB.ping() do
      :ok -> json(conn, 200, %{status: "ok"})
      :error -> json(conn, 503, %{status: "database_unavailable"})
    end
  end

  get "/api/currencies" do
    render_list(conn, Currencies.list(), :currencies, &View.currency/1)
  end

  post "/api/register" do
    case Users.register(conn.body_params) do
      {:ok, %{user: user, workspace: workspace, token: token}} ->
        json(conn, 201, %{
          user: View.user(user),
          workspace: View.workspace(workspace),
          token: token
        })

      error ->
        error(conn, error)
    end
  end

  post "/api/login" do
    case Users.login(conn.body_params["email"], conn.body_params["password"], conn.remote_ip) do
      {:ok, user, token} ->
        json(conn, 200, %{user: View.user(user), token: token})

      {:error, {:rate_limited, retry_after}} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> json(429, %{error: "too_many_attempts"})

      error ->
        error(conn, error)
    end
  end

  # The signed-in user

  post "/api/logout" do
    :ok = Users.delete_token(conn.assigns.token)
    send_resp(conn, 204, "")
  end

  get "/api/me" do
    user = conn.assigns.current_user

    json(conn, 200, %{
      user: View.user(user),
      workspaces: Enum.map(Workspaces.list_for_user(user.id), &View.workspace/1)
    })
  end

  get "/api/workspaces" do
    render_list(
      conn,
      Workspaces.list_for_user(conn.assigns.current_user.id),
      :workspaces,
      &View.workspace/1
    )
  end

  post "/api/workspaces" do
    result = Workspaces.create(conn.assigns.current_user.id, conn.body_params)
    render(conn, result, :workspace, &View.workspace/1, 201)
  end

  get "/api/invitations" do
    invitations = Workspaces.pending_invitations(conn.assigns.current_user)
    render_list(conn, invitations, :invitations, &View.invitation/1)
  end

  post "/api/invitations/:id/accept" do
    result = Workspaces.accept_invitation(conn.assigns.current_user, id)
    render(conn, result, :workspace, &View.workspace/1)
  end

  forward "/api/workspaces/:wid", to: Networth.Web.WorkspaceRouter

  match _ do
    json(conn, 404, %{error: "not_found"})
  end

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{reason: reason}) do
    {status, error} =
      case reason do
        %Plug.Parsers.ParseError{} -> {400, "malformed_json"}
        %Plug.Parsers.UnsupportedMediaTypeError{} -> {415, "unsupported_media_type"}
        _ -> {conn.status, "internal_error"}
      end

    json(conn, status, %{error: error})
  end
end
