---
name: intelligence-review-context
description: "Audit rules, agents, and skills and propose behavior-preserving reductions"
argument-hint: "[rules|agents|skills|all] [compact]"
agent: intelligence-architect
---

# Review project context

Audit the intelligence layer and propose improvements. Review and compaction
analysis are read-only: do not sync or edit while inspecting. Accepted changes
go through `intelligence-update-context`; this skill owns their review criteria.

## Audit

1. Read `<manifest>` and enumerate its configured rule, agent, and skill sources.
   Read the `intelligence-authoring` rule and
   `<module>/references/conventions.md`. Review project-owned sources; an installed
   package finding belongs upstream. In a package's own repository, review its
   authoritative source tree. Do not audit generated output prose. Its byte count
   is the metadata-only exception.
2. Record source line and byte counts, and git history when available: first
   addition, last edit, and edit count. Find incoming references before proposing
   an archive. Resolve the shared agents output from the manifest and measure its
   bytes, or reuse a fresh `CONTEXT:` summary. Mark missing or stale measurements;
   do not regenerate output during analysis.
3. Read and apply [references/audit-checks.md](references/audit-checks.md). Reuse
   these generic checks in any project-specific audit. Check subtraction before
   proposing a split or rewrite: remove an unnecessary artifact, merge overlapping
   owners, or replace prose with an existing deterministic gate where possible.
4. When the user asks to compact context, or the audit proposes a merge, move,
   deletion, scoping change, or size reduction, read
   [references/compaction.md](references/compaction.md) and its principles. Build
   the behavior ledger and draft the structural reduction before wording changes.
   Review must preserve complete language and the layer's behavioral contract.
5. Present a punch-list: finding, target file, proposed action, concrete draft,
   reason, and priority (1: duplication, misplaced or unnecessary artifacts;
   3: description or naming polish). Compaction items also show the authoritative
   owner, behavior preserved, estimated byte savings, and any change to meaning,
   scope, or loading. Surface unverified reasons without silently rewriting them.

## Accepted changes

6. The user accepts items individually; a batch acceptance may cover named items.
   Pass accepted proposals to `/intelligence-update-context`, with the behavior
   ledger and additional checks. Reuse existing approval for those exact changes.
   If fresh rendered measurements are needed, capture them only after apply is
   authorized and before editing; record `<sync-cmd> --compact` output and require
   `IS_STATUS=ok`. The authoring skill performs the final batch sync and status check.
7. Verify each accepted finding against the resulting sources. For reductions,
   complete the ledger comparison, measurements, and behavioral evaluation in
   the compaction reference. Report each artifact as pass, fixed (what), or
   flagged (for whom), plus unresolved proposals. A read-only review ends with
   the evidenced punch-list; an apply run ends only after its checks complete.
