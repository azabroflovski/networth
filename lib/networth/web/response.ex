defmodule Networth.Web.Response do
  @moduledoc """
  Sending JSON responses and mapping domain results to HTTP statuses.
  Every function takes the conn first, so handlers read as
  `conn |> send_result(Accounts.get(scope, id), :account, &Serializer.account/1)`.
  """

  import Plug.Conn

  alias Networth.Web.Serializer

  def send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode_to_iodata!(body))
  end

  @doc "`{:ok, data}` as `%{key => serialize.(data)}`, or the error."
  def send_result(conn, result, key, serialize, status \\ 200)

  def send_result(conn, {:ok, data}, key, serialize, status),
    do: send_json(conn, status, %{key => serialize.(data)})

  def send_result(conn, error, _key, _serialize, _status), do: send_error(conn, error)

  @doc "A list (or `{:ok, list}`) as `%{key => [serialize.(item)]}`, or the error."
  def send_list(conn, {:ok, items}, key, serialize), do: send_list(conn, items, key, serialize)

  def send_list(conn, items, key, serialize) when is_list(items),
    do: send_json(conn, 200, %{key => Enum.map(items, serialize)})

  def send_list(conn, error, _key, _serialize), do: send_error(conn, error)

  @doc "A cursor page `{:ok, %{key => items, next_cursor: cursor}}`."
  def send_page(conn, {:ok, %{next_cursor: cursor} = page}, key, serialize),
    do:
      send_json(conn, 200, %{
        key => Enum.map(Map.fetch!(page, key), serialize),
        next_cursor: cursor
      })

  def send_page(conn, error, _key, _serialize), do: send_error(conn, error)

  @doc "No content (204) on success, or the error."
  def send_empty(conn, :ok), do: send_resp(conn, 204, "")
  def send_empty(conn, {:ok, _}), do: send_resp(conn, 204, "")
  def send_empty(conn, error), do: send_error(conn, error)

  def send_error(conn, {:error, {:rate_limited, retry_after}}) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> send_json(429, %{error: "rate_limited"})
  end

  def send_error(conn, {:error, {:invalid, errors}}),
    do: send_json(conn, 422, %{error: "invalid", errors: Serializer.validation_errors(errors)})

  def send_error(conn, {:error, reason}) do
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

    send_json(conn, status, %{error: Atom.to_string(reason)})
  end
end
