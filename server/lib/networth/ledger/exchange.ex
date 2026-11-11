defmodule Networth.Ledger.Exchange do
  @moduledoc """
  Details of a currency exchange as the user entered them. Amounts are minor
  units; `rate` is to/from in major units; `fee_amount` is in the source
  currency, on top of `from_amount`.
  """

  @type t :: %__MODULE__{
          from_account_id: String.t(),
          from_amount: pos_integer(),
          from_currency: String.t(),
          to_account_id: String.t(),
          to_amount: pos_integer(),
          to_currency: String.t(),
          rate: Decimal.t(),
          fee_amount: non_neg_integer()
        }

  defstruct [
    :from_account_id,
    :from_amount,
    :from_currency,
    :to_account_id,
    :to_amount,
    :to_currency,
    :rate,
    :fee_amount
  ]
end
