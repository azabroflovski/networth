defmodule Networth.Currencies do
  @moduledoc """
  Currency reference data. The table only changes through migrations, so it is
  cached in `:persistent_term` on first use.
  """

  alias Networth.DB

  def list do
    cached() |> Map.values() |> Enum.sort_by(& &1.code)
  end

  def get(code) when is_binary(code), do: Map.get(cached(), code)
  def get(_code), do: nil

  def exponent!(code), do: Map.fetch!(cached(), code).exponent

  defp cached do
    case :persistent_term.get(__MODULE__, nil) do
      nil ->
        currencies =
          "SELECT code, exponent, name FROM currencies"
          |> DB.all()
          |> Map.new(&{&1.code, &1})

        :persistent_term.put(__MODULE__, currencies)
        currencies

      currencies ->
        currencies
    end
  end
end
