CREATE TABLE IF NOT EXISTS spell_stars (
  spell_id TEXT NOT NULL,
  owner_email TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (spell_id, owner_email),
  FOREIGN KEY (spell_id) REFERENCES spells(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_spell_stars_owner
  ON spell_stars (owner_email, created_at DESC);
