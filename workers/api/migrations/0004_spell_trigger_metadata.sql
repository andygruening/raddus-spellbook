ALTER TABLE spells
  ADD COLUMN trigger TEXT NOT NULL DEFAULT '';

UPDATE spells
SET trigger = TRIM(
  CASE
    WHEN INSTR(SUBSTR(content, INSTR(content, '## Trigger') + LENGTH('## Trigger')), CHAR(10) || '## ') > 0 THEN
      SUBSTR(
        SUBSTR(content, INSTR(content, '## Trigger') + LENGTH('## Trigger')),
        1,
        INSTR(SUBSTR(content, INSTR(content, '## Trigger') + LENGTH('## Trigger')), CHAR(10) || '## ') - 1
      )
    ELSE SUBSTR(content, INSTR(content, '## Trigger') + LENGTH('## Trigger'))
  END
)
WHERE trigger = ''
  AND INSTR(content, '## Trigger') > 0;
