defmodule Networth.UUIDTest do
  use ExUnit.Case, async: true

  alias Networth.UUID

  test "casts UUID strings to canonical lowercase form" do
    assert UUID.cast("0193A6C2-7D3E-7B21-9F4A-1C2D3E4F5A6B") ==
             "0193a6c2-7d3e-7b21-9f4a-1c2d3e4f5a6b"
  end

  test "rejects anything that is not a UUID string" do
    for value <- [
          nil,
          42,
          "",
          "42",
          "0193a6c2-7d3e-7b21-9f4a-1c2d3e4f5a6",
          "0193a6c2x7d3e-7b21-9f4a-1c2d3e4f5a6b",
          "zz93a6c2-7d3e-7b21-9f4a-1c2d3e4f5a6b"
        ] do
      assert UUID.cast(value) == nil, inspect(value)
    end
  end

  test "round-trips through the 16-byte form" do
    uuid = "0193a6c2-7d3e-7b21-9f4a-1c2d3e4f5a6b"
    {:ok, bin} = UUID.dump(uuid)

    assert byte_size(bin) == 16
    assert UUID.load(bin) == uuid
  end
end
