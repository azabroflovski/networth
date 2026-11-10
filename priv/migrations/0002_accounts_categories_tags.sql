-- exponent: number of minor-unit digits (USD 2, JPY 0, KWD 3).
CREATE TABLE currencies (
  code text PRIMARY KEY CHECK (code ~ '^[A-Z]{3}$'),
  exponent smallint NOT NULL CHECK (exponent BETWEEN 0 AND 4),
  name text NOT NULL
);

INSERT INTO currencies (code, exponent, name) VALUES
  ('USD', 2, 'US Dollar'),
  ('EUR', 2, 'Euro'),
  ('GBP', 2, 'Pound Sterling'),
  ('CHF', 2, 'Swiss Franc'),
  ('CNY', 2, 'Yuan Renminbi'),
  ('RUB', 2, 'Russian Ruble'),
  ('UZS', 2, 'Uzbekistan Sum'),
  ('KZT', 2, 'Tenge'),
  ('KGS', 2, 'Som'),
  ('TRY', 2, 'Turkish Lira'),
  ('AED', 2, 'UAE Dirham'),
  ('JPY', 0, 'Yen'),
  ('KRW', 0, 'Won'),
  ('KWD', 3, 'Kuwaiti Dinar'),
  ('BHD', 3, 'Bahraini Dinar');

-- User accounts (cash, bank, ...) hold or owe money. System accounts
-- (income, expense, opening_balance, exchange) are the counterparties that keep
-- every transaction balanced; there is at most one per workspace, type and currency.
CREATE TABLE accounts (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  workspace_id uuid NOT NULL REFERENCES workspaces,
  name text NOT NULL CHECK (length(name) BETWEEN 1 AND 100),
  type text NOT NULL CHECK (type IN (
    'cash', 'bank', 'card', 'deposit', 'savings', 'credit_card', 'loan',
    'income', 'expense', 'opening_balance', 'exchange'
  )),
  kind text NOT NULL GENERATED ALWAYS AS (
    CASE
      WHEN type IN ('cash', 'bank', 'card', 'deposit', 'savings') THEN 'asset'
      WHEN type IN ('credit_card', 'loan') THEN 'liability'
      WHEN type = 'income' THEN 'income'
      WHEN type = 'expense' THEN 'expense'
      ELSE 'equity'
    END
  ) STORED,
  system boolean NOT NULL GENERATED ALWAYS AS (
    type IN ('income', 'expense', 'opening_balance', 'exchange')
  ) STORED,
  currency text NOT NULL REFERENCES currencies,
  archived_at timestamptz,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, id, currency),
  UNIQUE (workspace_id, id, currency, kind)
);

CREATE INDEX accounts_workspace_id_index ON accounts (workspace_id);
CREATE UNIQUE INDEX accounts_system_index ON accounts (workspace_id, type, currency) WHERE system;
CREATE UNIQUE INDEX accounts_name_index
  ON accounts (workspace_id, lower(name)) WHERE NOT system AND archived_at IS NULL;

CREATE FUNCTION accounts_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (NEW.workspace_id, NEW.type, NEW.currency) IS DISTINCT FROM (OLD.workspace_id, OLD.type, OLD.currency) THEN
    RAISE EXCEPTION 'account workspace, type and currency are immutable' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER accounts_guard BEFORE UPDATE ON accounts
  FOR EACH ROW EXECUTE FUNCTION accounts_guard();

-- Two levels at most: a category or a subcategory of a top-level category.
-- A subcategory has the same kind as its parent (enforced by the composite FK).
CREATE TABLE categories (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  workspace_id uuid NOT NULL REFERENCES workspaces,
  parent_id uuid,
  kind text NOT NULL CHECK (kind IN ('expense', 'income')),
  name text NOT NULL CHECK (length(name) BETWEEN 1 AND 100),
  system boolean NOT NULL DEFAULT false,
  archived_at timestamptz,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, id, kind),
  FOREIGN KEY (workspace_id, parent_id, kind) REFERENCES categories (workspace_id, id, kind)
);

CREATE INDEX categories_workspace_id_index ON categories (workspace_id);
CREATE UNIQUE INDEX categories_name_index
  ON categories (workspace_id, kind, parent_id, lower(name)) NULLS NOT DISTINCT;

CREATE FUNCTION categories_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND (NEW.workspace_id, NEW.kind, NEW.parent_id) IS DISTINCT FROM (OLD.workspace_id, OLD.kind, OLD.parent_id) THEN
    RAISE EXCEPTION 'category workspace, kind and parent are immutable' USING ERRCODE = 'check_violation';
  END IF;

  IF TG_OP = 'INSERT' AND NEW.parent_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM categories WHERE id = NEW.parent_id AND parent_id IS NOT NULL) THEN
    RAISE EXCEPTION 'categories can be nested one level deep' USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END $$;

CREATE TRIGGER categories_guard BEFORE INSERT OR UPDATE ON categories
  FOR EACH ROW EXECUTE FUNCTION categories_guard();

CREATE TABLE tags (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  workspace_id uuid NOT NULL REFERENCES workspaces,
  name text NOT NULL CHECK (length(name) BETWEEN 1 AND 50),
  color text CHECK (color ~ '^#[0-9a-f]{6}$'),
  inserted_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, id)
);

CREATE UNIQUE INDEX tags_name_index ON tags (workspace_id, lower(name));
