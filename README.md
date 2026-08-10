# Raddus Spellbook

Spellbook is a native macOS app and Cloudflare backend for capturing reusable AI-agent instructions from local agent work, storing a local `spells.json` index plus markdown spell files, and sharing public spells through a hosted API.

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

macOS requests redirect to `spellbook://spell/<spell-id>`. Other requests redirect to the production web app with `?spell=<spell-id>` so the relevant public spell can open automatically.

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

## Local Spell Files

Each target directory stores a `spells.json` index next to a `spells/` directory:

```json
{
  "version": 1,
  "spells": [
    {
      "uid": "server-id-after-publish",
      "name": "Short spell name",
      "description": "What this spell helps the agent remember.",
      "trigger": "When the agent should activate this spell.",
      "tags": ["instruction"],
      "file": "spells/short-spell-name.md"
    }
  ]
}
```

Unpublished spells omit `uid`. The referenced markdown file holds the full instruction body and details.

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
