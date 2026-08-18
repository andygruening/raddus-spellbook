# Raddus Spellbook

Spellbook is a native macOS app and Cloudflare backend for installing reusable, versioned AI-agent instructions into local agent harnesses and sharing public spells through a hosted API.

## Structure

- `apps/macos/Spellbook` - native SwiftUI macOS app.
- `workers/api` - TypeScript Cloudflare Worker API backed by D1.
- `apps/web` - optional React TypeScript read-only web listing.

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

## Dynamic Spell Links

The Worker exposes dynamic spell links at:

```text
https://api.spellbook.raddus.dev/open/<spell-id>
```

macOS requests redirect to `spellbook://spell/<spell-id>`. Other requests redirect to the production web app at `/spell/<spell-id>` so the relevant public spell can open automatically.

## Deploy The Web App

The read-only web app deploys to Cloudflare Pages as the `spellbook` project. Create the Pages project once, then deploy production builds from the repo root:

```bash
npm run deploy:web:create
npm run deploy:web
```

Attach `spellbook.raddus.dev` to this Pages project so dynamic links from the API land on the deployed web app.

For preview deployments, run:

```bash
npm run deploy:web:preview
```

## Local Agent Context Files

Each target directory uses the selected harness files, such as `AGENTS.md`, `AGENT.md`, or `CLAUDE.md`, as the target-level source of truth. The macOS app writes one managed Spellbook block into each selected harness file:

```md
<!-- spellbook:start -->
## Spellbook Instructions

The Spellbook app manages this block. Do not edit it by hand.

For every task, check these Spellbook instruction triggers. When a trigger matches, read the linked `SPEC.md` and follow it. If a referenced file is missing or unreadable, report it in chat and continue without that Spellbook instruction.

<!-- spellbook:instruction:start uid="server-id-after-publish" version="3" -->
Trigger: when the instruction trigger applies.
File: ~/.spellbook/instructions/server-id-after-publish/3/SPEC.md
<!-- spellbook:instruction:end -->

<!-- spellbook:end -->
```

The machine-local Spellbook store keeps the installed instruction metadata, known targets, and versioned `SPEC.md` bodies:

```text
~/.spellbook/
  registry/
    targets.json
  instructions/
    <uid>/
      <version>/
        index.json
        SPEC.md
```

Known targets use the selected root directory plus harness file names:

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

The app discovers locally installed instruction versions by scanning `~/.spellbook/instructions/<uid>/<version>/`. A version is complete only when both `index.json` and `SPEC.md` exist. Unpublished drafts stay private to the macOS app and cannot be installed into target harnesses until they are published or synced and have a backend `uid`.

JSON Schemas for instruction version indexes and known targets live in `docs/schemas/`.

The macOS app is sandboxed, but Spellbook intentionally resolves `~/.spellbook` to the real account home directory, not the app container. The app has a home-relative sandbox exception for `/.spellbook/` and has a Settings repair action that migrates UID-backed instructions from the older container-local store when needed.

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
