defmodule Networth.Accounts.Account do
  @moduledoc """
  A financial account. `kind` follows from `type` (asset, liability, or a
  system kind). `balance` is computed from ledger entries, in minor units and
  in the account's natural sign; it is nil where an account is loaded for
  posting rather than for display.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          workspace_id: String.t() | nil,
          name: String.t(),
          type: String.t(),
          kind: String.t(),
          currency: String.t(),
          archived_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          balance: integer() | nil
        }

  defstruct [
    :id,
    :workspace_id,
    :name,
    :type,
    :kind,
    :currency,
    :archived_at,
    :inserted_at,
    :balance
  ]
end
