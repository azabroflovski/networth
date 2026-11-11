defmodule Networth.Ledger.Transaction do
  @moduledoc """
  A financial operation as the user sees it, with its ledger entries.

  `reverses_id` is set on a reversal, `reversed_by_id` on a reversed
  operation, `replaces_id` on a correction. `exchange` holds the details of
  a currency exchange, nil for other types.
  """

  alias Networth.Ledger.{Entry, Exchange}

  @type t :: %__MODULE__{
          id: String.t(),
          workspace_id: String.t(),
          type: String.t(),
          occurred_on: Date.t(),
          description: String.t() | nil,
          reverses_id: String.t() | nil,
          reversed_by_id: String.t() | nil,
          replaces_id: String.t() | nil,
          idempotency_key: String.t() | nil,
          created_by: String.t(),
          inserted_at: DateTime.t(),
          entries: [Entry.t()],
          tag_ids: [String.t()],
          exchange: Exchange.t() | nil
        }

  defstruct [
    :id,
    :workspace_id,
    :type,
    :occurred_on,
    :description,
    :reverses_id,
    :reversed_by_id,
    :replaces_id,
    :idempotency_key,
    :created_by,
    :inserted_at,
    :exchange,
    entries: [],
    tag_ids: []
  ]
end
