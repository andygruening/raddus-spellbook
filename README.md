# Raddus Spellbook

Spellbook is a native macOS app and Cloudflare backend for capturing reusable AI-agent instructions from local agent work, storing a local agent context package, and sharing public spells through a hosted API.

## Structure

- `apps/macos/Spellbook` - native SwiftUI macOS app.
- `workers/api` - TypeScript Cloudflare Worker API backed by D1.
- `apps/web` - optional React TypeScript read-only web listing.

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

Each target directory stores an `.agent-context/` package next to its `AGENTS.md`, `AGENT.md`, or `CLAUDE.md` file. The project registry contains the installed instructions attached to that specific target:

```text
.agent-context/
  manifest.json
  master.json
```

The machine-local Spellbook store keeps the global installed library, review queues, and versioned spell bodies:

```text
~/.spellbook/
  registry/
    library.json
    staging.json
    archive.json
  spells/
    <spell-uid-or-local-id>/
      <version>/
        SPEC.md
```

The global library and project registries use this lightweight shape:

```json
{
  "version": 1,
  "agent": "codex",
  "instructions": [
    {
      "uid": "server-id-after-publish",
      "version": 3,
      "name": "Short spell name",
      "description": "What this spell helps the agent remember.",
      "trigger": "When the agent should activate this spell.",
      "tags": ["instruction"]
    }
  ]
}
```

Unpublished local spells use `localID` instead of `uid`. Published spell versions are immutable snapshots; the backend increments `version` every time an update is published for that spell.

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
