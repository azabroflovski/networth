CREATE TABLE users (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  email text NOT NULL CHECK (email = lower(email) AND length(email) BETWEEN 3 AND 254),
  name text NOT NULL CHECK (length(name) BETWEEN 1 AND 100),
  password_hash text NOT NULL,
  inserted_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX users_email_index ON users (email);

-- Only a SHA-256 hash of the bearer token is stored.
CREATE TABLE user_tokens (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  token_hash bytea NOT NULL,
  expires_at timestamptz NOT NULL,
  inserted_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX user_tokens_token_hash_index ON user_tokens (token_hash);
CREATE INDEX user_tokens_user_id_index ON user_tokens (user_id);

-- timezone (IANA name) defines "today" for the workspace: default operation dates
-- and period boundaries. Validated by the application against pg_timezone_names.
CREATE TABLE workspaces (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  name text NOT NULL CHECK (length(name) BETWEEN 1 AND 100),
  timezone text NOT NULL DEFAULT 'UTC',
  inserted_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE workspace_members (
  workspace_id uuid NOT NULL REFERENCES workspaces,
  user_id uuid NOT NULL REFERENCES users,
  role text NOT NULL CHECK (role IN ('owner', 'member')),
  inserted_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workspace_id, user_id)
);

CREATE INDEX workspace_members_user_id_index ON workspace_members (user_id);

-- An invitation is addressed to an email and grants the member role once accepted
-- by the user registered with that email.
CREATE TABLE workspace_invitations (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  workspace_id uuid NOT NULL REFERENCES workspaces,
  email text NOT NULL CHECK (email = lower(email)),
  invited_by uuid NOT NULL REFERENCES users,
  accepted_by uuid REFERENCES users,
  accepted_at timestamptz,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((accepted_by IS NULL) = (accepted_at IS NULL))
);

CREATE UNIQUE INDEX workspace_invitations_pending_index
  ON workspace_invitations (workspace_id, email) WHERE accepted_at IS NULL;
CREATE INDEX workspace_invitations_email_index
  ON workspace_invitations (email) WHERE accepted_at IS NULL;
