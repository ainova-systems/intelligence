# 0002 — Consolidate the Intelligence CLI around lifecycle and resource groups

Date: 2026-08-26
Status: accepted

## Context

The first Intelligence CLI exposed implementation steps as separate commands: package restore,
project upgrade, legacy conversion, deep diagnosis, update preview, and target-state editing. The operations
were valid, but users had to remember which near-duplicate command matched the project's current
state. That preserved the shape of the legacy Intelligence Sync procedures instead of presenting one Intelligence product model.

## Decision

1. The public lifecycle is `init`, `sync`, `update`, `package`, `adapter`, `status`, and `registry`.
   `help` and `version` remain ordinary informational entry points.

2. `init` is idempotent and state-aware: it creates a new Intelligence project, transactionally converts an
   eligible legacy Intelligence Sync project, or aligns/restores an existing Intelligence project. `--preview` is
   read-only and `--apply` is the explicit non-interactive path.

3. A project-aware mutation runs one shared preflight. If an installed CLI is newer than the Intelligence
   project, the preflight applies internal idempotent alignment before the requested operation.
   CI refuses implicit tracked alignment and requires a reviewed local `init --apply` diff.

4. `sync` restores a missing package store strictly from `intelligence.lock` before rendering.
   Restore is not a separate public operation and never re-resolves ranges.

5. `update` is the only update-planning surface. It reports the CLI npm channel, project
   alignment, and movable package ranges. `--preview` stops without writes, no flag asks for
   confirmation, and `--apply` executes without asking.

6. Package and adapter operations live under their nouns: `package add|remove|list|search` and
   `adapter list|create|enable|disable|remove`. Deep diagnosis is `status --check`.

7. The old public commands and aliases are removed, not deprecated: `install`, `upgrade`,
   `migrate`, `outdated`, `target`, `doctor`, and top-level `add|remove|list|search`.

## Consequences

- Developers learn one normal flow: install the CLI, run `init`, edit or add content, then `sync`.
- A fresh clone needs only `sync`; reproducibility remains lock-driven and fail-closed.
- Updating the global npm package cannot edit unknown projects. The first later mutating project
  call aligns each project, while CI makes that tracked change explicit.
- Internal scripts retain small deterministic mechanics, but the dispatcher cannot invoke them.
- Meta-skills interpret plans, changelog post-conditions, tool formats, and status output instead
  of reimplementing lifecycle mechanics.

## Rejected

- **Keep every mechanical command public.** Complete but too costly to remember, with several
  commands differing only by discovered project state.
- **Keep old names as aliases.** That would preserve two vocabularies indefinitely and make docs,
  automation, and support ambiguous.
- **Run project alignment during `npm update`.** npm has no project working directory or list of
  repositories, so it cannot safely find or modify project manifests.
- **Let CI auto-commit alignment.** Hidden tracked changes in a render step are not reviewable and
  can make generated output appear valid against uncommitted schema state.
