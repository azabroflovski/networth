defmodule Networth.MixProject do
  use Mix.Project

  def project do
    [
      app: :networth,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      releases: [networth: [include_executables_for: [:unix]]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Networth.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.5"},
      {:postgrex, "~> 0.19"},
      {:decimal, "~> 3.2"},
      {:jason, "~> 1.4"}
    ]
  end

  defp aliases do
    [
      "db.reset": ["db.drop", "db.setup"],
      test: ["db.setup", "test"]
    ]
  end
end
