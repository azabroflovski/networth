defmodule Networth.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [Networth.DB, Networth.RateLimit] ++ http_server()
    Supervisor.start_link(children, strategy: :one_for_one, name: Networth.Supervisor)
  end

  defp http_server do
    if Application.get_env(:networth, :server, false) do
      [{Bandit, plug: Networth.Web.Router, port: Application.fetch_env!(:networth, :port)}]
    else
      []
    end
  end
end
