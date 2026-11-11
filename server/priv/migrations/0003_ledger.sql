-- Append-only rows. DELETE is allowed only while purging their workspace: the
-- purge sets the transaction-local networth.purge_workspace to its id.
CREATE FUNCTION forbid_change() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' AND OLD.workspace_id::text = current_setting('networth.purge_workspace', true) THEN
    RETURN OLD;
  END IF;

  RAISE EXCEPTION '% is append-only', TG_TABLE_NAME USING ERRCODE = 'check_violation';
END $$;

-- A transaction is the user-level financial operation. Its money movement lives
-- in ledger_entries. Both are append-only, except the description of a
-- transaction (see transactions_guard); corrections are reversals.
--   reverses_id      set on a reversal: the transaction it cancels
--   replaces_id      set on a correction: the transaction it replaces (which
--                    is reversed in the same database transaction)
--   idempotency_key  client key against duplicate posting; idempotency_hash
--                    detects reuse of a key with different parameters
CREATE TABLE transactions (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  workspace_id uuid NOT NULL REFERENCES workspaces,
  type text NOT NULL CHECK (type IN (
    'expense', 'income', 'transfer', 'exchange', 'opening_balance', 'adjustment', 'reversal'
  )),
  occurred_on date NOT NULL,
  description text CHECK (length(description) <= 500),
  reverses_id uuid,
  replaces_id uuid,
  idempotency_key text CHECK (length(idempotency_key) BETWEEN 1 AND 100),
  idempotency_hash bytea,
  created_by uuid NOT NULL REFERENCES users,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, id),
  FOREIGN KEY (workspace_id, reverses_id) REFERENCES transactions (workspace_id, id),
  FOREIGN KEY (workspace_id, replaces_id) REFERENCES transactions (workspace_id, id),
  CHECK ((type = 'reversal') = (reverses_id IS NOT NULL)),
  CONSTRAINT transactions_replaces_check
    CHECK (replaces_id IS NULL OR type IN ('expense', 'income', 'transfer', 'exchange')),
  CHECK ((idempotency_key IS NULL) = (idempotency_hash IS NULL))
);

CREATE INDEX transactions_workspace_occurred_on_index ON transactions (workspace_id, occurred_on DESC, id DESC);
CREATE UNIQUE INDEX transactions_reverses_id_index ON transactions (reverses_id);
CREATE UNIQUE INDEX transactions_replaces_id_index ON transactions (replaces_id);
CREATE UNIQUE INDEX transactions_idempotency_key_index ON transactions (workspace_id, idempotency_key);

-- Only the description of a transaction may change, and every change is
-- recorded in the activity log with its author, taken from the
-- transaction-local networth.user_id that the application sets. Comparing the
-- rows without description keeps any future column immutable as well.
CREATE FUNCTION transactions_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  author text := current_setting('networth.user_id', true);
BEGIN
  IF TG_OP = 'DELETE' AND OLD.workspace_id::text = current_setting('networth.purge_workspace', true) THEN
    RETURN OLD;
  END IF;

  IF TG_OP = 'DELETE' OR (to_jsonb(NEW) - 'description') IS DISTINCT FROM (to_jsonb(OLD) - 'description') THEN
    RAISE EXCEPTION 'transactions are append-only except description' USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.description IS DISTINCT FROM OLD.description THEN
    IF author IS NULL OR author = '' THEN
      RAISE EXCEPTION 'changing a transaction requires networth.user_id' USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO activity_log (workspace_id, actor_id, action, subject_type, subject_id, changes)
    VALUES (NEW.workspace_id, author::uuid, 'transaction.description_changed', 'transaction', NEW.id,
            jsonb_build_object('description', jsonb_build_array(OLD.description, NEW.description)));
  END IF;

  RETURN NEW;
END $$;

CREATE TRIGGER transactions_guard BEFORE UPDATE OR DELETE ON transactions
  FOR EACH ROW EXECUTE FUNCTION transactions_guard();

-- amount is in minor units of the account currency: positive = debit, negative = credit.
-- Categories live on entries of income/expense accounts, so one operation can be
-- split across several categories. account_kind copies the account's kind (checked
-- by the FK) and makes the category FK reject categories on other accounts and
-- categories of the wrong kind.
CREATE TABLE ledger_entries (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  workspace_id uuid NOT NULL,
  transaction_id uuid NOT NULL,
  account_id uuid NOT NULL,
  currency text NOT NULL,
  account_kind text NOT NULL,
  amount bigint NOT NULL CHECK (amount <> 0),
  category_id uuid,
  FOREIGN KEY (workspace_id, transaction_id) REFERENCES transactions (workspace_id, id),
  FOREIGN KEY (workspace_id, account_id, currency, account_kind)
    REFERENCES accounts (workspace_id, id, currency, kind),
  FOREIGN KEY (workspace_id, category_id, account_kind) REFERENCES categories (workspace_id, id, kind)
);

CREATE INDEX ledger_entries_transaction_id_index ON ledger_entries (transaction_id);
CREATE INDEX ledger_entries_account_id_index ON ledger_entries (account_id) INCLUDE (amount);
CREATE INDEX ledger_entries_category_id_index ON ledger_entries (category_id) WHERE category_id IS NOT NULL;

CREATE TRIGGER ledger_entries_append_only BEFORE UPDATE OR DELETE ON ledger_entries
  FOR EACH ROW EXECUTE FUNCTION forbid_change();

-- Details of a currency exchange as the user entered them.
-- rate = to_amount / from_amount in major units. fee_amount is charged in the
-- source currency on top of from_amount and posted as an expense line.
CREATE TABLE exchanges (
  transaction_id uuid PRIMARY KEY,
  workspace_id uuid NOT NULL,
  from_account_id uuid NOT NULL,
  from_amount bigint NOT NULL CHECK (from_amount > 0),
  from_currency text NOT NULL,
  to_account_id uuid NOT NULL,
  to_amount bigint NOT NULL CHECK (to_amount > 0),
  to_currency text NOT NULL,
  rate numeric NOT NULL CHECK (rate > 0),
  fee_amount bigint NOT NULL DEFAULT 0 CHECK (fee_amount >= 0),
  FOREIGN KEY (workspace_id, transaction_id) REFERENCES transactions (workspace_id, id),
  FOREIGN KEY (workspace_id, from_account_id, from_currency) REFERENCES accounts (workspace_id, id, currency),
  FOREIGN KEY (workspace_id, to_account_id, to_currency) REFERENCES accounts (workspace_id, id, currency),
  CHECK (from_currency <> to_currency)
);

CREATE TRIGGER exchanges_append_only BEFORE UPDATE OR DELETE ON exchanges
  FOR EACH ROW EXECUTE FUNCTION forbid_change();

-- Tags classify a whole transaction and never affect the ledger, so they may change.
CREATE TABLE transaction_tags (
  workspace_id uuid NOT NULL,
  transaction_id uuid NOT NULL,
  tag_id uuid NOT NULL,
  PRIMARY KEY (transaction_id, tag_id),
  FOREIGN KEY (workspace_id, transaction_id) REFERENCES transactions (workspace_id, id),
  FOREIGN KEY (workspace_id, tag_id) REFERENCES tags (workspace_id, id) ON DELETE CASCADE
);

CREATE INDEX transaction_tags_tag_id_index ON transaction_tags (tag_id);

-- Checked at commit: every transaction has at least two entries and its
-- debits equal its credits in each currency.
CREATE FUNCTION check_transaction_balanced() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  tx_id uuid;
BEGIN
  IF TG_TABLE_NAME = 'transactions' THEN
    tx_id := NEW.id;
  ELSE
    tx_id := NEW.transaction_id;
  END IF;

  IF (SELECT count(*) FROM ledger_entries WHERE transaction_id = tx_id) < 2 THEN
    RAISE EXCEPTION 'transaction % has fewer than two ledger entries', tx_id
      USING ERRCODE = 'check_violation', CONSTRAINT = 'transaction_balanced';
  END IF;

  IF EXISTS (
    SELECT 1 FROM ledger_entries WHERE transaction_id = tx_id
    GROUP BY currency HAVING sum(amount) <> 0
  ) THEN
    RAISE EXCEPTION 'transaction % is not balanced', tx_id
      USING ERRCODE = 'check_violation', CONSTRAINT = 'transaction_balanced';
  END IF;

  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER transactions_balanced AFTER INSERT ON transactions
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION check_transaction_balanced();
CREATE CONSTRAINT TRIGGER ledger_entries_balanced AFTER INSERT ON ledger_entries
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION check_transaction_balanced();
