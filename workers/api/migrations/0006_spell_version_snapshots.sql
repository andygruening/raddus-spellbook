CREATE TABLE IF NOT EXISTS spell_versions (
  spell_id TEXT NOT NULL,
  version INTEGER NOT NULL,
  name TEXT NOT NULL,
  description TEXT NOT NULL,
  trigger TEXT NOT NULL,
  file TEXT NOT NULL,
  content TEXT NOT NULL,
  tags_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (spell_id, version),
  FOREIGN KEY (spell_id) REFERENCES spells(id) ON DELETE CASCADE
);

INSERT OR IGNORE INTO spell_versions (
  spell_id, version, name, description, trigger, file, content, tags_json, created_at
)
SELECT
  id, version, name, description, trigger, file, content, tags_json, updated_at
FROM spells;

CREATE INDEX IF NOT EXISTS idx_spell_versions_spell_version
  ON spell_versions (spell_id, version);
