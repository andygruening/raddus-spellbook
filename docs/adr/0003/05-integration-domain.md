# Task 05: Integration Domain

Source decision: [../0003-rule-centric-product-model-and-reviewed-sharing.md](../0003-rule-centric-product-model-and-reviewed-sharing.md)

## Goal

Merge and harden the backend, web, macOS, and docs domain branches into one coherent ADR-0003 implementation.

## Domain Boundary

Owns:

- Cross-domain merge reconciliation.
- Migration numbering and compatibility cleanup.
- End-to-end validation across backend, web, and macOS.
- Final docs/task packet accuracy.

Does not own:

- New product features beyond ADR-0003.
- Reopening already-settled domain design without a concrete integration problem.

## Required Behavior

- Rebase and renumber D1 migrations from backend work.
- Verify old spell endpoints and new rule endpoints have the intended compatibility story.
- Verify backend, web, and macOS agree on lifecycle state names.
- Verify public listings show latest approved rules and packs only by default.
- Verify draft rules are private but installable by the creator.
- Verify approved versions are immutable.
- Verify packs install rules into workspaces without creating pack workspace state.
- Verify `~/.spellbook/instructions` to `~/.spellbook/rules` migration or compatibility behavior.
- Update docs and task packet notes for anything discovered during integration.

## Likely Files

- `workers/api/migrations/*.sql`
- `workers/api/src/*.ts`
- `workers/api/test/*.test.ts`
- `apps/web/src/*.tsx`
- `apps/web/src/*.ts`
- `apps/macos/Spellbook/Spellbook/*.swift`
- `docs/schemas/*.json`
- `README.md`
- `docs/adr/0003*.md`

## Acceptance Criteria

- Fresh local backend migrations apply cleanly.
- Backend tests and type checks pass.
- Web build passes.
- macOS builds.
- A signed-in user can create a draft rule, privately install it, submit it, have an admin approve it, and see it in the public library.
- A public pack can be approved and then installed into a workspace as rule references only.
- Legacy local instruction installs are either migrated or clearly supported as read-compatible.
- User-facing product language is coherent across web and macOS.

## Suggested Validation

- From `workers/api`: `npm run migrate:local`
- From `workers/api`: `npm run test`
- From `workers/api`: `npm run check`
- From `apps/web`: `npm run build`
- Build the macOS app with Xcode or `xcodebuild`.

## Coordination Notes

- Run this after the other domain branches are merged or rebased onto one integration branch.
- This task is allowed to touch many files, but only to reconcile completed domain work.
- Keep a short final compatibility note for any legacy spell/instruction behavior that remains.
