defmodule Networth.Params do
  @moduledoc """
  Small helpers for validating external input (string-keyed maps from JSON or
  any other adapter). Each returns `{:ok, value}` or an `invalid/3` error.

  A validation error is a code with optional details, never text:
  `{:error, {:invalid, %{"amount" => %{code: :too_many_decimals, currency: "JPY", decimals: 0}}}}`.
  Interfaces turn codes into messages in the user's language.

  Independent fields are checked together with `all/1`, so a form gets every
  error at once.
  """

  def invalid(field, code, details \\ %{}),
    do: {:error, {:invalid, %{field => Map.put(details, :code, code)}}}

  @doc """
  Combines independent checks: `{:ok, %{name => value}}` when all pass,
  otherwise one error with every field's error.

      Params.all(name: Params.string(params, "name", required: true),
                 type: Params.one_of(params, "type", types, required: true))
  """
  def all(checks) do
    {values, errors} =
      Enum.reduce(checks, {%{}, %{}}, fn
        {key, {:ok, value}}, {values, errors} ->
          {Map.put(values, key, value), errors}

        {_key, {:error, {:invalid, error}}}, {values, errors} ->
          {values, Map.merge(errors, error)}
      end)

    if errors == %{}, do: {:ok, values}, else: {:error, {:invalid, errors}}
  end

  def string(params, key, opts \\ []) do
    max = Keyword.get(opts, :max, 100)

    case Map.get(params, key) do
      nil ->
        if opts[:required], do: invalid(key, :required), else: {:ok, opts[:default]}

      value when is_binary(value) ->
        value = String.trim(value)

        cond do
          value == "" and opts[:required] -> invalid(key, :blank)
          value == "" -> {:ok, opts[:default]}
          String.length(value) > max -> invalid(key, :too_long, %{max: max})
          true -> {:ok, value}
        end

      _ ->
        invalid(key, :not_string)
    end
  end

  def one_of(params, key, allowed, opts \\ []) do
    case Map.get(params, key) do
      nil ->
        if opts[:required], do: invalid(key, :required), else: {:ok, opts[:default]}

      value ->
        if value in allowed,
          do: {:ok, value},
          else: invalid(key, :invalid_choice, %{allowed: allowed})
    end
  end

  def id(params, key, opts \\ []) do
    case Map.get(params, key) do
      nil -> if opts[:required], do: invalid(key, :required), else: {:ok, nil}
      value -> if id = cast_id(value), do: {:ok, id}, else: invalid(key, :invalid_id)
    end
  end

  def ids(params, key) do
    case Map.get(params, key, []) do
      list when is_list(list) ->
        ids = Enum.map(list, &cast_id/1)
        if nil in ids, do: invalid(key, :invalid_id), else: {:ok, Enum.uniq(ids)}

      _ ->
        invalid(key, :not_list)
    end
  end

  def date(params, key, default) do
    with value when is_binary(value) <- Map.get(params, key),
         {:ok, date} <- Date.from_iso8601(value) do
      {:ok, date}
    else
      nil -> {:ok, if(is_function(default, 0), do: default.(), else: default)}
      _ -> invalid(key, :invalid_date)
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
      else: invalid(key, :out_of_range, %{min: min, max: max})
  end

  def boolean(params, key) do
    case Map.get(params, key) do
      value when is_boolean(value) or is_nil(value) -> {:ok, value}
      _ -> invalid(key, :not_boolean)
    end
  end

  @doc "A supported currency code, case-insensitive."
  def currency(params, key) do
    with {:ok, code} <- string(params, key, required: true, max: 3) do
      code = String.upcase(code)

      if Networth.Currencies.get(code),
        do: {:ok, code},
        else: invalid(key, :unsupported_currency)
    end
  end

  @doc "Parses a decimal string amount in major units of `currency` into minor units."
  def amount(params, key, currency, opts \\ []) do
    exponent = Networth.Currencies.exponent!(currency)

    case Map.get(params, key) do
      nil ->
        if opts[:required], do: invalid(key, :required), else: {:ok, nil}

      value ->
        case Networth.Money.parse(value, exponent) do
          {:ok, minor} ->
            if opts[:positive] && minor <= 0,
              do: invalid(key, :not_positive),
              else: {:ok, minor}

          {:error, :too_many_decimals} ->
            invalid(key, :too_many_decimals, %{currency: currency, decimals: exponent})

          {:error, _} ->
            invalid(key, :invalid_amount)
        end
    end
  end

  @doc "Fingerprint of a request, stored with an idempotency key to detect its reuse with other params."
  def request_hash(params),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(params, [:deterministic]))

  @doc "Cast an id from a UUID string; nil if it is not one."
  def cast_id(value), do: Networth.DB.UUID.cast(value)
end
