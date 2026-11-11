defmodule Networth.Budgets.Budget do
  @moduledoc """
  A monthly limit for an expense category in one currency, in effect from
  `starts_on` until a later limit; `amount` 0 ends the budget.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          workspace_id: String.t(),
          category_id: String.t(),
          category_kind: String.t(),
          currency: String.t(),
          starts_on: Date.t(),
          amount: non_neg_integer(),
          updated_by: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  defstruct [
    :id,
    :workspace_id,
    :category_id,
    :category_kind,
    :currency,
    :starts_on,
    :amount,
    :updated_by,
    :inserted_at,
    :updated_at
  ]
end
