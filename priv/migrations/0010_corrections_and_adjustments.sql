-- Corrections: a transaction may replace an earlier one, which is reversed in
-- the same database transaction. Each transaction is replaced at most once.
ALTER TABLE transactions
  ADD COLUMN replaces_id uuid,
  ADD FOREIGN KEY (workspace_id, replaces_id) REFERENCES transactions (workspace_id, id),
  ADD CONSTRAINT transactions_replaces_check
    CHECK (replaces_id IS NULL OR type IN ('expense', 'income', 'transfer', 'exchange'));

CREATE UNIQUE INDEX transactions_replaces_id_index ON transactions (replaces_id);

-- Balance adjustments: the difference between the recorded and the actual
-- balance, booked against a per-currency `adjustment` equity account.
ALTER TABLE transactions DROP CONSTRAINT transactions_type_check;
ALTER TABLE transactions ADD CONSTRAINT transactions_type_check CHECK (type IN (
  'expense', 'income', 'transfer', 'exchange', 'opening_balance', 'adjustment', 'reversal'
));

ALTER TABLE accounts DROP CONSTRAINT accounts_type_check;
ALTER TABLE accounts ADD CONSTRAINT accounts_type_check CHECK (type IN (
  'cash', 'bank', 'card', 'deposit', 'savings', 'receivable', 'credit_card', 'loan', 'payable',
  'income', 'expense', 'opening_balance', 'exchange', 'adjustment'
));

ALTER TABLE accounts ALTER COLUMN system SET EXPRESSION AS (
  type IN ('income', 'expense', 'opening_balance', 'exchange', 'adjustment')
);
