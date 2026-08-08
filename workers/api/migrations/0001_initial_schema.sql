CREATE TABLE IF NOT EXISTS otp_challenges (
  id TEXT PRIMARY KEY,
  email TEXT NOT NULL,
  code_hash TEXT NOT NULL,
  salt TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  consumed_at TEXT,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_otp_email_created
  ON otp_challenges (email, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_otp_expires
  ON otp_challenges (expires_at);

CREATE TABLE IF NOT EXISTS spells (
  id TEXT PRIMARY KEY,
  local_id TEXT NOT NULL,
  title TEXT NOT NULL,
  role TEXT NOT NULL,
  category TEXT NOT NULL,
  requirement TEXT NOT NULL,
  trigger TEXT NOT NULL,
  safe_path TEXT NOT NULL,
  source_agent TEXT NOT NULL,
  tags_json TEXT NOT NULL,
  owner_email TEXT NOT NULL,
  published INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  published_at TEXT NOT NULL,
  UNIQUE(owner_email, local_id)
);

CREATE INDEX IF NOT EXISTS idx_spells_public_updated
  ON spells (published, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_spells_owner_updated
  ON spells (owner_email, updated_at DESC);
