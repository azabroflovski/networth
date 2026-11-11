-- Workspace activity log: who did what to which object, written in the same
-- database transaction as the change itself. Replaces transaction_changes,
-- which only covered description edits.
--   action       resource.verb, e.g. account.updated, transaction.posted
--   changes      {field: [old, new]} for updates
--   data         snapshot for rendering the event without loading the subject
CREATE TABLE activity_log (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  workspace_id uuid NOT NULL REFERENCES workspaces,
  actor_id uuid NOT NULL REFERENCES users,
  action text NOT NULL CHECK (action ~ '^[a-z_]+\.[a-z_]+$'),
  subject_type text NOT NULL,
  subject_id uuid,
  changes jsonb NOT NULL DEFAULT '{}',
  data jsonb NOT NULL DEFAULT '{}',
  inserted_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX activity_log_workspace_id_index ON activity_log (workspace_id, id DESC);
CREATE INDEX activity_log_subject_id_index ON activity_log (subject_id) WHERE subject_id IS NOT NULL;

CREATE TRIGGER activity_log_append_only BEFORE UPDATE OR DELETE ON activity_log
  FOR EACH ROW EXECUTE FUNCTION forbid_change();

INSERT INTO activity_log (id, workspace_id, actor_id, action, subject_type, subject_id, changes, inserted_at)
SELECT id, workspace_id, changed_by, 'transaction.description_changed', 'transaction', transaction_id,
       jsonb_build_object('description', jsonb_build_array(old_value, new_value)), inserted_at
FROM transaction_changes;

-- Description edits are still recorded by the database, now into the shared log.
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

    INSERT INTO activity_log (workspace_id, actor_id, action, subject_type, subject_id, changes)
    VALUES (NEW.workspace_id, author::uuid, 'transaction.description_changed', 'transaction', NEW.id,
            jsonb_build_object('description', jsonb_build_array(OLD.description, NEW.description)));
  END IF;

  RETURN NEW;
END $$;

DROP TABLE transaction_changes;
