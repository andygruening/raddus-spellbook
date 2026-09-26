# Task 02: Web Domain

Source decision: [../0003-rule-centric-product-model-and-reviewed-sharing.md](../0003-rule-centric-product-model-and-reviewed-sharing.md)

## Goal

Implement the web app domain for ADR-0003: public Rules and Packs library, signed-in creator views, and admin review UI using the existing email OTP sign-in method.

## Domain Boundary

Owns:

- React web UI and web client state.
- Public library browsing for latest approved rules and packs.
- Creator-facing draft/review states on the web.
- Admin review queues and review actions.
- Web build/type checks.

Does not own:

- D1 migrations or backend lifecycle rules.
- macOS Swift UI.
- Local `~/.spellbook` storage behavior.

## Required Behavior

- Replace "published spells" as the primary web concept with Rules and Packs.
- Public visitors see latest approved rules and latest approved packs by default.
- Users can open a pack and inspect its pinned included rule versions.
- Signed-in creators can see their own draft, submitted, Needs Changes, and approved artifacts when backend APIs expose them.
- Admin users can see review queues.
- Admins can approve a submitted rule or pack.
- Admins can send a rule or pack back as Needs Changes with notes.
- Pack review UI is atomic: approve the whole submission or send the whole submission back.
- Review notes are visible to creators.
- Deep links to macOS remain supported where the current dynamic-link behavior applies.

## Likely Files

- `apps/web/src/App.tsx`
- New web modules under `apps/web/src/` if useful
- `apps/web/package.json`

## Backend Dependencies

Use the Backend Domain handoff contract for endpoint names, state names, and response shapes. If the backend branch is not ready, use small local fixtures or narrow client abstractions that can be swapped to the final endpoints.

## Acceptance Criteria

- Web public library has clear Rules and Packs surfaces.
- Pack details show pinned included rule versions.
- Signed-in user state works with OTP session handling.
- Admin-only review controls are hidden from regular users.
- Approve and Needs Changes actions call the expected backend endpoints.
- Loading, empty, unauthorized, and error states are handled.
- User-facing web copy uses Rules, Packs, Workspaces, and Applies when instead of old spell/instruction language.

## Suggested Validation

- From `apps/web`: `npm run check`
- From `apps/web`: `npm run build`
- Manually verify public, signed-in creator, and admin review states.
