---
status: proposed
gist: https://gist.github.com/andygruening/c6c9fff424d702d0bad8a4a6c09186b5
---

# Local Agent Context Instruction Structure

Raddus Spellbook will split monolithic agent harness files, such as `AGENTS.md`, into versioned, shareable instruction records that can be installed into many local projects or harness directories by the macOS client. A target project will carry only a manifest and pinned `{ uid, version }` references for each enabled agent harness, while the system-level Spellbook store under `~/.spellbook/` will own versioned instruction metadata, instruction bodies, known targets, diagnostics, and the resolver command used by agent harnesses.

## Context

Agent harness files are a convenient place to place instructions, but they do not scale when the same instruction should be reused across repositories, global harness directories, and multiple agents. Copying full instruction bodies into every harness file makes updates hard to reason about, hides which version a project uses, and gives the macOS client no clean boundary between local installation, project installation, remote publishing, and runtime loading.

The important split is between a target-level agent context package and a system-level Spellbook library:

- A target is any directory containing one or more supported agent harness files such as `AGENTS.md`, `AGENT.md`, or `CLAUDE.md`. It may be a normal project repository or a global harness directory.
- A target-level package lives at `.agent-context/` next to the harness files and references only the instruction `uid`s and versions installed for each agent.
- The system-level Spellbook store lives under `~/.spellbook/` and contains the locally installed versioned instruction library, versioned `SPEC.md` bodies, known targets, diagnostics, and resolver binary.
- The macOS client is the only writer of durable Spellbook state. Agents may make chat-only suggestions for future instructions, but they must not write suggestion, staging, archive, registry, or diagnostic files.
- Agent harnesses load instructions by calling the local resolver at `~/.spellbook/bin/spellbook-agent-context`. If the resolver is unavailable or cannot return usable JSON, the agent reports that in chat and continues without Spellbook-loaded instructions.

## Decision

Use a two-level local storage model with thin, agent-specific target registries and a versioned system registry.

Target-level files:

```text
<target>/
  AGENTS.md
  CLAUDE.md
  .agent-context/
    manifest.json
    codex.registry.json
    claude.registry.json
```

System-level files:

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

The target-level registries reference only instructions installed into that target for that agent. Each reference pins `uid` and `version`, and intentionally does not duplicate instruction names, descriptions, triggers, tags, or bodies. The target registry is the opt-in boundary; the system registry is the metadata authority.

The system-level `registry/registry.json` contains the user's locally installed instruction library. Metadata is versioned and flat, so the resolver always joins target references and system metadata by `(uid, version)`. Creating an instruction in the macOS app publishes or syncs it to the backend first, receives a backend `uid`, writes the local system metadata and `SPEC.md` snapshot, and only then can install `{ uid, version }` into one or more targets. Offline drafts may exist inside the macOS app's private data model, but they are not visible to agent harnesses and cannot be installed into target registries until published.

The target-level registry uses this thin reference schema:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://spellbook.raddus.dev/schemas/target-instruction-registry.schema.json",
  "title": "Spellbook Target Instruction Registry",
  "type": "object",
  "additionalProperties": false,
  "required": ["schema_version", "agent", "instructions"],
  "properties": {
    "schema_version": {
      "const": 1
    },
    "agent": {
      "type": "string",
      "minLength": 1
    },
    "instructions": {
      "type": "array",
      "items": {
        "$ref": "#/$defs/instruction_ref"
      }
    }
  },
  "$defs": {
    "instruction_ref": {
      "type": "object",
      "additionalProperties": false,
      "required": ["uid", "version"],
      "properties": {
        "uid": {
          "type": "string",
          "minLength": 1
        },
        "version": {
          "type": "integer",
          "minimum": 1
        }
      }
    }
  }
}
```

An example target-level registry file is:

```json
{
  "schema_version": 1,
  "agent": "codex",
  "instructions": [
    {
      "uid": "remote-stable-id",
      "version": 2
    }
  ]
}
```

The system-level registry uses the full versioned metadata schema:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://spellbook.raddus.dev/schemas/system-instruction-registry.schema.json",
  "title": "Spellbook System Instruction Registry",
  "type": "object",
  "additionalProperties": false,
  "required": ["schema_version", "instructions"],
  "properties": {
    "schema_version": {
      "const": 1
    },
    "instructions": {
      "type": "array",
      "items": {
        "$ref": "#/$defs/instruction"
      }
    }
  },
  "$defs": {
    "instruction": {
      "type": "object",
      "additionalProperties": false,
      "required": ["uid", "version", "name", "description", "trigger"],
      "properties": {
        "uid": {
          "type": "string",
          "minLength": 1
        },
        "version": {
          "type": "integer",
          "minimum": 1
        },
        "name": {
          "type": "string",
          "minLength": 1
        },
        "description": {
          "type": "string",
          "minLength": 1
        },
        "trigger": {
          "type": "string",
          "minLength": 1
        },
        "tags": {
          "type": "array",
          "items": {
            "type": "string",
            "minLength": 1
          },
          "uniqueItems": true
        }
      }
    }
  }
}
```

An example system-level registry file is:

```json
{
  "schema_version": 1,
  "instructions": [
    {
      "uid": "remote-stable-id",
      "version": 1,
      "name": "Instruction name",
      "description": "What this instruction helps the agent do.",
      "trigger": "Use when this instruction should activate.",
      "tags": ["instruction"]
    },
    {
      "uid": "remote-stable-id",
      "version": 2,
      "name": "Instruction name",
      "description": "What this updated version helps the agent do.",
      "trigger": "Use when this updated instruction should activate.",
      "tags": ["instruction"]
    }
  ]
}
```

The target-level `manifest.json` tells the resolver which registry belongs to each enabled agent and where to find system-level state:

```json
{
  "schema_version": 1,
  "name": "spellbook-agent-context",
  "type": "agent-context-package",
  "version": "0.1.0",
  "entrypoints": {
    "instruction_registries": {
      "codex": "codex.registry.json",
      "claude": "claude.registry.json"
    },
    "installed_registry": "~/.spellbook/registry/registry.json",
    "known_targets": "~/.spellbook/registry/targets.json",
    "diagnostics": "~/.spellbook/registry/errors.json"
  },
  "paths": {
    "target_package": ".agent-context/",
    "system_registry": "~/.spellbook/registry/",
    "instruction_store": "~/.spellbook/instructions/"
  },
  "resolver": {
    "command": "~/.spellbook/bin/spellbook-agent-context"
  },
  "loader": {
    "activation": "trigger_match",
    "read_order": [
      "resolver_list_triggers",
      "resolver_read_matching_specs"
    ]
  }
}
```

The managed Spellbook block inside each harness file must stay small. For example, the Codex block should instruct the agent to:

- Call `~/.spellbook/bin/spellbook-agent-context list-triggers --target <cwd> --agent codex` for every task.
- If the resolver is unavailable, exits before returning usable JSON, or returns malformed JSON, report that in chat and continue without Spellbook-loaded instructions.
- Report any resolver diagnostics in chat.
- Inspect returned triggers and decide which instructions apply.
- For each matching instruction, call `~/.spellbook/bin/spellbook-agent-context read-spec --target <cwd> --agent codex --uid <uid> --version <version>`.
- Apply the returned instruction content.
- Suggest useful future instructions in chat only; do not write suggestion files or durable instruction state.

The resolver accepts `--target` as any file or directory inside the intended target. It walks upward to the nearest `.agent-context/manifest.json`; the nearest package wins. If no package is found, Spellbook loading is skipped with a diagnostic. All resolver operations are target-scoped and agent-scoped, so `read-spec` must reject or diagnose a request for an instruction that is not pinned in that target's registry for that agent.

The resolver returns JSON envelopes. `list-triggers` returns resolved trigger metadata plus diagnostics:

```json
{
  "instructions": [
    {
      "uid": "remote-stable-id",
      "version": 2,
      "name": "Instruction name",
      "description": "What this instruction helps the agent do.",
      "trigger": "Use when this instruction should activate.",
      "tags": ["instruction"]
    }
  ],
  "diagnostics": [
    {
      "type": "missing_instruction_version",
      "severity": "warning",
      "uid": "missing-id",
      "version": 1,
      "message": "Target references missing-id@1, but that version is not installed."
    }
  ]
}
```

`read-spec` returns the matching instruction body plus diagnostics:

```json
{
  "instruction": {
    "uid": "remote-stable-id",
    "version": 2,
    "name": "Instruction name",
    "content": "# Instruction Body\n..."
  },
  "diagnostics": []
}
```

Resolver exit codes mean:

- `0`: valid JSON returned; diagnostics may still be present.
- `1`: operational error; valid JSON should be returned when possible.
- `2`: invalid CLI usage.
- `3`: target context not found.
- `4`: malformed registry or manifest.
- `5`: internal resolver error.

If stdout is valid JSON, the harness reports diagnostics and continues according to the payload. If stdout is not valid JSON or the command is missing, the harness reports resolver failure and continues without Spellbook-loaded instructions.

Missing pinned instruction versions are soft-skipped for the current agent run and included in resolver diagnostics for chat visibility. Malformed target registries or manifests are hard failures for Spellbook loading, but they do not block the user's task; the agent reports the problem and continues without Spellbook-loaded instructions.

The macOS app is the authoritative writer of system diagnostics. It records known target harnesses in `~/.spellbook/registry/targets.json` when a user installs Spellbook into a target. On startup it scans known targets and rewrites `~/.spellbook/registry/errors.json` from scratch as a current-state diagnostics snapshot.

An example `targets.json` file is:

```json
{
  "schema_version": 1,
  "targets": [
    {
      "id": "stable-local-target-id",
      "target_root": "/Users/agruning/Documents/raddus-spellbook",
      "agent_context": ".agent-context/manifest.json",
      "harnesses": [
        {
          "agent": "codex",
          "file": "AGENTS.md",
          "registry": "codex.registry.json"
        },
        {
          "agent": "claude",
          "file": "CLAUDE.md",
          "registry": "claude.registry.json"
        }
      ],
      "added_at": "2026-08-14T00:00:00Z",
      "last_scanned_at": "2026-08-14T00:00:00Z"
    }
  ]
}
```

An example `errors.json` file is:

```json
{
  "schema_version": 1,
  "errors": [
    {
      "type": "missing_instruction_version",
      "severity": "warning",
      "target_root": "/Users/agruning/Documents/raddus-spellbook",
      "agent": "codex",
      "uid": "missing-id",
      "version": 1,
      "message": "Target references missing-id@1, but that version is not installed.",
      "detected_at": "2026-08-14T00:00:00Z"
    }
  ]
}
```

The startup scan should validate that each target path exists, each harness file exists, `.agent-context/manifest.json` exists and is valid, the manifest includes each selected agent registry, each agent registry exists and is valid, every `{ uid, version }` target reference exists in the system registry, every referenced `~/.spellbook/instructions/<uid>/<version>/SPEC.md` file exists, the resolver binary exists, and the managed Spellbook block is present in each harness file. If a target path no longer exists, the app records a stale-target diagnostic rather than deleting the target automatically.

The macOS app flow for adding a target is:

- User chooses a target directory.
- The app scans for supported harness files: `AGENTS.md`, `AGENT.md`, and `CLAUDE.md`.
- The user enables one or more harnesses.
- The app maps harness files to agent keys, such as `AGENTS.md` to `codex`, `AGENT.md` to `agent`, and `CLAUDE.md` to `claude`.
- The app creates or updates `.agent-context/manifest.json`.
- The app creates or updates an independent thin registry for each enabled agent.
- The app inserts or updates the managed Spellbook block in each selected harness file.
- The app records the target and harnesses in `targets.json`.

Multiple harness files in one target are supported. Each agent gets its own registry by default. The app may offer a convenience action to copy installed instruction references from another agent's registry, but registries remain independent afterward.

Instruction versions are immutable snapshots. A target can stay pinned to version `1` while another target moves to version `2`. Publishing an update through the macOS client creates a new backend version and writes the corresponding local metadata and `SPEC.md` snapshot. The client may then offer to install that version into one or many target-level registries.

## Considered Options

Store full instruction bodies or trigger metadata in every target package.

This would make a target more self-contained, but it would duplicate instruction bodies and metadata, make updates harder to audit, and weaken the distinction between "installed on this machine" and "enabled for this target."

Automatically activate all system-level installed instructions.

This would reduce target setup, but it would make agent behavior depend on the user's whole local library rather than the target's explicit configuration. Target registries should be the opt-in boundary.

Use `uid`-only target references.

This would make target registries even smaller, but it would make instruction versions float with the system-level library. Target behavior should stay pinned until the macOS client explicitly upgrades the installed reference.

Allow local-only instruction identities in target registries.

This would support offline installation, but it would make project registries machine-specific. Target registries should be portable by using backend `uid`s only; local drafts can remain private to the app until published.

Let agents write staged suggestions or archive files.

This previously produced low-quality durable state and forced harnesses to learn filesystem write rules. Suggestions should be chat-only, and durable instruction state should be written by the macOS app.

Fall back to manual file resolution when the resolver is missing.

This would improve resilience, but it would put too much file topology and error-handling logic into every harness block. Missing resolver should be visible in chat, then the task should continue without Spellbook-loaded instructions.

## Consequences

Target packages remain small and portable, but they depend on the system-level instruction store containing each referenced `uid` and version.

The macOS client becomes responsible for creating, publishing, installing, upgrading, scanning, and repairing instruction state across targets.

The resolver becomes the single read path for agent harnesses, which keeps harness instructions small and makes runtime diagnostics consistent.

The agent can discover and apply only the instructions that a target explicitly references for its current agent, making activation deterministic and reviewable.

Agents can still suggest useful future instructions in chat, but they cannot silently create durable local instruction state.
