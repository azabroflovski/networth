defmodule Networth.Ledger do
  @moduledoc """
  Double-entry ledger: posting financial operations, correcting them and
  reading their history. This module is the public API; the work is done by
  the modules in `ledger/`.

  A transaction is one user-level operation (an expense, a transfer, ...).
  Posting it writes balanced ledger entries: in every currency the debits
  (positive amounts) equal the credits (negative amounts). Transactions and
  entries are never updated or deleted; a mistake is corrected by reversing
  the transaction and posting a new one.

  Categories are carried by the entries on income/expense accounts, one entry
  per line, so an expense can be split across several categories.

  `post/2` is the single entry point for creating operations from any input
  channel (HTTP today, other adapters later). It accepts string-keyed params
  with amounts as decimal strings in major units.
  """

  alias Networth.Ledger.{Adjustment, Correction, Editing, History, Posting, Reversal}

  @doc """
  Posts a new operation. Params by type:

    * expense / income: account_id and either amount + category_id (optional)
      or lines: [%{"amount" => ..., "category_id" => ...}, ...] for a split
    * transfer: from_account_id, to_account_id, amount (same currency)
    * exchange: from_account_id, from_amount, to_account_id, to_amount,
      optional fee (source currency, taken on top of from_amount) and
      fee_category_id

  Common: occurred_on (ISO date, default today in the workspace timezone),
  description, tag_ids, idempotency_key, and id (a client-generated UUIDv7;
  `{:error, :id_taken}` if it already exists).

  Repeating a request with the same idempotency_key returns the originally
  posted transaction; reusing the key with different params returns
  `{:error, :idempotency_key_reused}`.
  """
  defdelegate post(scope, params), to: Posting

  @doc false
  # Used by Accounts.create/2. `amount` is in the account's natural sign.
  defdelegate post_opening_balance(scope, account, amount, occurred_on), to: Posting

  @doc """
  Reverses a posted transaction: posts a `reversal` transaction with every
  entry (including its category) negated, dated like the original unless
  occurred_on is given.

  Reversing an already reversed transaction returns the existing reversal,
  so a retried request is harmless. Reversals themselves cannot be reversed
  (post the operation again instead).
  """
  defdelegate reverse(scope, id, params \\ %{}), to: Reversal

  @doc """
  Corrects a posted operation: reverses it and posts the new version in one
  database transaction. The new transaction's `replaces_id` points to the
  original. Params are those of `post/2`; occurred_on, description and
  tag_ids default to the original's.

  The original must be an expense, income, transfer or exchange that is not
  reversed yet (`{:error, :already_reversed}` otherwise). With an
  idempotency_key a retried correction returns the posted one.
  """
  defdelegate correct(scope, id, params), to: Correction

  @doc """
  Reconciles an account with its real balance: posts an `adjustment` for the
  difference between `balance` (natural sign, decimal string) and the
  recorded balance at the end of `occurred_on` (default today in the
  workspace timezone). The difference goes to an equity account, so it does
  not appear as income or expense. Returns `{:ok, nil}` when the balances
  already match, so repeating a request posts nothing.
  """
  defdelegate adjust_balance(scope, account_id, params), to: Adjustment

  @doc """
  Edits a posted transaction. Only the description can change, and the
  database records every change in the activity log. Amounts, accounts,
  categories and dates are changed by `correct/3`.
  """
  defdelegate update(scope, id, params), to: Editing

  @doc "Replaces the tags of a transaction. Tags are not part of the ledger."
  defdelegate set_tags(scope, id, params), to: Editing

  @doc "A transaction with its entries, tag ids and exchange details."
  defdelegate get(scope, id), to: History

  @doc """
  Lists transactions, newest first (by occurred_on, then id). Reversed
  transactions and their reversals (deleted or corrected operations) are
  hidden unless `include_reversed` is true. Filters: account_id,
  category_id (any line in it or its subcategories), tag_id, type, from, to.
  Paginated by `limit` and `cursor`: pass the returned `next_cursor` to get
  the next page; it is nil on the last page.
  """
  defdelegate list(scope, params \\ %{}), to: History
end
