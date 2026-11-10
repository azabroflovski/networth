-- Fee charged on an exchange, in the source account's currency (from_currency),
-- on top of from_amount. It is posted as an expense line of the same transaction.
ALTER TABLE exchanges ADD COLUMN fee_amount bigint NOT NULL DEFAULT 0 CHECK (fee_amount >= 0);
