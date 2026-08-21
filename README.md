# Raddus Spellbook

Spellbook is a native macOS app, web public library, and Cloudflare backend for creating reusable AI-agent rules, applying them to local workspaces, and sharing reviewed public rules and packs.

## Structure

- `apps/macos/Spellbook` - native SwiftUI macOS app.
- `workers/api` - TypeScript Cloudflare Worker API backed by D1.
- `apps/web` - React TypeScript public library and review surface.

## Testing

Install dependencies and run the same checks used by pull request CI:

```bash
npm ci
npm run check
npm test
```

The `Tests` GitHub Actions workflow runs these commands whenever a pull request is opened, reopened, marked ready for review, or updated with new commits. To make passing tests a merge requirement, configure the default branch protection rule or repository ruleset to require the `All tests` status check before merging.

## Production API

The macOS and web clients point to:

```text
https://api.spellbook.raddus.dev/
```

The app does not expose an editable API URL.

## Dynamic Links

The Worker exposes dynamic links for public artifacts. During the ADR-0003 migration, existing spell links remain supported for compatibility:

```text
https://api.spellbook.raddus.dev/open/<spell-id>
```

macOS requests redirect to the installed app. Other requests redirect to the production web app so the relevant public rule or pack can open automatically.

## Deploy The Web App

The web app deploys to Cloudflare Pages as the `spellbook` project. Create the Pages project once, then deploy production builds from the repo root:

```bash
npm run deploy:web:create
npm run deploy:web
```

Attach `spellbook.raddus.dev` to this Pages project so dynamic links from the API land on the deployed web app.

For preview deployments, run:

```bash
npm run deploy:web:preview
```

## Product Model

Spellbook uses these user-facing terms after ADR-0003:

- **Workspace**: a local context where AI behavior applies. A workspace usually maps to a directory containing one or more harness files such as `AGENTS.md`, `AGENT.md`, or `CLAUDE.md`.
- **Rule**: the atomic reusable behavior unit. A rule has a backend `uid`, versioned metadata, an "Applies when" condition, and a generated or advanced markdown rule body.
- **Pack**: a reviewed public-library bundle of pinned rule versions. Installing a pack is a batch operation that adds or updates rules in a workspace; workspaces do not store pack installation state.
- **Public library**: the web and app surfaces for latest approved public rules and packs. Older approved versions remain available by version history or direct links.

Draft authoring is backend-owned. Creating a rule or pack draft requires sign-in, assigns the backend `uid` immediately, and stores mutable draft content in the backend. Local offline draft authoring under `~/.spellbook/drafts` is out of scope.

## Local Agent Context Files

Each workspace directory uses the selected harness files, such as `AGENTS.md`, `AGENT.md`, or `CLAUDE.md`, as the workspace-level source of truth. The macOS app writes one managed Spellbook block into each selected harness file:

```md
<!-- spellbook:start -->
## Spellbook Rules

The Spellbook app manages this block. Do not edit it by hand.

For every task, check these Spellbook rule conditions. When one applies, read the linked `SPEC.md` and follow it. If a referenced file is missing or unreadable, report it in chat and continue without that Spellbook rule.

<!-- spellbook:instruction:start uid="server-id-after-draft" version="3" -->
Applies when: when the rule condition applies.
File: ~/.spellbook/rules/server-id-after-draft/3/SPEC.md
<!-- spellbook:instruction:end -->

<!-- spellbook:end -->
```

The machine-local Spellbook store keeps installed rule metadata, known workspaces, and versioned `SPEC.md` bodies:

```text
~/.spellbook/
  registry/
    targets.json
  rules/
    <uid>/
      <version>/
        index.json
        SPEC.md
```

The canonical local executable rule path is:

```text
~/.spellbook/rules/<uid>/<version>/SPEC.md
```

Known workspaces use the selected root directory plus harness file names. The compatibility file name remains `targets.json` during the migration:

```json
{
  "schema_version": 1,
  "targets": [
    {
      "root": "/Users/agruning/Documents/raddus-spellbook",
      "harness_files": ["AGENTS.md", "CLAUDE.md"]
    }
  ]
}
```

The app discovers locally installed rule versions by scanning `~/.spellbook/rules/<uid>/<version>/`. A version is complete only when both `index.json` and `SPEC.md` exist. Mutable backend draft versions may be installed by their creator; reinstalling a mutable draft overwrites the local rule body with the latest backend draft. Approved versions are immutable, and edits after approval create the next draft version for the same `uid`.

Existing content under `~/.spellbook/instructions` and `~/.spellbook/spells` is legacy-compatible data. The app may scan, migrate, or repair those layouts, but newly written harness entries and local executable bodies should use `~/.spellbook/rules`.

JSON Schemas for rule version indexes and known workspaces live in `docs/schemas/`.

The macOS app is sandboxed, but Spellbook intentionally resolves `~/.spellbook` to the real account home directory, not the app container. The app has a home-relative sandbox exception for `/.spellbook/` and has a Settings repair action that migrates UID-backed legacy rule content from the older container-local store when needed.

## Run The macOS App

Open `apps/macos/Spellbook/Spellbook.xcodeproj` in Xcode and run the `Spellbook` scheme. The target builds a native macOS `.app` with sandboxed network access, user-selected read/write file access, and Keychain-backed session storage.

## Publish The macOS App

Use Xcode's Organizer flow to archive, sign, and notarize the macOS app for direct distribution. See `apps/macos/Spellbook/PUBLISHING.md` for the release checklist and GitHub `.dmg` upload steps.

## Worker Secrets

Configure these with Wrangler secrets before deploying:

```bash
wrangler secret put SPELLBOOK_JWT_SECRET
wrangler secret put RESEND_API_KEY
wrangler secret put RESEND_FROM_EMAIL
```

The D1 binding is named `DB`.

Apply D1 migrations before deploying Worker code that depends on new schema tables:

```bash
wrangler d1 migrations apply spellbook --remote
```
