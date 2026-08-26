---
name: intelligence-sync
description: "Sync intelligence to enabled adapters"
agent: intelligence-operator
context: fork
---

# Sync intelligence

1. Run `intelligence sync` (or `intelligence sync <adapter>` when one adapter
   was requested). For Intelligence projects, this command first aligns project schema/content
   with the installed CLI and restores a missing package store strictly from
   `intelligence.lock`.
2. Require final `IS_STATUS=ok`; relay per-adapter counts and any model-drift
   or unsynced-source warnings.
3. In CI, a required tracked project upgrade is intentionally refused. Report
   the instruction to run `intelligence init --apply` locally, review and
   commit its diff; never bypass the gate. A frozen restore refusal means the
   manifest and lock disagree or a pinned ref moved—report it without
   hand-copying package content.
