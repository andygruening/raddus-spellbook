# ADR-0003 Cross-Domain Contracts

Source decision: [../0003-rule-centric-product-model-and-reviewed-sharing.md](../0003-rule-centric-product-model-and-reviewed-sharing.md)

These notes keep the backend, web, macOS, and integration work aligned while ADR-0003 is split across isolated branches.

## Product Vocabulary

- Use **workspace** in user-facing copy for a local context where rules apply. The compatibility file remains `~/.spellbook/registry/targets.json`.
- Use **rule** for the atomic reusable behavior unit. "Instruction" and "spell" are legacy terms and should appear only in historical ADRs, migration notes, compatibility APIs, or implementation symbols that have not migrated yet.
- Use **Applies when** for the user-facing rule condition. "Trigger" may remain in advanced diagnostics and legacy metadata aliases.
- Use **pack** for a public-library bundle of pinned rule versions. Packs are not workspace state.

## Local Storage

New executable rule bodies are stored at:

```text
~/.spellbook/rules/<uid>/<version>/SPEC.md
```

Rule metadata is stored beside the body as:

```text
~/.spellbook/rules/<uid>/<version>/index.json
```

The schema for new metadata is [../../schemas/rule-version-index.schema.json](../../schemas/rule-version-index.schema.json). Existing `~/.spellbook/instructions/<uid>/<version>/` and `~/.spellbook/spells/<uid>/<version>/` content is legacy-compatible data. macOS owns scanning, migration, and repair behavior for those layouts.

Harness blocks may keep the `spellbook:instruction` marker name during migration because ADR-0002 made that marker part of the managed-block contract. Rendered copy and generated file paths should use rule terminology and `~/.spellbook/rules`.

## Lifecycle States

Rules and packs use these canonical lifecycle state names in docs and API contracts:

- `draft`
- `submitted_for_review`
- `needs_changes`
- `approved`
- `withdrawn`
- `archived`

A rule receives its backend `uid` when the backend draft is created. A version is mutable in `draft`, `submitted_for_review`, and `needs_changes`; approval freezes that version. Editing an approved version creates the next draft version for the same `uid`.

## Draft Ownership

Draft authoring is backend-owned. macOS and web clients edit backend drafts after sign-in. Local offline draft authoring under `~/.spellbook/drafts` is out of scope for ADR-0003.

Creators may privately install their own mutable draft rule versions into their own workspaces. Reinstalling a mutable draft version overwrites the local `SPEC.md` snapshot with the latest backend draft content.

## Packs

Packs are reviewed public-library artifacts and batch installers:

- Public pack listings show latest approved pack versions by default.
- A pack version contains pinned `uid` and `version` references for included rules.
- Installing a pack into a workspace installs or updates those pinned rule versions and updates the workspace harness block.
- Pack-pinned versions win, including downgrades from a different installed rule version.
- Spellbook does not write durable local pack installation state, workspace pack provenance, or `~/.spellbook/packs.json`.

Approved pack versions may only reference approved rule versions. Pack review is atomic: approve the full pack submission and any included new draft rules, or return the full submission with notes.

## Backend API Handoff

Task 01 owns final endpoint names and response shapes. Until that branch lands, other domains should isolate API calls behind local client methods and rely on these stable concepts:

- rule draft create, read, update, submit
- rule public latest-approved list
- rule version lookup by `uid` and `version`
- pack draft create, read, update, submit
- pack public latest-approved list
- pack version lookup by `uid` and `version`
- admin review approve
- admin review needs-changes with notes

Existing `/api/spells/*` behavior is a compatibility surface during migration. New public contracts should prefer rules and packs, while compatibility endpoints should translate to the canonical lifecycle and version model where practical.
