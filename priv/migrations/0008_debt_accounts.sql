-- Personal debts are accounts with the counterparty as the name:
-- receivable (asset) — money owed to me, payable (liability) — money I owe.
-- Bank credits stay `loan`.
ALTER TABLE accounts DROP CONSTRAINT accounts_type_check;

ALTER TABLE accounts ADD CONSTRAINT accounts_type_check CHECK (type IN (
  'cash', 'bank', 'card', 'deposit', 'savings', 'receivable', 'credit_card', 'loan', 'payable',
  'income', 'expense', 'opening_balance', 'exchange'
));

ALTER TABLE accounts ALTER COLUMN kind SET EXPRESSION AS (
  CASE
    WHEN type IN ('cash', 'bank', 'card', 'deposit', 'savings', 'receivable') THEN 'asset'
    WHEN type IN ('credit_card', 'loan', 'payable') THEN 'liability'
    WHEN type = 'income' THEN 'income'
    WHEN type = 'expense' THEN 'expense'
    ELSE 'equity'
  END
);
