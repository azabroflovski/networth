defmodule Networth.RateLimitTest do
  # The table is global and DataCase clears it, so this case is not async.
  use ExUnit.Case

  alias Networth.RateLimit

  test "a key is limited after reaching the limit within its window" do
    key = make_ref()

    for _ <- 1..3,
        do: assert(RateLimit.check(key, 3) == :ok && RateLimit.record(key, 60_000) == :ok)

    assert {:error, retry_after} = RateLimit.check(key, 3)
    assert retry_after in 59..60
    assert RateLimit.check(make_ref(), 3) == :ok
  end

  test "the window expires and reset clears a key" do
    key = make_ref()
    RateLimit.record(key, 50)
    assert {:error, _} = RateLimit.check(key, 1)

    Process.sleep(60)
    assert RateLimit.check(key, 1) == :ok

    RateLimit.record(key, 60_000)
    RateLimit.reset(key)
    assert RateLimit.check(key, 1) == :ok
  end

  test "concurrent records are all counted" do
    key = make_ref()

    1..50
    |> Enum.map(fn _ -> Task.async(fn -> RateLimit.record(key, 60_000) end) end)
    |> Enum.each(&Task.await/1)

    assert RateLimit.check(key, 50) != :ok
    assert RateLimit.check(key, 51) == :ok
  end
end
