-- Same mechanism as transactions: a client key against duplicate creation on
-- retry, and a hash of the request to detect reuse of the key with other params.
ALTER TABLE accounts
  ADD COLUMN idempotency_key text CHECK (length(idempotency_key) BETWEEN 1 AND 100),
  ADD COLUMN idempotency_hash bytea,
  ADD CHECK ((idempotency_key IS NULL) = (idempotency_hash IS NULL));

CREATE UNIQUE INDEX accounts_idempotency_key_index ON accounts (workspace_id, idempotency_key);
