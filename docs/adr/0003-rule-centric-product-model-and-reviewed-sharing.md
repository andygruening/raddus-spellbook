---
status: draft
---

# Rule-Centric Product Model and Reviewed Sharing Workflow

Raddus Spellbook will present itself as a control panel for reusable AI behavior, not as an `AGENTS.md` or instruction-file manager. The product model will shift from instructions, spells, projects, and published lists toward rules, packs, workspaces, and reviewed public sharing.

The underlying harness-file approach from ADR-0002 remains conceptually valid: workspaces opt into specific behavior by pinning a `uid` and `version` in a managed harness block, and the harness opens a local `SPEC.md` only when its trigger applies. ADR-0003 changes the product and storage vocabulary from instructions to rules, so the canonical local executable rule path becomes `~/.spellbook/rules/<uid>/<version>/SPEC.md`.

## Issue

Spellbook's current technical model is useful, but its product language and flows still assume a developer mindset. Users are asked to understand instructions, triggers, project targets, local installs, published spells, and markdown bodies before the app has helped them express what they actually want: a repeatable way for AI to behave in different kinds of work.

The app should answer a simpler user problem:

> How do I make my AI remember how I want to work, apply those expectations in the right places, and share useful behavior patterns safely?

## Decision

Spellbook will use the following product hierarchy:

- A **workspace** is a local context where AI behavior applies. It replaces the user-facing term "project." A workspace may still map to a local directory and one or more harness files.
- A **rule** is the atomic reusable behavior unit. It replaces the user-facing terms "instruction" and "spell." A rule receives a backend `uid` as soon as its backend draft is created.
- A **pack** is a versioned public-library bundle of pinned rule versions. Packs are not installed into workspaces as durable workspace state; installing a pack is a batch operation that installs or updates the pack's included rules in a selected workspace.
- **Settings** contains account, storage, diagnostics, review/admin controls, and advanced implementation details.

The left sidebar will use this order:

1. Workspaces
2. Packs
3. Rules
4. Settings

Spellbook will remove the standalone Published tab. Public discovery will live inside the Rules and Packs areas as filters, sections, or library views. Public browsing should show only the latest approved version of each rule or pack by default; older approved versions remain reachable through version history or pack pins.

The Rules area will show all rules across lifecycle states, including drafts, rules in review, approved public rules, rules needing changes, archived rules, and installed local rules. The default user-facing view should be "My Rules," with filters such as All, Drafts, In Review, Published, Needs Changes, Archived, and Installed.

## Rule Lifecycle

Rules are draft-first and online-first. Creating a rule requires sign-in and creates a backend draft with a canonical `uid` and version number. That draft is private to the creator, but it is installable by the creator into their own workspaces through the normal rule install flow.

Rule states:

- **Draft**: Private, editable, backend-owned, and available for private use by the creator.
- **Submitted for Review**: Awaiting admin review. The creator may still edit and resubmit the same version while it is in review.
- **Needs Changes**: Returned by an admin with review notes. The same version remains editable and can be resubmitted.
- **Approved**: Frozen, immutable, and available in the public library for other users.
- **Withdrawn**: Removed from review by the creator before approval.
- **Archived**: Hidden from active authoring and installation surfaces without deleting history.

Private use and public availability are separate. A user can create, install, update, and use private draft rules in their own workspaces without admin approval. Admin review gates public discoverability and installation by other users.

A rule version is mutable until it is approved. While mutable, reinstalling or updating that draft version overwrites `~/.spellbook/rules/<uid>/<version>/SPEC.md` with the latest backend draft content. Once a version is approved, it becomes immutable. Any edit after approval creates the next draft version for the same rule `uid`. The existing approved version remains available while the next version is drafted or reviewed.

If an approved draft appears in the macOS app as "Approved, ready to finish," the Finish action should ensure the approved rule version exists in the local rule store and clear the local draft/finish state. Finish does not add the rule to any workspace harness automatically.

## Rule Creation Flow

Spellbook will replace the markdown-first creation flow with a guided rule builder. The builder should ask plain-language questions first and generate the underlying rule markdown from the answers.

The creation flow should include:

1. **Purpose**: What should this rule help with?
2. **Applies When**: When should the AI follow this rule?
3. **Desired Behavior**: How should the AI behave?
4. **Avoided Behavior**: What should the AI avoid doing?
5. **Permission Boundary**: Should the AI ask before editing files, deleting content, publishing, sending, or making irreversible changes?
6. **Examples**: Example requests where the rule should apply and, optionally, requests where it should not apply.
7. **Preview**: A plain-language summary plus the generated markdown rule body.

Technical users may use an Advanced Markdown view, but the default flow should not require writing markdown, knowing the `SPEC.md` format, or understanding agent harness files.

The current trigger concept should remain in the underlying rule model, but the user-facing label should become "Applies when." Trigger debugging or a dedicated Trigger Lab is out of scope for this decision.

## Packs

Packs are first-class public-library artifacts, not tags, saved searches, local installs, or workspace state. The Packs tab lists approved public packs. Spellbook should not maintain a local `packs.json` registry or mark a workspace as having a pack installed. A workspace has rules; it does not have packs.

A pack should contain:

- Name
- Description
- Intended audience or use case
- Included rules with pinned `uid` and `version` references
- Suggested workspace type
- Compatibility metadata for supported AI tools or harnesses
- Lifecycle state
- Creator
- Changelog or release notes
- Review notes when applicable

Pack states should mirror rule states where practical: Draft, Submitted for Review, Needs Changes, Approved, Withdrawn, and Archived.

Installing a pack into a workspace is a batch rule install operation:

1. The user chooses a workspace.
2. Spellbook shows the pack's included rules before installing.
3. For each included rule, Spellbook labels whether the workspace already has that exact version, a different version, or no version of that rule.
4. When the user confirms, Spellbook installs the pack-pinned version of each rule locally under `~/.spellbook/rules/<uid>/<version>/SPEC.md`, overwriting any existing local copy of that same rule version with the backend copy.
5. Spellbook updates the workspace harness block to reference the pack-pinned rule versions.

The pack's pinned versions win during install. If the workspace already references an older, newer, or otherwise different version of an included rule, installing the pack updates the workspace to the pack-pinned version. Customization detection, content-hash checks, conflict resolution, and transactional partial-failure handling are out of scope for this decision.

Pack versions are immutable once approved. If a pack includes another user's approved rule version, that dependency remains pinned until the pack creator submits and receives approval for a new pack version. Public pack browsing shows only the latest approved pack version by default, while older approved versions remain available through history or existing links.

Example packs:

- Careful Code Assistant
- No Surprise Changes
- Brand Voice Guardrails
- Client Proposal Writer
- Academic Feedback Assistant
- Founder Operating Style

## Review Workflow

Public rules and packs require admin review before they appear in the public library.

Review happens in the Spellbook web app and uses the same email OTP sign-in method as the rest of Spellbook. Authorization is stored in the backend database with a minimal `user` or `admin` role. Admins can approve submissions, including their own submissions.

Drafts for both rules and packs are stored on the backend, not in `~/.spellbook/drafts`. The macOS app and web app both edit backend drafts. Offline authoring is not part of this decision.

Admin review should check:

- The "Applies when" text is clear and not overly broad.
- The behavior guidance is specific enough to be useful.
- The rule does not contain secrets, private customer data, or credentials.
- The rule does not include unsafe or deceptive guidance.
- The rule does not make misleading claims about what an AI system can guarantee.
- The artifact is not spam, trivial duplication, or a low-quality generic prompt.
- Examples, if present, match the stated behavior.
- Pack contents are coherent and do not contain obvious contradictions.

Admin decisions should produce visible review notes for the creator. For v1, the review outcomes are:

- **Approve**: make the reviewed rule version or pack version public.
- **Needs Changes**: send the whole reviewed rule or pack back to the creator with notes.

Pack review is atomic. A pack submission can include already-approved public rules by any creator and new draft rules owned by the submitting creator. Existing approved rules are reused unchanged. New draft rules included in the pack are reviewed with the pack. The reviewer either approves the entire pack submission, which also approves every included new rule version as an individually discoverable public rule, or sends the entire pack submission back with notes. A reviewer cannot approve one new rule from a pack submission without approving the pack.

An approved public pack may only point to approved rule versions. If a creator submits a new version of an approved pack, the older approved pack version remains publicly available until the new pack version is approved.

## User-Facing Vocabulary

Use these names in the app:

| Current term | New term |
| --- | --- |
| Project | Workspace |
| Target | Workspace, or target only in implementation docs |
| Instruction | Rule |
| Spell | Rule |
| Published spells | Public rules or library |
| Trigger | Applies when |
| SPEC.md | Rule body, or Advanced Markdown in technical views |
| Install instruction | Add rule |
| Install into target | Add to workspace |
| `~/.spellbook/instructions` | `~/.spellbook/rules` |

Implementation files may continue to use older names during migration, but new UI, product copy, documentation, and API concepts should move toward the new vocabulary.

## Argument

The rule-centric model better matches the problem Spellbook is trying to solve. Non-technical users do not primarily want to manage agent files. They want AI systems to preserve their preferences, working style, and safety boundaries across different contexts.

Draft-first authoring lowers the cost of creating personal rules. Assigning a backend `uid` at draft creation keeps private installation and later public review on the same identity model. Reviewed public sharing keeps the public library trustworthy. Packs make installation easier because users often want a complete behavior profile, not a single isolated rule.

Keeping private use separate from public approval is important. If every useful rule has to pass review before the creator can use it, Spellbook becomes a publishing workflow instead of a behavior control panel. Review should protect other users, not block personal use. Backend-owned drafts with immediate `uid`s allow private use while preserving a clean public review path.

The separate Published tab creates an unnecessary split between local and public concepts. Rules should expose ownership, installation, and review state inside one coherent area. Packs should remain public-library curation units and batch installers rather than becoming another workspace-level state model.

## Implications

The macOS app will need navigation changes:

- Rename Projects to Workspaces.
- Add Packs.
- Rename Instructions to Rules.
- Remove Published as a top-level tab.
- Move public discovery into Rules and Packs.

The local rule store will need to migrate from `~/.spellbook/instructions/<uid>/<version>/` to `~/.spellbook/rules/<uid>/<version>/`. The app may keep compatibility aliases during migration, but newly written harness entries should use rule terminology and the `rules` path. ADR-0002 remains conceptually valid, but its instruction-path contract is renamed by this decision.

The backend data model will need to move from `spells` and `spell_versions` toward rules and packs. At minimum, the model needs:

- Users with an email identity and `user` or `admin` role.
- Rules as canonical identity records with owner metadata.
- Rule version records with lifecycle/review status, generated markdown body, metadata, and version number.
- Packs as canonical identity records with owner metadata.
- Pack version records with lifecycle/review status and pinned included rule versions.
- Review notes or review events visible to creators.

Remote review status is distinct from local installation status. Local installation remains the presence of a rule version in `~/.spellbook/rules` and the workspace harness block.

The backend will need draft, submission, review, and public listing APIs. Ordinary public listing filters should return only latest approved rules and latest approved packs by default. Creators should still be able to see their own drafts, in-review items, review notes, and approved history.

The app will need a guided builder that can produce the same versioned local rule body currently stored as `SPEC.md`. ADR-0002's managed-block approach can remain, but generated paths should migrate to the `~/.spellbook/rules` root.

The web app should become a public library for approved rules and packs, with direct links that open the macOS app when available.

The migration should be staged. Internal symbols may continue to use `Spell` or `Instruction` temporarily, but the user-facing model should move first so product decisions stop reinforcing the old terminology.

## Consequences

Spellbook becomes more accessible to non-technical users because the main task is creating and applying rules, not managing markdown files.

The product gains a clearer trust model. Public content is reviewed, while private content remains fast and personal.

Packs create a higher-level sharing unit and make the public library more useful than a list of isolated prompts, without creating another kind of workspace installation state.

The app takes on more product complexity: lifecycle state, review queues, admin tools, pack membership, version review, backend draft editing, and migration copy.

The underlying harness-managed-block mechanism does not need to change immediately, but the local path and new schemas should move to rule terminology. Future schemas and APIs should avoid baking in the old "spell" or "instruction" terminology unless kept as compatibility aliases.

## Out of Scope

This decision does not add Trigger Lab or semantic trigger testing.

This decision does not require changing the ADR-0002 managed harness block format immediately, beyond migrating generated local file paths from `~/.spellbook/instructions` to `~/.spellbook/rules`.

This decision does not define the final database schema, final admin UI, review-attempt history model, or a pack installation conflict-resolution algorithm.

This decision does not support offline draft authoring.

This decision does not add local pack installation state, local pack provenance, or a durable `packs.json` registry.

This decision does not add local customization detection for pack installs.

This decision does not define monetization, organization/team sharing, or enterprise policy controls.

## Related Decisions

- ADR-0002: App-Written Spellbook Instruction Indexes in Harness Files
- ADR-0001: Local Agent Context Instruction Structure, superseded by ADR-0002 for the runtime resolver-loading contract

## Implementation Task Packet

Implementation task briefs for parallel agent work live in `docs/adr/0003/`.
