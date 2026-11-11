defmodule Networth.DB.Migrator do
  @moduledoc """
  Applies `priv/migrations/NNNN_name.sql` files in order.

  Each file runs through the simple query protocol (so it may contain several
  statements and function bodies) inside one transaction together with its
  `schema_migrations` record. Migrations are forward-only.
  """

  alias Postgrex.SimpleConnection

  require Logger

  @behaviour SimpleConnection

  def migrate(database_url \\ Application.fetch_env!(:networth, :database_url)) do
    with_connection(database_url, fn conn ->
      run!(conn, """
      CREATE TABLE IF NOT EXISTS schema_migrations (
        version bigint PRIMARY KEY,
        name text NOT NULL,
        inserted_at timestamptz NOT NULL DEFAULT now()
      )
      """)

      [%{rows: rows}] = run!(conn, "SELECT version FROM schema_migrations")
      applied = MapSet.new(rows, fn [v] -> String.to_integer(v) end)

      for {version, name, path} <- migration_files(), version not in applied do
        Logger.info("Applying migration #{version}_#{name}")

        run!(conn, """
        BEGIN;
        SELECT pg_advisory_xact_lock(#{lock_key()});
        #{File.read!(path)}
        ;
        INSERT INTO schema_migrations (version, name) VALUES (#{version}, '#{name}');
        COMMIT;
        """)

        version
      end
    end)
  end

  def create_database(database_url \\ Application.fetch_env!(:networth, :database_url)) do
    name = Keyword.fetch!(Networth.DB.connection_opts(database_url), :database)

    with_connection(maintenance_url(database_url), fn conn ->
      [%{rows: rows}] =
        run!(conn, "SELECT 1 FROM pg_database WHERE datname = #{quote_literal(name)}")

      if rows == [] do
        run!(conn, "CREATE DATABASE #{quote_ident(name)}")
        :created
      else
        :already_exists
      end
    end)
  end

  def drop_database(database_url \\ Application.fetch_env!(:networth, :database_url)) do
    name = Keyword.fetch!(Networth.DB.connection_opts(database_url), :database)

    with_connection(maintenance_url(database_url), fn conn ->
      run!(conn, "DROP DATABASE IF EXISTS #{quote_ident(name)} WITH (FORCE)")
      :ok
    end)
  end

  defp migration_files do
    dir = Application.app_dir(:networth, "priv/migrations")

    dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".sql"))
    |> Enum.map(fn file ->
      [version, name] = file |> Path.rootname() |> String.split("_", parts: 2)
      {String.to_integer(version), name, Path.join(dir, file)}
    end)
    |> Enum.sort()
  end

  defp lock_key, do: :erlang.phash2(__MODULE__)

  defp maintenance_url(database_url) do
    database_url |> URI.parse() |> Map.put(:path, "/postgres") |> URI.to_string()
  end

  defp quote_ident(name), do: ~s("#{String.replace(name, ~s("), ~s(""))}")
  defp quote_literal(value), do: "'#{String.replace(value, "'", "''")}'"

  defp with_connection(database_url, fun) do
    opts = Networth.DB.connection_opts(database_url)
    {:ok, conn} = SimpleConnection.start_link(__MODULE__, [], opts ++ [sync_connect: true])

    try do
      fun.(conn)
    after
      GenServer.stop(conn)
    end
  end

  defp run!(conn, sql) do
    case SimpleConnection.call(conn, {:query, sql}) do
      {:ok, results} -> results
      {:error, error} -> raise error
    end
  end

  @impl true
  def init(_args), do: {:ok, %{from: nil}}

  @impl true
  def handle_call({:query, sql}, from, state), do: {:query, sql, %{state | from: from}}

  @impl true
  def handle_result(%Postgrex.Error{} = error, state) do
    SimpleConnection.reply(state.from, {:error, error})
    {:noreply, %{state | from: nil}}
  end

  def handle_result(results, state) when is_list(results) do
    SimpleConnection.reply(state.from, {:ok, results})
    {:noreply, %{state | from: nil}}
  end

  @impl true
  def notify(_channel, _payload, _state), do: :ok
end
