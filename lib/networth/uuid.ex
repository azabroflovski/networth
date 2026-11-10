defmodule Networth.UUID do
  @moduledoc """
  UUIDs are canonical lowercase strings everywhere in the application.

  Also a Postgrex extension for the `uuid` type (registered in
  `Networth.PostgresTypes`): it converts between strings and the 16-byte wire
  format, so no other code deals with the binary form.
  """

  @behaviour Postgrex.Extension

  @doc "Normalizes a UUID string to canonical lowercase form, or returns nil."
  def cast(<<_::binary-36>> = value) do
    value = String.downcase(value)

    case dump(value) do
      {:ok, _} -> value
      :error -> nil
    end
  end

  def cast(_value), do: nil

  def dump(<<a::binary-8, ?-, b::binary-4, ?-, c::binary-4, ?-, d::binary-4, ?-, e::binary-12>>) do
    Base.decode16(a <> b <> c <> d <> e, case: :mixed)
  end

  def dump(_value), do: :error

  def load(<<a::binary-4, b::binary-2, c::binary-2, d::binary-2, e::binary-6>>) do
    [a, b, c, d, e] |> Enum.map(&Base.encode16(&1, case: :lower)) |> Enum.join("-")
  end

  @impl true
  def init(_opts), do: nil

  @impl true
  def matching(_state), do: [send: "uuid_send"]

  @impl true
  def format(_state), do: :binary

  @impl true
  def encode(_state) do
    quote location: :keep do
      uuid when is_binary(uuid) ->
        case Networth.UUID.dump(uuid) do
          {:ok, bin} ->
            [<<16::signed-size(32)>> | bin]

          :error ->
            raise DBConnection.EncodeError, "expected a UUID string, got: #{inspect(uuid)}"
        end
    end
  end

  @impl true
  def decode(_state) do
    quote location: :keep do
      <<16::signed-size(32), uuid::binary-16>> -> Networth.UUID.load(uuid)
    end
  end
end
