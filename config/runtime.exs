import Config

database_url =
  case config_env() do
    :test ->
      System.get_env(
        "TEST_DATABASE_URL",
        "postgres://postgres:postgres@localhost:5432/networth_test"
      )

    :dev ->
      System.get_env("DATABASE_URL", "postgres://postgres:postgres@localhost:5432/networth_dev")

    :prod ->
      System.fetch_env!("DATABASE_URL")
  end

config :networth,
  database_url: database_url,
  pool_size: String.to_integer(System.get_env("POOL_SIZE", "10")),
  port: String.to_integer(System.get_env("PORT", "4000")),
  server: config_env() != :test
