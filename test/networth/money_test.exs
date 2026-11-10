defmodule Networth.MoneyTest do
  use ExUnit.Case, async: true

  alias Networth.Money

  test "parses decimal strings into minor units using the currency exponent" do
    assert Money.parse("12.5", 2) == {:ok, 1250}
    assert Money.parse("12.50", 2) == {:ok, 1250}
    assert Money.parse("12", 2) == {:ok, 1200}
    assert Money.parse("-0.01", 2) == {:ok, -1}
    assert Money.parse("1500", 0) == {:ok, 1500}
    assert Money.parse("1.234", 3) == {:ok, 1234}
  end

  test "rejects more decimals than the currency allows" do
    assert Money.parse("1.5", 0) == {:error, :too_many_decimals}
    assert Money.parse("1.234", 2) == {:error, :too_many_decimals}
  end

  test "rejects floats, malformed strings and out-of-range values" do
    assert Money.parse(12.5, 2) == {:error, :invalid}
    assert Money.parse(12, 2) == {:error, :invalid}
    assert Money.parse("1e3", 2) == {:error, :invalid}
    assert Money.parse("1,50", 2) == {:error, :invalid}
    assert Money.parse(" 1", 2) == {:error, :invalid}
    assert Money.parse("", 2) == {:error, :invalid}
    assert Money.parse("9223372036854775807", 0) == {:ok, 9_223_372_036_854_775_807}
    assert Money.parse("9223372036854775808", 0) == {:error, :out_of_range}
    assert Money.parse("9223372036854775807", 2) == {:error, :out_of_range}
  end

  test "formats minor units" do
    assert Money.format(1250, 2) == "12.50"
    assert Money.format(5, 2) == "0.05"
    assert Money.format(-5, 2) == "-0.05"
    assert Money.format(1500, 0) == "1500"
    assert Money.format(1, 3) == "0.001"
  end

  test "computes exchange rates in major units" do
    # 100.00 USD -> 1 270 000.00 UZS
    assert Decimal.equal?(Money.rate(10_000, 2, 127_000_000, 2), 12_700)
    # 1.000 KWD -> 3.25 USD
    assert Decimal.equal?(Money.rate(1000, 3, 325, 2), Decimal.new("3.25"))
    # 100 JPY -> 0.65 USD
    assert Decimal.equal?(Money.rate(100, 0, 65, 2), Decimal.new("0.0065"))
  end
end
