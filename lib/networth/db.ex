defmodule Networth.DB do
  @moduledoc """
  Thin layer over a Postgrex pool. Queries are plain SQL with positional params.

  Inside `transaction/1` every query in the calling process runs on the
  transaction's connection, so domain functions compose without passing a
  connection around. Nested `transaction/1` calls join the outer transaction.
  """

  @pool __MODULE__
  @conn_key {__MODULE__, :conn}

  def child_spec(_opts) do
    opts =
      connection_opts()
      |> Keyword.merge(
        name: @pool,
        pool_size: Application.fetch_env!(:networth, :pool_size),
        types: Networth.DB.Types
      )

    Postgrex.child_spec(opts)
  end

  @doc "Connection options parsed from the configured database URL."
  def connection_opts(database_url \\ Application.fetch_env!(:networth, :database_url)) do
    uri = URI.parse(database_url)
    {username, password} = parse_userinfo(uri.userinfo)

    [
      hostname: uri.host || "localhost",
      port: uri.port || 5432,
      database: String.trim_leading(uri.path || "", "/"),
      username: username,
      password: password
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp parse_userinfo(nil), do: {nil, nil}

  defp parse_userinfo(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [user, pass] -> {URI.decode(user), URI.decode(pass)}
      [user] -> {URI.decode(user), nil}
    end
  end

  def query(sql, params \\ []), do: Postgrex.query(conn(), sql, params)

  def query!(sql, params \\ []), do: Postgrex.query!(conn(), sql, params)

  @doc "Runs a query and returns rows as maps with atom keys."
  def all(sql, params \\ []), do: sql |> query!(params) |> to_maps()

  def one(sql, params \\ []) do
    case all(sql, params) do
      [] -> nil
      [row] -> row
      rows -> raise "expected at most one row, got #{length(rows)}"
    end
  end

  def to_maps(%Postgrex.Result{columns: nil}), do: []

  def to_maps(%Postgrex.Result{columns: columns, rows: rows}) do
    keys = Enum.map(columns, &String.to_atom/1)
    Enum.map(rows, fn row -> keys |> Enum.zip(row) |> Map.new() end)
  end

  @doc """
  Runs `fun` in a transaction. Returns `{:ok, result}` or `{:error, reason}`
  when `rollback/1` was called.
  """
  def transaction(fun) when is_function(fun, 0) do
    case Process.get(@conn_key) do
      nil ->
        Postgrex.transaction(@pool, fn conn ->
          Process.put(@conn_key, conn)

          try do
            fun.()
          after
            Process.delete(@conn_key)
          end
        end)

      _conn ->
        {:ok, fun.()}
    end
  end

  @doc """
  Like `transaction/1` for functions that return `{:ok, value}` or
  `{:error, reason}`: an error rolls the transaction back.
  """
  def transact(fun) when is_function(fun, 0) do
    transaction(fn ->
      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> rollback(reason)
      end
    end)
  end

  def rollback(reason) do
    case Process.get(@conn_key) do
      nil -> raise "rollback/1 called outside of a transaction"
      conn -> Postgrex.rollback(conn, reason)
    end
  end

  @doc """
  Adds an optional filter to `{conditions, args}` while building a WHERE
  clause. `condition` receives the placeholder (`"$3"`), or a list of them
  when `value` is a tuple. A nil value adds nothing.
  """
  def where(acc, nil, _condition), do: acc

  def where({conditions, args}, values, condition) when is_tuple(values) do
    values = Tuple.to_list(values)
    placeholders = Enum.map(1..length(values), &"$#{length(args) + &1}")
    {conditions ++ [condition.(placeholders)], args ++ values}
  end

  def where({conditions, args}, value, condition) do
    {conditions ++ [condition.("$#{length(args) + 1}")], args ++ [value]}
  end

  @doc "Name of the violated constraint for unique/foreign key/check errors."
  def constraint_violation(%Postgrex.Error{postgres: %{code: code} = pg})
      when code in [:unique_violation, :foreign_key_violation, :check_violation] do
    {code, pg[:constraint]}
  end

  def constraint_violation(_error), do: nil

  defp conn, do: Process.get(@conn_key, @pool)
end
