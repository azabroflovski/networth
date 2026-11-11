defmodule Networth.RateLimit do
  @moduledoc """
  Fixed-window counters in ETS, local to this node.

  `check/2` tells whether a key is over its limit, `record/2` counts an
  event, `reset/1` forgets a key. Expired windows are swept periodically.
  With several application instances each keeps its own counters.
  """

  use GenServer

  @table __MODULE__
  @sweep_every :timer.minutes(1)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "`:ok`, or `{:error, retry_after_seconds}` when `key` reached `limit` in its window."
  def check(key, limit) do
    now = now()

    case :ets.lookup(@table, key) do
      [{^key, count, expires_at}] when expires_at > now and count >= limit ->
        {:error, div(expires_at - now + 999, 1000)}

      _ ->
        :ok
    end
  end

  @doc "Counts one event for `key`; a new window of `window_ms` starts when none is active."
  def record(key, window_ms) do
    now = now()

    case :ets.lookup(@table, key) do
      [{^key, _count, expires_at}] when expires_at > now ->
        :ets.update_counter(@table, key, {2, 1})

      [_expired] ->
        :ets.insert(@table, {key, 1, now + window_ms})

      [] ->
        :ets.insert_new(@table, {key, 1, now + window_ms}) ||
          :ets.update_counter(@table, key, {2, 1})
    end

    :ok
  end

  def reset(key) do
    :ets.delete(@table, key)
    :ok
  end

  @doc false
  def reset_all, do: :ets.delete_all_objects(@table)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule_sweep()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = now()
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_every)

  defp now, do: System.monotonic_time(:millisecond)
end
