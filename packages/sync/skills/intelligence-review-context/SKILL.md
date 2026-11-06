---
name: intelligence-review-context
description: "Audit rules, agents, and skills and propose behavior-preserving reductions"
argument-hint: "[rules|agents|skills|all] [compact]"
agent: intelligence-architect
context: fork
background: false
---

# Review project context

Audit the intelligence layer and return proposals. Work from the arguments and
the files alone and ask nothing: in Claude Code this skill runs as a subagent that
sees none of the conversation. Review and compaction analysis are read-only, so
never sync or edit. Accepted changes go through `intelligence-update-context`;
this skill owns their review criteria.

## Audit

1. Read `<manifest>` and enumerate its configured rule, agent, and skill sources.
   Read the `intelligence-authoring` rule and
   `<module>/references/conventions.md`. Review project-owned sources; an installed
   package finding, an entry naming a package's directory however spelled,
   belongs upstream. In a package's own repository, review its
   authoritative source tree. Do not audit generated output prose. Its byte count
   is the metadata-only exception.
2. Record source line and byte counts, and git history when available: first
   addition, last edit, and edit count. Find incoming references before proposing
   an archive. Resolve the shared agents output from the manifest and measure its
   bytes. Mark missing or stale measurements; do not regenerate output during
   analysis.
3. Read and apply [references/audit-checks.md](references/audit-checks.md). Reuse
   these generic checks in any project-specific audit. Check subtraction before
   proposing a split or rewrite: remove an unnecessary artifact, merge overlapping
   owners, or replace prose with an existing deterministic gate where possible.
4. When the arguments ask to compact context, or the audit proposes a merge, move,
   deletion, scoping change, or size reduction, read
   [references/compaction.md](references/compaction.md) and its principles. Build
   the behavior ledger and draft the structural reduction before wording changes.
   Review must preserve complete language and the layer's behavioral contract.
5. Present a punch-list: finding, target file, proposed action, concrete draft,
   reason, and priority (1: duplication, misplaced or unnecessary artifacts;
   3: description or naming polish). Compaction items also show the authoritative
   owner, behavior preserved, estimated byte savings, and any change to meaning,
   scope, or loading. Surface unverified reasons without silently rewriting them.
   A finding about what an artifact says is a wrong or missing outcome, a
   contradiction, or a stale reference; an edge case its outcome already covers
   is no finding.

## Hand the decision back

6. End the result with the decision that belongs to the person: which numbered
   items to accept, one by one or as a named batch, with the items you recommend
   and the reason for each. Accepted items go to `/intelligence-update-context`
   with their drafts. For compaction items, include what that skill needs to
   verify them: the behavior ledger, the baseline counts with any missing
   rendered measurement marked, and the steps under *Verify the accepted result*
   in the compaction reference, copied into the result. The review is complete
   when this evidenced punch-list is returned.
