defmodule Mix.Tasks.Db do
  @moduledoc false

  def start do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:postgrex)
  end
end

defmodule Mix.Tasks.Db.Create do
  @shortdoc "Creates the database"
  @moduledoc "Creates the database from the configured URL if it does not exist."
  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Tasks.Db.start()
    Networth.DB.Migrator.create_database()
  end
end

defmodule Mix.Tasks.Db.Migrate do
  @shortdoc "Applies pending SQL migrations"
  @moduledoc "Applies pending migrations from priv/migrations."
  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Tasks.Db.start()
    Networth.DB.Migrator.migrate()
  end
end

defmodule Mix.Tasks.Db.Setup do
  @shortdoc "Creates the database and applies migrations"
  @moduledoc "Creates the database if needed and applies pending migrations."
  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Tasks.Db.start()
    Networth.DB.Migrator.create_database()
    Networth.DB.Migrator.migrate()
  end
end

defmodule Mix.Tasks.Db.Drop do
  @shortdoc "Drops the database"
  @moduledoc "Drops the database. Refuses to run in prod."
  use Mix.Task

  @impl true
  def run(_args) do
    if Mix.env() == :prod, do: Mix.raise("db.drop is disabled in prod")
    Mix.Tasks.Db.start()
    Networth.DB.Migrator.drop_database()
  end
end
