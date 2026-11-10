-- Every workspace keeps at least one owner. Checked at commit; the workspace
-- row is locked first so that two concurrent changes (two owners leaving at
-- once) are serialized and the second one sees the first.
CREATE FUNCTION check_workspace_has_owner() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM workspaces WHERE id = OLD.workspace_id FOR UPDATE;

  IF FOUND AND NOT EXISTS (
    SELECT 1 FROM workspace_members WHERE workspace_id = OLD.workspace_id AND role = 'owner'
  ) THEN
    RAISE EXCEPTION 'workspace % must keep at least one owner', OLD.workspace_id
      USING ERRCODE = 'check_violation', CONSTRAINT = 'workspace_has_owner';
  END IF;

  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER workspace_members_has_owner AFTER UPDATE OR DELETE ON workspace_members
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION check_workspace_has_owner();
