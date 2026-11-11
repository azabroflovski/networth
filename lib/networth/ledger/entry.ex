defmodule Networth.Ledger.Entry do
  @moduledoc """
  A ledger entry of a transaction as read back: amount in minor units of
  the account currency, positive = debit. `category_id` is set on lines of
  income and expense accounts.
  """

  @type t :: %__MODULE__{
          account_id: String.t(),
          account_name: String.t(),
          account_type: String.t(),
          currency: String.t(),
          amount: integer(),
          category_id: String.t() | nil
        }

  defstruct [:account_id, :account_name, :account_type, :currency, :amount, :category_id]
end
