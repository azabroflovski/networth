-- Monthly spending limit for an expense category in one currency, effective
-- from starts_on (first day of a month) until a row with a later starts_on.
-- amount 0 ends the budget. Budgets are plans, not ledger data, so rows are
-- updated in place.
CREATE TABLE budgets (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  workspace_id uuid NOT NULL REFERENCES workspaces,
  category_id uuid NOT NULL,
  category_kind text NOT NULL DEFAULT 'expense' CHECK (category_kind = 'expense'),
  currency text NOT NULL REFERENCES currencies,
  starts_on date NOT NULL CHECK (extract(day FROM starts_on) = 1),
  amount bigint NOT NULL CHECK (amount >= 0),
  updated_by uuid NOT NULL REFERENCES users,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (workspace_id, category_id, category_kind) REFERENCES categories (workspace_id, id, kind),
  UNIQUE (workspace_id, category_id, currency, starts_on)
);
