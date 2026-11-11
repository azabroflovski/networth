defmodule Networth.Web.ErrorMessages do
  @moduledoc """
  English texts for validation error codes. The core returns codes with
  details (`%{code: :too_long, max: 100}`); this is the only place that
  turns them into words. Clients may show their own texts by code.
  """

  def text(:required, _), do: "is required"
  def text(:blank, _), do: "can't be blank"
  def text(:too_long, %{max: max}), do: "is too long (max #{max})"
  def text(:not_string, _), do: "must be a string"
  def text(:not_list, _), do: "must be a list"
  def text(:not_boolean, _), do: "must be a boolean"

  def text(:invalid_choice, %{allowed: allowed}),
    do: "must be one of: #{Enum.join(allowed, ", ")}"

  def text(:invalid_id, _), do: "must be a UUID"
  def text(:invalid_uuid_v7, _), do: "must be a UUIDv7"
  def text(:invalid_date, _), do: "must be an ISO 8601 date"
  def text(:invalid_month, _), do: "must be YYYY-MM"

  def text(:out_of_range, %{min: min, max: max}),
    do: "must be an integer between #{min} and #{max}"

  def text(:invalid_amount, _), do: "must be a decimal string, e.g. \"12.50\""

  def text(:too_many_decimals, %{currency: c, decimals: d}),
    do: "#{c} allows at most #{d} decimal places"

  def text(:not_positive, _), do: "must be greater than zero"
  def text(:negative, _), do: "must not be negative"
  def text(:too_large, _), do: "is too large"
  def text(:unsupported_currency, _), do: "is not a supported currency"
  def text(:invalid_email, _), do: "is not a valid email"

  def text(:invalid_length, %{min: min, max: max}),
    do: "must be #{min} to #{max} characters long"

  def text(:invalid_timezone, _), do: "is not a known IANA time zone"
  def text(:invalid_color, _), do: "must be a hex color like #1a2b3c"
  def text(:invalid_count, %{min: min, max: max}), do: "must contain #{min} to #{max} items"
  def text(:invalid_cursor, _), do: "is invalid"
  def text(:not_found, _), do: "does not exist"
  def text(:archived, _), do: "is archived"
  def text(:already_exists, _), do: "already exists"
  def text(:already_invited, _), do: "already has a pending invitation"
  def text(:already_member, _), do: "is already a member"
  def text(:wrong_kind, %{expected: kind}), do: "must be an #{kind} category"
  def text(:not_top_level, _), do: "must be a top-level category"
  def text(:parent_kind_mismatch, _), do: "must match the parent category"
  def text(:same_account, _), do: "must differ from from_account_id"
  def text(:currency_mismatch, _), do: "has a different currency; use an exchange"
  def text(:same_currency, _), do: "has the same currency; use a transfer"

  def text(:conflicting_fields, %{fields: fields}),
    do: "cannot be combined with #{Enum.join(fields, ", ")}"

  def text(:requires_fee, _), do: "requires a fee"
  def text(:immutable, _), do: "cannot be changed; correct the transaction instead"
  def text(:not_reversible, _), do: "a reversal cannot be reversed"

  def text(:not_correctable, _),
    do: "only expense, income, transfer and exchange can be corrected"

  def text(:before_from, _), do: "must not be before from"
  def text(:confirmation_mismatch, _), do: "must match the workspace name"
  # A code without its own text still gets a readable message rather than a crash.
  def text(code, _), do: code |> to_string() |> String.replace("_", " ")
end
