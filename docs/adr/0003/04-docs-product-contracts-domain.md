# Task 04: Docs And Product Contracts Domain

Source decision: [../0003-rule-centric-product-model-and-reviewed-sharing.md](../0003-rule-centric-product-model-and-reviewed-sharing.md)

## Goal

Keep ADR-0003's product language, schemas, and implementation contracts coherent while backend, web, and macOS agents work in parallel.

## Domain Boundary

Owns:

- README and product documentation updates.
- Schema names and schema documentation.
- Terminology cleanup in docs.
- Cross-domain contract notes that help agents merge their work.
- ADR/task packet maintenance.

Does not own:

- Backend behavior implementation.
- macOS app behavior.
- Web app behavior.

## Required Behavior

- Update docs from instructions/spells/projects/published tabs toward rules/packs/workspaces/public library.
- Document the local rule path `~/.spellbook/rules/<uid>/<version>/SPEC.md`.
- Document compatibility expectations for legacy `~/.spellbook/instructions` and `~/.spellbook/spells`.
- Update or add schema docs for rule version metadata if implementation work changes `index.json`.
- Keep ADR-0001 and ADR-0002 historical text intact unless explicitly adding forward pointers.
- Keep the ADR-0003 task packet aligned with implementation discoveries.
- Maintain a concise API/state contract note if backend endpoints or lifecycle state names change during implementation.
- Keep [contracts.md](contracts.md) current with cross-domain vocabulary, local storage, lifecycle, pack, draft, and API handoff notes.

## Likely Files

- `README.md`
- `apps/macos/Spellbook/PUBLISHING.md`
- `docs/schemas/*.json`
- `docs/adr/0003-rule-centric-product-model-and-reviewed-sharing.md`
- `docs/adr/0003/*.md`

## Acceptance Criteria

- Current product docs describe Rules, Packs, Workspaces, and Applies when.
- Historical ADRs remain readable as historical decisions.
- New or updated schemas use rule terminology where appropriate.
- Docs clearly say packs are public-library batch installers, not workspace state.
- Docs clearly say drafts are backend-owned and offline draft authoring is out of scope.
- The task packet remains domain-oriented and useful for isolated worktrees.

## Suggested Validation

- Use `rg` to audit old vocabulary in docs and decide whether each occurrence is historical, compatibility-related, or stale.
- Verify Markdown links in the ADR-0003 packet are valid.

## Coordination Notes

- This domain can start early, but should do a final pass after backend, web, and macOS work settle.
- Avoid large behavior edits in code files from this task.
