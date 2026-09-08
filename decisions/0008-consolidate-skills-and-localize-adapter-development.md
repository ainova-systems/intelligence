# 0008 — Consolidate skills and keep adapter development in the repository

Date: 2026-09-08
Status: accepted

## Context

The shipped catalog exposed twelve skills. Three artifact-creation workflows
repeated discovery, naming, and final sync. Session learning dispatched observed
workflows to another skill; auditing and compaction shared their analysis but had
separate apply procedures. Adapter installation combined operating an existing
target with researching and writing executable adapter code.

The team wants fewer discoverable workflows while retaining their functional
checks. It approved moving guided adapter implementation to this repository,
without creating a second content package.

## Decision

1. Ship seven skills: `intelligence-update-context`,
   `intelligence-learn-from-session`, `intelligence-review-context`,
   `intelligence-learn-from-repository`, `intelligence-manage-adapters`,
   `intelligence-sync`, and `intelligence-update`.
2. Context updating owns authoring for rules, agents, and skills. Type-specific
   steps and templates load conditionally from its own references. Session
   learning, onboarding, and accepted review findings pass proposals to that
   owner rather than maintaining separate write procedures.
3. Session learning includes observed workflow extraction. Review includes
   compaction proposals and remains read-only during analysis. Compaction retains
   its behavior ledger, reasons, load conditions, measurements, and evaluation;
   accepted changes preserve unapproved content and use one final batch sync.
4. Keep first-time onboarding separate from later learning. Preserve migration
   evidence, interrupted-setup recovery, approval scope, final header replacement,
   packaging checks, and separate backup-removal approval.
5. Adapter management handles existing target state and approved output cleanup.
   The project-owned `dev-build-adapter` skill handles implementation, current
   tool-format research, regression tests, idempotence, and transactional rollback.
   The public CLI and adapter contract documentation remain available to consumers.
6. Keep package content at `packages/sync/` and development workflow content at
   `intelligence/skills/`. No development package or new public CLI command is
   introduced. This repository consumes its local skill through its existing sources.

## Consequences

The default catalog falls from twelve entries to seven; this repository adds one
local adapter skill. Removed slash commands are a breaking content change with
an explicit migration map and changelog post-conditions. All source bindings,
documentation, and generated output move together. Deliberate downstream
overrides require content comparison because renaming can end their override
relationship.

Functional preservation is checked at each owner: artifact formats and bindings
in context updating; evidence and workflow sequence in session learning; semantic
equivalence and language quality in review; migration in onboarding; retained
output and approval scope in adapter management. Sync and update retain their
existing status, failure, and release-gap checks.

## Rejected

- A sibling development package: the approved scope needs an internal contributor
  workflow and does not need another installable package or release relationship.
- Shipping compatibility wrapper skills indefinitely: that preserves the crowded
  registry. The migration map carries the old vocabulary without registering it.
- Merging repository onboarding with session learning: their evidence and recovery
  requirements differ, and the separation prevents partial setup becoming a lesson.
