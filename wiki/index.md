# Raddus Spellbook Wiki

Raddus Spellbook is a monorepo for a native macOS app, a Cloudflare Worker API, and a read-only React web listing. The implemented product installs reusable, versioned AI-agent instructions into local agent harness files and publishes public "spells" through a hosted API.

The repository has three first-party runtime areas:

| Area | Path | Responsibility |
| --- | --- | --- |
| macOS app | `apps/macos/Spellbook` | SwiftUI app for signing in, publishing or installing instructions, managing target directories, and writing managed blocks into harness files. |
| Worker API | `workers/api` | Cloudflare Worker with OTP auth, D1-backed public spell storage, version snapshots, stars, deletes, and dynamic `/open/<spell-id>` redirects. |
| Web app | `apps/web` | Vite/React Cloudflare Pages app that lists public spells, supports `/spell/<uid>` deep links, and shows published `SPEC.md` content. |

## Primary Flows

1. A user signs in through the macOS app. `AuthFlowView` collects an email and six-digit code, `SpellbookAPI` calls `/api/auth/request-otp` and `/api/auth/verify-otp`, and `SessionModel` stores the returned JWT session in Keychain.
2. A user publishes or updates a spell. The macOS app sends a `Spell` through `SpellbookAPI.publish`, and the Worker writes the current row in `spells` plus a version snapshot in `spell_versions`.
3. A user installs a published spell locally. `LocalSpellStore.upsertLocal` writes `index.json` and `SPEC.md` under `~/.spellbook/instructions/<uid>/<version>/`.
4. A user attaches installed instructions to target projects. `InstructionManager` writes a managed Spellbook block into selected `AGENTS.md`, `AGENT.md`, or `CLAUDE.md` files, with one trigger and versioned `SPEC.md` path per instruction.
5. Public visitors browse spells on the web app. `App` fetches `/api/spells/public?limit=100`, opens direct `/spell/<uid>` links, and renders details from `/api/spells/<uid>` when needed.
6. Dynamic share links hit the Worker at `/open/<spell-id>`. macOS-looking user agents redirect to `spellbook://spell/<spell-id>`; other clients redirect to the public web app at `/spell/<spell-id>`.

## Domain Pages

| Page | Scope |
| --- | --- |
| [Authentication and Sessions](authentication-and-sessions.md) | OTP email sign-in, JWT creation/verification, protected Worker routes, and macOS Keychain session handling. |
| [Backend Spell Registry](backend-spell-registry.md) | Worker route handling, D1 schema, public/mine spell reads, publishing, version snapshots, stars, deletes, and dynamic redirects. |
| [macOS Local Instruction Installation](macos-local-instruction-installation.md) | `~/.spellbook` storage, target registries, managed harness blocks, local install/update/remove flows, legacy migration, and diagnostics. |
| [macOS Application Workflows](macos-application-workflows.md) | SwiftUI navigation and user-facing workflows for local instructions, published spells, project targets, settings, and deep links. |
| [Web Public Registry](web-public-registry.md) | React public catalog, route-derived selection, linked spell loading, detail modal, share behavior, styling, and Pages routing. |
| [Development Operations and Contracts](development-operations-and-contracts.md) | npm workspaces, CI, type checks, tests, Cloudflare deploy configuration, D1 migrations, macOS release notes, schemas, and ADRs. |

## Reader Guide

Start with [Authentication and Sessions](authentication-and-sessions.md) if you need to understand how signed-in requests are authorized. Read [Backend Spell Registry](backend-spell-registry.md) for the API surface and database effects. Read [macOS Local Instruction Installation](macos-local-instruction-installation.md) before changing anything that writes `~/.spellbook` or target harness files. Read [Web Public Registry](web-public-registry.md) when changing the hosted listing or deep-link web behavior. Use [Development Operations and Contracts](development-operations-and-contracts.md) for supported commands, deployment hooks, and the current gap between accepted implementation docs and the draft ADR-0003 roadmap.
