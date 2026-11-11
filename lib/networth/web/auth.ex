defmodule Networth.Web.Auth do
  @moduledoc """
  Authentication plugs.

  `authenticate/2` resolves the user from the bearer token for every path
  except the public ones, so a new route is protected unless it is listed
  here. `authorize_workspace/2` turns membership in the workspace of the
  path into `conn.assigns.scope`; non-members get 404.
  """

  import Plug.Conn
  import Networth.Web.Response, only: [error: 2]

  alias Networth.{Users, Workspaces}

  @public ["/health", "/api/register", "/api/login", "/api/currencies"]

  def authenticate(%{request_path: path} = conn, _opts) when path in @public, do: conn

  def authenticate(conn, _opts) do
    with token when is_binary(token) <- bearer_token(conn),
         %{} = user <- Users.get_by_token(token) do
      conn |> assign(:current_user, user) |> assign(:token, token)
    else
      _ -> conn |> error({:error, :unauthorized}) |> halt()
    end
  end

  def authorize_workspace(conn, _opts) do
    case Workspaces.authorize(conn.assigns.current_user.id, conn.path_params["wid"]) do
      {:ok, scope} -> assign(conn, :scope, scope)
      error -> conn |> error(error) |> halt()
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> nil
    end
  end
end
