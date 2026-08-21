# ADR-0003 Task Packet

Source decision: [../0003-rule-centric-product-model-and-reviewed-sharing.md](../0003-rule-centric-product-model-and-reviewed-sharing.md)

These task briefs split ADR-0003 into domain-owned implementation tracks. They are written for separate AI agents working on isolated git worktrees, so each agent can mostly stay inside one part of the system and avoid feature-slice churn across unrelated files.

Do not create or update a GitHub Gist for these task files unless the user explicitly approves it.

## Domain Tracks

- [01-backend-domain.md](01-backend-domain.md): Workers API, D1 schema, auth roles, rules, packs, review lifecycle, and backend tests.
- [02-web-domain.md](02-web-domain.md): Web public library, creator views, admin review UI, and web build.
- [03-macos-domain.md](03-macos-domain.md): macOS app storage migration, rule authoring/install, pack install preview, and app navigation.
- [04-docs-product-contracts-domain.md](04-docs-product-contracts-domain.md): Product terminology, schemas, README/PUBLISHING docs, and cross-domain contract notes.
- [05-integration-domain.md](05-integration-domain.md): Final merge, migration hardening, compatibility checks, and end-to-end validation.

## Suggested Parallelization

Start these first:

- Backend domain, because it defines the canonical API and lifecycle behavior.
- macOS domain, because local rule storage migration can begin before every backend endpoint is finished.
- Docs/product contracts domain, because it can keep terminology and contract notes aligned while agents work.

Start after backend contracts are sketched:

- Web domain, using the backend agent's endpoint notes or temporary fixtures where needed.

Run last:

- Integration domain, after the other branches are merged or rebased together.

## Shared Invariants

- A rule receives a backend `uid` when its backend draft is created.
- A rule version is mutable until approval and immutable after approval.
- Draft rules are private to the creator but installable by that creator.
- Public library views show only the latest approved rule or pack by default.
- Packs are public-library batch installers only. Workspaces have rules, not packs.
- Pack install previews rule version differences, then installs the pack-pinned rule versions.
- Local executable rule storage is `~/.spellbook/rules/<uid>/<version>/SPEC.md`.
- The ADR-0002 managed harness block approach remains, but generated paths migrate from `instructions` to `rules`.
- Drafts are backend-owned; offline draft authoring is out of scope.

Shared cross-domain contracts live in [contracts.md](contracts.md).

## Collision Notes

- Each domain should keep a short implementation note in its task file or final response describing new endpoints, state names, and migration assumptions.
- Backend should prefer new modules over growing `workers/api/src/index.ts` further.
- macOS should own app behavior and local filesystem migration; web should not edit Swift files.
- Web should own browser UI and review surfaces; macOS should not edit `apps/web` except in integration.
- Docs/product contracts can update shared docs and schemas, but should avoid behavior changes.
- Integration may touch many files, but only to reconcile completed domain work.
