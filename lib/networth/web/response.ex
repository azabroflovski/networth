defmodule Networth.Web.Response do
  @moduledoc """
  Sending JSON responses and mapping domain results to HTTP statuses.
  Every function takes the conn first, so handlers read as
  `conn |> render(Accounts.get(scope, id), :account, &View.account/1)`.
  """

  import Plug.Conn

  alias Networth.Web.JSON, as: View

  def json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode_to_iodata!(body))
  end

  @doc "`{:ok, data}` as `%{key => view.(data)}`, or the error."
  def render(conn, result, key, view, status \\ 200)
  def render(conn, {:ok, data}, key, view, status), do: json(conn, status, %{key => view.(data)})
  def render(conn, error, _key, _view, _status), do: error(conn, error)

  @doc "A list (or `{:ok, list}`) as `%{key => [view.(item)]}`, or the error."
  def render_list(conn, {:ok, items}, key, view), do: render_list(conn, items, key, view)

  def render_list(conn, items, key, view) when is_list(items),
    do: json(conn, 200, %{key => Enum.map(items, view)})

  def render_list(conn, error, _key, _view), do: error(conn, error)

  @doc "A cursor page `{:ok, %{key => items, next_cursor: cursor}}`."
  def render_page(conn, {:ok, %{next_cursor: cursor} = page}, key, view),
    do: json(conn, 200, %{key => Enum.map(Map.fetch!(page, key), view), next_cursor: cursor})

  def render_page(conn, error, _key, _view), do: error(conn, error)

  @doc "No content (204) on success, or the error."
  def render_empty(conn, :ok), do: send_resp(conn, 204, "")
  def render_empty(conn, {:ok, _}), do: send_resp(conn, 204, "")
  def render_empty(conn, error), do: error(conn, error)

  def error(conn, {:error, {:invalid, errors}}),
    do: json(conn, 422, %{error: "invalid", errors: View.validation_errors(errors)})

  def error(conn, {:error, reason}) do
    status =
      case reason do
        :unauthorized -> 401
        :invalid_credentials -> 401
        :forbidden -> 403
        :not_found -> 404
        :already_reversed -> 409
        :id_taken -> 409
        :last_owner -> 409
        :idempotency_key_reused -> 409
      end

    json(conn, status, %{error: Atom.to_string(reason)})
  end
end
