-- A workspace is deleted by its owner with a delay: deletion_scheduled_at is
-- set, and a periodic job purges it once that moment has passed.
ALTER TABLE workspaces ADD COLUMN deletion_scheduled_at timestamptz;

CREATE INDEX workspaces_deletion_scheduled_at_index
  ON workspaces (deletion_scheduled_at) WHERE deletion_scheduled_at IS NOT NULL;

-- Append-only tables allow DELETE only while purging their workspace: the
-- purge sets the transaction-local networth.purge_workspace to its id.
CREATE OR REPLACE FUNCTION forbid_change() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' AND OLD.workspace_id::text = current_setting('networth.purge_workspace', true) THEN
    RETURN OLD;
  END IF;

  RAISE EXCEPTION '% is append-only', TG_TABLE_NAME USING ERRCODE = 'check_violation';
END $$;

CREATE OR REPLACE FUNCTION transactions_guard() RETURNS trigger LANGUAGE plpgsql AS $$
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

    INSERT INTO transaction_changes (workspace_id, transaction_id, field, old_value, new_value, changed_by)
    VALUES (NEW.workspace_id, NEW.id, 'description', OLD.description, NEW.description, author::uuid);
  END IF;

  RETURN NEW;
END $$;
