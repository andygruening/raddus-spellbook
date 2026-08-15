# Raddus Spellbook

Spellbook is a native macOS app and Cloudflare backend for installing reusable, versioned AI-agent instructions into local agent harnesses and sharing public spells through a hosted API.

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

Each target directory stores an `.agent-context/` package next to its `AGENTS.md`, `AGENT.md`, or `CLAUDE.md` file. Target registries are agent-specific and contain only pinned instruction references:

```text
.agent-context/
  manifest.json
  codex.registry.json
  claude.registry.json
```

The machine-local Spellbook store keeps the installed instruction metadata, known targets, current diagnostics, a stable resolver symlink, and versioned `SPEC.md` bodies:

```text
~/.spellbook/
  bin/
    spellbook-agent-context
  registry/
    registry.json
    targets.json
    errors.json
  instructions/
    <uid>/
      <version>/
        SPEC.md
```

Target registries use this lightweight shape:

```json
{
  "schema_version": 1,
  "agent": "codex",
  "instructions": [
    {
      "uid": "server-id-after-publish",
      "version": 3
    }
  ]
}
```

The system registry at `~/.spellbook/registry/registry.json` contains the full metadata for each installed `(uid, version)` pair. Unpublished drafts stay private to the macOS app and cannot be installed into target registries until they are published or synced and have a backend `uid`.

Agent harnesses call the resolver instead of reading registries directly:

```bash
~/.spellbook/bin/spellbook-agent-context list-triggers \
  --target "$PWD" \
  --harness-root "$HOME/.codex" \
  --agent codex
```

The resolver merges pinned refs from the current project target and the harness root, then resolves metadata and `SPEC.md` bodies from `~/.spellbook`. A missing `.agent-context/` package or an empty registry on either side returns an empty instruction set without diagnostics.

JSON Schemas for the manifest, target registries, system registry, known targets, and diagnostics live in `docs/schemas/`.

The macOS app is sandboxed, but Spellbook intentionally resolves `~/.spellbook` to the real account home directory, not the app container. The app has a home-relative sandbox exception for `/.spellbook/`, installs the resolver path as a symlink to the signed helper inside the app bundle, and has a Settings repair action that migrates UID-backed instructions from the older container-local store when needed.

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
