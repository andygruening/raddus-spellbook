# Task 03: macOS Domain

Source decision: [../0003-rule-centric-product-model-and-reviewed-sharing.md](../0003-rule-centric-product-model-and-reviewed-sharing.md)

## Goal

Implement the macOS app domain for ADR-0003: local rule storage, workspace rule installation, backend-owned rule authoring, private draft install, pack browsing/install preview, and app navigation.

## Domain Boundary

Owns:

- Swift models, API client, app state, and macOS UI.
- Local rule store migration and compatibility reads.
- Workspace harness block generation and updates.
- Rule builder, draft/review states, and Finish behavior.
- Packs tab and pack batch install preview.

Does not own:

- D1 schema or backend authorization rules.
- React web review UI.
- Broad README/docs updates outside macOS-specific notes.

## Required Behavior

### Local Rule Store

- Newly written executable rule versions live under `~/.spellbook/rules/<uid>/<version>/SPEC.md`.
- Metadata remains beside the body, preserving the current `index.json` style unless there is a strong local reason to change it.
- Generated harness entries reference `~/.spellbook/rules/...`.
- Existing content under `~/.spellbook/instructions` or `~/.spellbook/spells` remains discoverable or migratable.
- Removing a rule from a workspace updates the harness block only; it does not delete local rule files.

### Rule Authoring And Private Install

- Creating a rule draft requires sign-in and uses backend draft APIs.
- Drafts are not stored under `~/.spellbook/drafts`.
- The rule builder asks for Purpose, Applies When, Desired Behavior, Avoided Behavior, Permission Boundary, Examples, and Preview.
- Advanced Markdown remains available.
- The creator can install a private draft rule into a workspace through the normal rule install flow.
- Reinstalling a mutable draft version overwrites the local `SPEC.md` copy.
- Submitted and Needs Changes states remain editable and resubmittable.
- Review notes are visible.
- Approved ready to finish state is visible.
- Finish ensures the approved rule version is locally cached and clears local finish/draft UI state without touching any workspace harness.

### Packs

- Add a Packs top-level navigation item.
- List latest approved public packs.
- Expanding a pack shows included pinned rule versions.
- Installing a pack asks the user to choose a workspace.
- The preview labels each included rule as exact version already installed, different version installed, or missing.
- Confirming install writes every pack-pinned rule version locally and updates the selected workspace harness to those pinned versions.
- Pack-pinned versions win, including downgrades from a newer workspace version.
- Do not write `~/.spellbook/packs.json` or any workspace pack-provenance state.

### Navigation And Vocabulary

- Main macOS navigation is Workspaces, Packs, Rules, Settings.
- User-facing labels prefer Rules, Packs, Workspaces, and Applies when.
- Old terms may remain in implementation symbols and migration warnings where useful.

## Likely Files

- `apps/macos/Spellbook/Spellbook/InstructionManager.swift`
- `apps/macos/Spellbook/Spellbook/LocalSpellStore.swift`
- `apps/macos/Spellbook/Spellbook/Spell.swift`
- `apps/macos/Spellbook/Spellbook/SpellbookAPI.swift`
- `apps/macos/Spellbook/Spellbook/SpellPages.swift`
- `apps/macos/Spellbook/Spellbook/MainView.swift`
- `apps/macos/Spellbook/Spellbook/AuthViews.swift`

## Backend Dependencies

Use the Backend Domain handoff contract for rule and pack endpoint names. If backend work is still in flight, isolate API calls behind `SpellbookAPI` methods so endpoint changes are easy to reconcile.

## Acceptance Criteria

- The app writes and scans `~/.spellbook/rules`.
- New harness entries point at `~/.spellbook/rules`.
- Legacy installed instructions remain usable or migratable.
- A signed-in user can create, edit, privately install, submit, and finish a rule draft.
- A user can browse packs, preview rule version differences against a workspace, and install pack-pinned versions.
- Workspaces contain rule references only, never pack references.
- App copy uses the ADR-0003 vocabulary on primary surfaces.

## Suggested Validation

- Build the macOS app with Xcode or `xcodebuild`.
- Manually test local scan, rule install/update/remove, rule draft flow, Finish, pack preview, and pack install.
- Use `rg` to inspect remaining user-facing uses of old vocabulary.
