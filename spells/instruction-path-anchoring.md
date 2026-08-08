# Instruction Path Anchoring

**Role:** Software Developer

**Category:** Agent instruction file mutation

## Requirement

Instructions that tell agents to write registry or companion files must anchor those paths to the selected instruction file's parent directory, with any template placeholder replaced by the concrete selected instruction file path.

## Trigger

Use this when reviewing or changing managed blocks in AGENTS.md, AGENT.md, CLAUDE.md, or similar local agent instruction files.

## Safe Path

Avoid ambiguous `./` wording when the agent may run from a different project root. Use a clear placeholder such as `FILE_TARGET` in the managed-block template, replace it with the selected instruction file path during preview/apply, and state that `spells.json` and `spells/<spell>.md` resolve relative to that file's parent directory, not the process working directory or project root.
