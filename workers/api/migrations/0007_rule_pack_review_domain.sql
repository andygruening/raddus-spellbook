CREATE TABLE IF NOT EXISTS users (
  email TEXT PRIMARY KEY,
  role TEXT NOT NULL DEFAULT 'user' CHECK (role IN ('user', 'admin')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

INSERT OR IGNORE INTO users (email, role, created_at, updated_at)
SELECT owner_email, 'user', MIN(created_at), MAX(updated_at)
FROM spells
GROUP BY owner_email;

CREATE TABLE IF NOT EXISTS rules (
  uid TEXT PRIMARY KEY,
  owner_email TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  archived_at TEXT,
  FOREIGN KEY (owner_email) REFERENCES users(email) ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS rule_versions (
  rule_uid TEXT NOT NULL,
  version INTEGER NOT NULL,
  state TEXT NOT NULL CHECK (
    state IN ('draft', 'submitted_for_review', 'needs_changes', 'approved', 'withdrawn', 'archived')
  ),
  name TEXT NOT NULL,
  description TEXT NOT NULL,
  applies_when TEXT NOT NULL,
  file TEXT NOT NULL,
  body TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  submitted_at TEXT,
  approved_at TEXT,
  reviewed_at TEXT,
  reviewer_email TEXT,
  review_notes TEXT,
  PRIMARY KEY (rule_uid, version),
  FOREIGN KEY (rule_uid) REFERENCES rules(uid) ON DELETE CASCADE,
  FOREIGN KEY (reviewer_email) REFERENCES users(email) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_rule_versions_public_latest
  ON rule_versions (state, approved_at DESC, rule_uid, version DESC);

CREATE INDEX IF NOT EXISTS idx_rule_versions_review
  ON rule_versions (state, submitted_at ASC);

CREATE INDEX IF NOT EXISTS idx_rules_owner_updated
  ON rules (owner_email, updated_at DESC);

INSERT OR IGNORE INTO rules (uid, owner_email, created_at, updated_at)
SELECT id, owner_email, created_at, updated_at
FROM spells;

INSERT OR IGNORE INTO rule_versions (
  rule_uid, version, state, name, description, applies_when, file, body,
  created_at, updated_at, submitted_at, approved_at, reviewed_at, reviewer_email, review_notes
)
SELECT
  spell_versions.spell_id,
  spell_versions.version,
  CASE WHEN spells.published = 1 THEN 'approved' ELSE 'draft' END,
  spell_versions.name,
  spell_versions.description,
  spell_versions.trigger,
  spell_versions.file,
  spell_versions.content,
  spell_versions.created_at,
  spell_versions.created_at,
  CASE WHEN spells.published = 1 THEN spell_versions.created_at ELSE NULL END,
  CASE WHEN spells.published = 1 THEN COALESCE(spells.published_at, spell_versions.created_at) ELSE NULL END,
  CASE WHEN spells.published = 1 THEN COALESCE(spells.published_at, spell_versions.created_at) ELSE NULL END,
  NULL,
  NULL
FROM spell_versions
JOIN spells ON spells.id = spell_versions.spell_id;

CREATE TABLE IF NOT EXISTS rule_stars (
  rule_uid TEXT NOT NULL,
  owner_email TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (rule_uid, owner_email),
  FOREIGN KEY (rule_uid) REFERENCES rules(uid) ON DELETE CASCADE,
  FOREIGN KEY (owner_email) REFERENCES users(email) ON DELETE CASCADE
);

INSERT OR IGNORE INTO rule_stars (rule_uid, owner_email, created_at)
SELECT spell_id, owner_email, created_at
FROM spell_stars;

CREATE INDEX IF NOT EXISTS idx_rule_stars_owner
  ON rule_stars (owner_email, created_at DESC);

CREATE TABLE IF NOT EXISTS packs (
  uid TEXT PRIMARY KEY,
  owner_email TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  archived_at TEXT,
  FOREIGN KEY (owner_email) REFERENCES users(email) ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS pack_versions (
  pack_uid TEXT NOT NULL,
  version INTEGER NOT NULL,
  state TEXT NOT NULL CHECK (
    state IN ('draft', 'submitted_for_review', 'needs_changes', 'approved', 'withdrawn', 'archived')
  ),
  name TEXT NOT NULL,
  description TEXT NOT NULL,
  audience TEXT NOT NULL,
  suggested_workspace_type TEXT NOT NULL,
  compatibility_json TEXT NOT NULL,
  release_notes TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  submitted_at TEXT,
  approved_at TEXT,
  reviewed_at TEXT,
  reviewer_email TEXT,
  review_notes TEXT,
  PRIMARY KEY (pack_uid, version),
  FOREIGN KEY (pack_uid) REFERENCES packs(uid) ON DELETE CASCADE,
  FOREIGN KEY (reviewer_email) REFERENCES users(email) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS pack_version_rules (
  pack_uid TEXT NOT NULL,
  pack_version INTEGER NOT NULL,
  rule_uid TEXT NOT NULL,
  rule_version INTEGER NOT NULL,
  position INTEGER NOT NULL,
  included_draft_rule INTEGER NOT NULL DEFAULT 0 CHECK (included_draft_rule IN (0, 1)),
  PRIMARY KEY (pack_uid, pack_version, rule_uid, rule_version),
  FOREIGN KEY (pack_uid, pack_version) REFERENCES pack_versions(pack_uid, version) ON DELETE CASCADE,
  FOREIGN KEY (rule_uid, rule_version) REFERENCES rule_versions(rule_uid, version) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_pack_versions_public_latest
  ON pack_versions (state, approved_at DESC, pack_uid, version DESC);

CREATE INDEX IF NOT EXISTS idx_pack_versions_review
  ON pack_versions (state, submitted_at ASC);

CREATE INDEX IF NOT EXISTS idx_packs_owner_updated
  ON packs (owner_email, updated_at DESC);

CREATE TABLE IF NOT EXISTS review_events (
  id TEXT PRIMARY KEY,
  artifact_type TEXT NOT NULL CHECK (artifact_type IN ('rule', 'pack')),
  artifact_uid TEXT NOT NULL,
  artifact_version INTEGER NOT NULL,
  action TEXT NOT NULL CHECK (action IN ('submitted', 'approved', 'needs_changes')),
  actor_email TEXT NOT NULL,
  notes TEXT,
  created_at TEXT NOT NULL,
  FOREIGN KEY (actor_email) REFERENCES users(email) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_review_events_artifact
  ON review_events (artifact_type, artifact_uid, artifact_version, created_at DESC);

CREATE TRIGGER IF NOT EXISTS prevent_approved_rule_version_update
BEFORE UPDATE ON rule_versions
FOR EACH ROW
WHEN OLD.state = 'approved'
BEGIN
  SELECT RAISE(ABORT, 'approved rule versions are immutable');
END;

CREATE TRIGGER IF NOT EXISTS prevent_approved_rule_version_delete
BEFORE DELETE ON rule_versions
FOR EACH ROW
WHEN OLD.state = 'approved'
BEGIN
  SELECT RAISE(ABORT, 'approved rule versions are immutable');
END;

CREATE TRIGGER IF NOT EXISTS prevent_approved_pack_version_update
BEFORE UPDATE ON pack_versions
FOR EACH ROW
WHEN OLD.state = 'approved'
BEGIN
  SELECT RAISE(ABORT, 'approved pack versions are immutable');
END;

CREATE TRIGGER IF NOT EXISTS prevent_approved_pack_version_delete
BEFORE DELETE ON pack_versions
FOR EACH ROW
WHEN OLD.state = 'approved'
BEGIN
  SELECT RAISE(ABORT, 'approved pack versions are immutable');
END;
