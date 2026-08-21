---
status: accepted
supersedes: ADR-0001 runtime resolver-loading contract
---

# App-Written Spellbook Instruction Indexes in Harness Files

Forward pointer: ADR-0003 keeps this managed harness block approach, but renames the product model from instructions/targets to rules/workspaces and moves new local executable rule bodies to `~/.spellbook/rules/<uid>/<version>/SPEC.md`.

Raddus Spellbook will stop asking agent harnesses to run `~/.spellbook/bin/spellbook-agent-context` at task time to discover and read installed instructions. Instead, the macOS app will write a compact managed instruction index directly into the target harness file, such as `AGENTS.md`, with one marked `Trigger` and `File` entry per installed instruction. This removes the runtime binary dependency and per-session resolver overhead without copying full instruction bodies into every target harness file.

## Decision

The app-owned harness file content is the runtime source of truth for which Spellbook instructions an agent should consider. When a user installs an instruction into a target, the app writes a marked entry with the trigger for using it and the versioned local `SPEC.md` file. The harness should read the harness file naturally, inspect these triggers, and open the referenced `SPEC.md` only when a trigger matches the current task. It should not invoke a Spellbook resolver command to decide which Spellbook instructions exist.

The managed Spellbook area should use one outer managed block plus per-instruction comment markers. Each instruction entry must use `uid` as its identity and include `uid` and `version` attributes on the start marker. Installation state is scoped by the harness file containing the block, so markers do not include an agent key. The app should use the markers, not fragile trigger text parsing, to check whether an instruction exists, find the currently installed version, update the versioned path and trigger, or remove a single instruction.

```md
<!-- spellbook:start -->
## Spellbook Instructions

The Spellbook app manages this block. Do not edit it by hand.

For every task, check these Spellbook instruction triggers. When a trigger matches, read the linked `SPEC.md` and follow it. If a referenced file is missing or unreadable, report it in chat and continue without that Spellbook instruction.

<!-- spellbook:instruction:start uid="swiftui-design" version="3" -->
Trigger: when creating or changing SwiftUI views, layout, controls, navigation, or visual polish.
File: ~/.spellbook/instructions/swiftui-design/3/SPEC.md
<!-- spellbook:instruction:end -->

<!-- spellbook:instruction:start uid="cloudflare-workers" version="2" -->
Trigger: when writing, reviewing, testing, or deploying Cloudflare Workers code.
File: ~/.spellbook/instructions/cloudflare-workers/2/SPEC.md
<!-- spellbook:instruction:end -->

<!-- spellbook:instruction:start uid="github-pr-review" version="1" -->
Trigger: when reviewing a pull request, addressing review comments, or investigating failing GitHub checks.
File: ~/.spellbook/instructions/github-pr-review/1/SPEC.md
<!-- spellbook:instruction:end -->

<!-- spellbook:end -->
```

The target directory should not contain a `.agent-context/` package, target manifest, or agent-specific target registry files. The managed block in the selected harness file is the only target-level record of which Spellbook instructions are installed for that harness.

The local instruction store keeps `~/.spellbook/instructions/<uid>/<version>/index.json` beside each `SPEC.md`. That metadata remains useful to the macOS app for names, descriptions, triggers, tags, catalog display, upgrade checks, and diagnostics, but the harness does not need to read it. The app should discover locally available instruction versions by scanning `~/.spellbook/instructions/`; it should not maintain a separate `~/.spellbook/registry/registry.json` installed-version index. The harness-facing contract is only the managed block and the linked `SPEC.md` files.

The app should treat a local instruction version as complete only when both `index.json` and `SPEC.md` exist. Complete local versions appear in the Instructions tab. Incomplete local versions, such as metadata without a body or a body without metadata, appear only as warnings. The Published tab is backed by the backend catalog, not by the local instruction-store scan.

Deleting an instruction from the local Instructions tab is an instruction-level operation that removes all locally cached versions for that `uid`. The app must block deletion while any known harness file references that `uid`, regardless of which version the harness pins. The user must remove the instruction from all targets before deleting it locally.

Removing an instruction from a target only removes that instruction entry from the selected harness file's managed block. It does not delete local `~/.spellbook/instructions/<uid>/` files. If the removed instruction was the last instruction in that harness, the app should leave the empty outer managed block in place so the harness remains enrolled in the known target.

Removing a target is different from removing all instructions. Target removal should remove the entire Spellbook managed block, including all instruction entries, from each selected harness file and remove the target record from `targets.json`.

Instruction versions are increasing integers. Harness entries pin a specific version and may stay on an older version until the user updates that target. Install and update actions should choose the latest backend version for the instruction, sync that version into `~/.spellbook/instructions/<uid>/<version>/index.json` and `SPEC.md`, and only then write the harness marker and rendered `Trigger` and `File` fields. If the local sync fails, the app should not update the harness file.

For now, target install and update flows assume the backend is reachable. If the app is offline, it should show a full-window warning asking the user to reconnect before continuing instead of falling back to locally cached latest-version decisions.

The macOS app should validate the whole managed block, including the outer template, matching instruction start/end markers, marker attributes, the rendered `Trigger` and `File` fields, the derived `SPEC.md` path, and the corresponding `index.json` and `SPEC.md` files. Any mismatch is a diagnostic that should ask the user to repair the target. The marker `uid` and `version` are authoritative for repair; rendered trigger text and `SPEC.md` paths should be rewritten from `index.json` and the fixed store layout when the user chooses repair. If `index.json` or `SPEC.md` is missing for a marked instruction, the app should leave the entry in place with a diagnostic saying the instruction will not work until the user repairs or removes it.

Repair actions should be scoped to the smallest identifiable problem. If a listed harness file is missing, or the harness file exists but its outer Spellbook block is missing, the warnings view should ask the user to either recreate the harness/block or remove that harness from the known target. If one instruction entry is malformed but still has an identifiable `uid`, repair should rewrite only that instruction entry. If an instruction entry is too broken for the app to identify which instruction it was, the warning should say there is a broken instruction entry and offer removal, not repair. If a harness block contains duplicate entries for the same `uid`, the app should warn and offer only to keep one chosen version and remove the duplicate entry.

Diagnostics should be live app state, not durable Spellbook state. The app should not write `~/.spellbook/registry/errors.json`; it should refresh diagnostics for all known targets when the user opens the warnings view and show the current results from memory.

Known targets remain durable user intent in `~/.spellbook/registry/targets.json`. Each target record should store only the selected root directory and the selected harness file names, not stable ids, display names, timestamps, `.agent-context` paths, or absolute paths to each harness file. The root directory is the target identity and must be unique; adding harnesses for an existing root should merge them into that root's `harness_files`. The app should derive display names from the root directory basename:

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

If a known target root no longer exists, the warnings view should show a stale-target diagnostic with a fix action that lets the user relink the target to its new root. The app should not silently delete moved or renamed targets.

When adding a target, the user explicitly selects the harness file names Spellbook should manage. If a selected harness file does not exist under the chosen root, the app should create it with the standard empty managed block.

## Considered Options

Keep the resolver-driven runtime loading from ADR-0001.

This keeps `AGENTS.md` very small and avoids putting trigger text in every target, but it makes every task depend on a local executable, valid JSON output, current registry state, and harness-specific instructions for command execution and failure handling. It also spends time and tokens on a resolver step before the agent can decide whether any Spellbook instruction matters.

Keep `.agent-context/` target packages.

This would preserve the previous target manifest and registry structure, but the new harness file block already records the installed `uid`s and versions. Keeping both would create two target-level sources of truth while the product is still early enough to remove the old package cleanly.

Persist diagnostics in `~/.spellbook/registry/errors.json`.

This would make warnings inspectable outside the app, but it creates another durable file that can drift from the real target state. Warnings are only needed when the user opens the warnings UI, so they should be recomputed then.

Keep `~/.spellbook/registry/registry.json` as an installed-version index.

This would make local library reads faster, but it creates another durable index that can drift from `index.json` and `SPEC.md` files. The instruction directory layout is the local source of truth; the app can scan it when it needs the installed library.

Store absolute harness file paths in `targets.json`.

This would make scans direct, but the selected root directory is the user-facing target. Storing root plus harness filenames keeps target identity stable while still allowing each harness file to have independent managed instructions.

Only allow existing harness files during target enrollment.

This would avoid creating files unexpectedly, but the user has already selected the harness names Spellbook should manage. Creating missing selected files makes target setup explicit and smooth.

Choose latest versions by scanning the local instruction store.

This would work offline, but it could miss a newer backend version the user expects to install. The backend catalog is the authority for latest; the local store is the prerequisite cache that must be written before a harness entry points at that version.

Support offline target installs and updates.

This would make the app more resilient, but it complicates latest-version semantics. While the product is still early, offline install/update should be blocked with a clear reconnect warning.

Inline full instruction bodies in the harness file.

This makes runtime loading simple and reviewable, but it duplicates full instruction bodies across targets and bloats every harness session with instruction content that often will not apply to the current task.

Parse installed instructions from canonical `SPEC.md` paths alone.

This keeps the managed block cleaner for humans, but it makes app behavior depend on parsing rendered prose. Triggers can contain markdown, paths can change during migrations, and a user edit could make one instruction hard to update or remove without affecting others.

## Consequences

Installed instruction triggers become visible in the target's harness file and work even when the resolver binary is missing or broken.

The app takes on responsibility for rewriting the managed block carefully, including preserving non-Spellbook content, avoiding duplicate instruction `uid`s, keeping installed versions explicit, and preserving valid start/end marker pairs.

Manual edits inside the managed block are treated as mismatches. The app should warn and offer repair rather than treating edited managed content as target-specific customization.

Repair is per identifiable harness or instruction entry. Unidentifiable broken instruction entries are remove-only.

Warnings are refreshed on demand in the macOS app instead of stored in `~/.spellbook`.

The local installed-version list is derived by scanning `~/.spellbook/instructions/`, not by reading a durable `registry.json` index.

The Instructions tab shows complete local instruction versions. The Published tab shows backend catalog entries. Broken local instruction versions are warnings only.

Local instruction deletion removes all cached versions for a `uid` and is blocked by any target reference to that `uid`.

Removing an instruction from a target does not delete local cached files, and empty managed blocks stay in enrolled harness files.

Removing a target deletes its managed harness blocks and removes its `targets.json` record.

`targets.json` remains durable state, but only for unique known target roots and selected harness file names. If a root path is stale, the app warns and offers to relink it.

Adding a target can create missing harness files, but only for harness filenames the user selected.

Removing `.agent-context/` leaves the selected harness file as the only per-target Spellbook artifact. The system library remains under `~/.spellbook/`.

The `~/.spellbook/instructions/<uid>/<version>/SPEC.md` path format becomes a harness-facing contract. Changing that layout later will require a managed-block migration.

Instruction bodies stay in the system store rather than being duplicated across targets, but upgrades must still be explicit app writes to each target's managed block rather than implicit runtime resolution through a resolver. Install and update actions move targets to the latest backend version only after that version is present locally.

Offline install and update are intentionally out of scope for now.
