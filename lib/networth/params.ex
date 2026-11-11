defmodule Networth.Params do
  @moduledoc """
  Small helpers for validating external input (string-keyed maps from JSON or
  any other adapter). Each returns `{:ok, value}` or an `invalid/2` error.
  """

  def invalid(field, message), do: {:error, {:invalid, %{field => message}}}

  def string(params, key, opts \\ []) do
    max = Keyword.get(opts, :max, 100)

    case Map.get(params, key) do
      nil ->
        if opts[:required], do: invalid(key, "is required"), else: {:ok, opts[:default]}

      value when is_binary(value) ->
        value = String.trim(value)

        cond do
          value == "" and opts[:required] -> invalid(key, "can't be blank")
          value == "" -> {:ok, opts[:default]}
          String.length(value) > max -> invalid(key, "is too long (max #{max})")
          true -> {:ok, value}
        end

      _ ->
        invalid(key, "must be a string")
    end
  end

  def one_of(params, key, allowed, opts \\ []) do
    case Map.get(params, key) do
      nil -> if opts[:required], do: invalid(key, "is required"), else: {:ok, opts[:default]}
      value -> if value in allowed, do: {:ok, value}, else: invalid(key, "is invalid")
    end
  end

  def id(params, key, opts \\ []) do
    case Map.get(params, key) do
      nil -> if opts[:required], do: invalid(key, "is required"), else: {:ok, nil}
      value -> if id = cast_id(value), do: {:ok, id}, else: invalid(key, "is invalid")
    end
  end

  def ids(params, key) do
    case Map.get(params, key, []) do
      list when is_list(list) ->
        ids = Enum.map(list, &cast_id/1)
        if nil in ids, do: invalid(key, "is invalid"), else: {:ok, Enum.uniq(ids)}

      _ ->
        invalid(key, "must be a list")
    end
  end

  def date(params, key, default) do
    case Map.get(params, key) do
      nil ->
        {:ok, if(is_function(default, 0), do: default.(), else: default)}

      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _} -> invalid(key, "must be an ISO 8601 date")
        end

      _ ->
        invalid(key, "must be an ISO 8601 date")
    end
  end

  def integer(params, key, default, min, max) do
    value =
      case Map.get(params, key) do
        nil -> default
        v when is_integer(v) -> v
        v when is_binary(v) -> with {i, ""} <- Integer.parse(v), do: i, else: (_ -> nil)
        _ -> nil
      end

    if is_integer(value) and value >= min and value <= max,
      do: {:ok, value},
      else: invalid(key, "must be an integer between #{min} and #{max}")
  end

  def boolean(params, key) do
    case Map.get(params, key) do
      value when is_boolean(value) or is_nil(value) -> {:ok, value}
      _ -> invalid(key, "must be a boolean")
    end
  end

  @doc "A supported currency code, case-insensitive."
  def currency(params, key) do
    with {:ok, code} <- string(params, key, required: true, max: 3) do
      code = String.upcase(code)

      if Networth.Currencies.get(code),
        do: {:ok, code},
        else: invalid(key, "is not supported")
    end
  end

  @doc "Parses a decimal string amount in major units of `currency` into minor units."
  def amount(params, key, currency, opts \\ []) do
    exponent = Networth.Currencies.exponent!(currency)

    case Map.get(params, key) do
      nil ->
        if opts[:required], do: invalid(key, "is required"), else: {:ok, nil}

      value ->
        case Networth.Money.parse(value, exponent) do
          {:ok, minor} ->
            if opts[:positive] && minor <= 0,
              do: invalid(key, "must be greater than zero"),
              else: {:ok, minor}

          {:error, :too_many_decimals} ->
            invalid(key, "#{currency} allows at most #{exponent} decimal places")

          {:error, _} ->
            invalid(key, "must be a decimal string, e.g. \"12.50\"")
        end
    end
  end

  @doc "Fingerprint of a request, stored with an idempotency key to detect its reuse with other params."
  def request_hash(params),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(params, [:deterministic]))

  @doc "Cast an id from a UUID string; nil if it is not one."
  def cast_id(value), do: Networth.DB.UUID.cast(value)
end
