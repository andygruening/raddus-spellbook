# Task 01: Backend Domain

Source decision: [../0003-rule-centric-product-model-and-reviewed-sharing.md](../0003-rule-centric-product-model-and-reviewed-sharing.md)

## Goal

Implement the backend domain for ADR-0003: rule identities, mutable-until-approved rule versions, packs, admin review, user roles, latest-approved public listing, and compatibility with the current spell API during migration.

## Domain Boundary

Owns:

- Workers API behavior.
- D1 migrations and data model.
- OTP-authenticated user records and roles.
- Rule and pack lifecycle state.
- Review notes and admin authorization.
- Backend tests and type checks.

Does not own:

- macOS Swift UI or local filesystem behavior.
- Web React UI beyond small API compatibility fixes.
- Product copy sweeps outside backend-facing messages.

## Current Shape To Replace

The backend currently has OTP challenges, a mutable `spells` table, `spell_versions` snapshots, and `spell_stars`. Creating or updating a spell publishes immediately. There are no users, roles, packs, draft records, review queues, or review notes.

## Required Behavior

- Create or upsert a `users` record during OTP verification, defaulting to role `user`.
- Support role `admin` in the backend database.
- Create a backend draft rule with a canonical `uid` immediately.
- Keep a single mutable rule version while it is Draft, Submitted for Review, or Needs Changes.
- Allow the creator to install/read their own private draft rule version.
- Let creators edit and resubmit while a rule is in review.
- Make approved rule versions immutable.
- Editing an approved rule creates the next draft version for the same `uid`.
- List only latest approved rule versions publicly by default.
- Create pack identities and pack versions with pinned rule `uid/version` references.
- Allow packs to include approved rules by any creator.
- Allow pack submissions to include new draft rules owned by the pack creator.
- Review packs atomically: approve the whole pack and its included new rules, or return the whole pack with notes.
- Ensure approved packs point only at approved rule versions.
- Keep older approved pack versions available by direct version lookup while public listing defaults to latest only.
- Preserve an intentional compatibility story for existing `/api/spells/*` clients.

## Likely Files

- `workers/api/migrations/*.sql`
- `workers/api/src/auth.ts`
- `workers/api/src/index.ts`
- `workers/api/src/spells.ts`
- New modules such as `workers/api/src/rules.ts`, `workers/api/src/packs.ts`, and `workers/api/src/reviews.ts`
- `workers/api/test/*.test.ts`

## Handoff Contract

Document the API shape for web and macOS agents, including:

- Rule draft create/update/read/submit endpoints.
- Rule public list/version lookup endpoints.
- Pack draft create/update/read/submit endpoints.
- Pack public list/version lookup endpoints.
- Admin review endpoints.
- Response lifecycle state names.
- Compatibility behavior for existing spell endpoints.

## Acceptance Criteria

- A signed-in user can create, edit, submit, and privately read/install a draft rule.
- An admin can approve a rule or return it as Needs Changes with notes.
- Approved rule versions cannot be edited in place.
- A signed-in user can create and submit a pack containing existing approved rules plus new draft rules.
- Admin pack review is all-or-nothing.
- Public rule and pack listings return latest approved versions only by default.
- Non-owners cannot access another user's private drafts.
- Non-admins cannot approve or return submissions.
- OTP sign-in still works.
- Backend tests cover lifecycle, authorization, pack review, and latest-only listing.

## Suggested Validation

- From `workers/api`: `npm run test`
- From `workers/api`: `npm run check`
- If migrations are added: `npm run migrate:local`
