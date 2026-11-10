defmodule Networth.TokenCleanup do
  @moduledoc "Deletes expired bearer tokens once an hour."

  use GenServer

  @every :timer.hours(1)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:run, state) do
    Networth.Users.delete_expired_tokens()
    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :run, @every)
end
