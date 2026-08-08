CREATE TABLE IF NOT EXISTS spells_new (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT NOT NULL,
  file TEXT NOT NULL,
  content TEXT NOT NULL,
  tags_json TEXT NOT NULL,
  owner_email TEXT NOT NULL,
  published INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  published_at TEXT NOT NULL
);

INSERT INTO spells_new (
  id, name, description, file, content, tags_json, owner_email,
  published, created_at, updated_at, published_at
)
SELECT
  id,
  COALESCE(NULLIF(title, ''), 'Untitled spell'),
  COALESCE(NULLIF(requirement, ''), 'Reusable review instruction.'),
  'spells/' || LOWER(REPLACE(REPLACE(COALESCE(NULLIF(local_id, ''), id), ' ', '-'), '/', '-')) || '.md',
  '# ' || COALESCE(NULLIF(title, ''), 'Untitled spell') || CHAR(10) || CHAR(10) ||
    CASE
      WHEN COALESCE(NULLIF(role, ''), '') <> '' THEN '**Role:** ' || role || CHAR(10) || CHAR(10)
      ELSE ''
    END ||
    CASE
      WHEN COALESCE(NULLIF(category, ''), '') <> '' THEN '**Category:** ' || category || CHAR(10) || CHAR(10)
      ELSE ''
    END ||
    CASE
      WHEN COALESCE(NULLIF(requirement, ''), '') <> '' THEN '## Requirement' || CHAR(10) || requirement || CHAR(10) || CHAR(10)
      ELSE ''
    END ||
    CASE
      WHEN COALESCE(NULLIF(trigger, ''), '') <> '' THEN '## Trigger' || CHAR(10) || trigger || CHAR(10) || CHAR(10)
      ELSE ''
    END ||
    CASE
      WHEN COALESCE(NULLIF(safe_path, ''), '') <> '' THEN '## Safe path' || CHAR(10) || safe_path || CHAR(10)
      ELSE ''
    END,
  tags_json,
  owner_email,
  published,
  created_at,
  updated_at,
  published_at
FROM spells;

DROP TABLE spells;

ALTER TABLE spells_new RENAME TO spells;

CREATE INDEX IF NOT EXISTS idx_spells_public_updated
  ON spells (published, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_spells_owner_updated
  ON spells (owner_email, updated_at DESC);
