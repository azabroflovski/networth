-- The description of a posted transaction may be edited; every edit is
-- recorded here by a trigger, so it cannot happen without a trace.
CREATE TABLE transaction_changes (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  workspace_id uuid NOT NULL,
  transaction_id uuid NOT NULL,
  field text NOT NULL CHECK (field IN ('description')),
  old_value text,
  new_value text,
  changed_by uuid NOT NULL REFERENCES users,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (workspace_id, transaction_id) REFERENCES transactions (workspace_id, id)
);

CREATE INDEX transaction_changes_transaction_id_index ON transaction_changes (transaction_id);

CREATE TRIGGER transaction_changes_append_only BEFORE UPDATE OR DELETE ON transaction_changes
  FOR EACH ROW EXECUTE FUNCTION forbid_change();

-- Replaces the blanket append-only trigger on transactions: everything except
-- the description stays immutable. The author of an edit is taken from the
-- transaction-local setting networth.user_id, which the application sets.
CREATE FUNCTION transactions_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  author text := current_setting('networth.user_id', true);
BEGIN
  IF TG_OP = 'DELETE' OR (to_jsonb(NEW) - 'description') IS DISTINCT FROM (to_jsonb(OLD) - 'description') THEN
    RAISE EXCEPTION 'transactions are append-only except description' USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.description IS DISTINCT FROM OLD.description THEN
    IF author IS NULL OR author = '' THEN
      RAISE EXCEPTION 'changing a transaction requires networth.user_id' USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO transaction_changes (workspace_id, transaction_id, field, old_value, new_value, changed_by)
    VALUES (NEW.workspace_id, NEW.id, 'description', OLD.description, NEW.description, author::uuid);
  END IF;

  RETURN NEW;
END $$;

DROP TRIGGER transactions_append_only ON transactions;

CREATE TRIGGER transactions_guard BEFORE UPDATE OR DELETE ON transactions
  FOR EACH ROW EXECUTE FUNCTION transactions_guard();
