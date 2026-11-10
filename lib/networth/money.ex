defmodule Networth.Money do
  @moduledoc """
  Money is an integer amount of minor units plus a currency code.
  The exponent (digits after the decimal point) comes from the currency.

  External input and output use decimal strings in major units ("1250.50"),
  never floats.
  """

  @max_minor 9_223_372_036_854_775_807

  @doc """
  Parses a decimal string into minor units for the given exponent.
  Rejects floats, extra fraction digits and values outside the bigint range.
  """
  def parse(value, exponent) when is_binary(value) and exponent in 0..4 do
    with %{"sign" => sign, "int" => int, "frac" => frac} <-
           Regex.named_captures(~r/^(?<sign>-?)(?<int>\d{1,19})(?:\.(?<frac>\d{1,4}))?$/, value),
         true <- String.length(frac) <= exponent || {:error, :too_many_decimals} do
      minor = String.to_integer(int <> String.pad_trailing(frac, exponent, "0"))
      minor = if sign == "-", do: -minor, else: minor
      if abs(minor) <= @max_minor, do: {:ok, minor}, else: {:error, :out_of_range}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid}
    end
  end

  def parse(_value, _exponent), do: {:error, :invalid}

  def format(minor, exponent) when is_integer(minor) and exponent == 0,
    do: Integer.to_string(minor)

  def format(minor, exponent) when is_integer(minor) and exponent in 1..4 do
    sign = if minor < 0, do: "-", else: ""
    digits = minor |> abs() |> Integer.to_string() |> String.pad_leading(exponent + 1, "0")
    {int, frac} = String.split_at(digits, -exponent)
    sign <> int <> "." <> frac
  end

  @doc "Exchange rate in major units: how many `to` units one `from` unit buys."
  def rate(from_minor, from_exponent, to_minor, to_exponent) do
    Decimal.Context.with(%Decimal.Context{precision: 20}, fn ->
      to_minor
      |> Decimal.new()
      |> Decimal.mult(pow10(from_exponent))
      |> Decimal.div(Decimal.mult(Decimal.new(from_minor), pow10(to_exponent)))
      |> Decimal.normalize()
    end)
  end

  defp pow10(exp), do: Decimal.new(Integer.pow(10, exp))
end
