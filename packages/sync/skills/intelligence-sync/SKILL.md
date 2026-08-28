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
4. On a probable Intelligence defect, first ask whether to collect a sanitized
   issue draft; collect nothing before approval and never use telemetry. Include
   only approved CLI/version, expected/actual behavior, and safe error details—
   no confidential or project-specific data. Show the draft and obtain separate
   approval before filing. If declined, ask whether the opt-out is for this
   session, a user/gitignored dev-project profile, or a shared team policy; save
   it only with separate approval. Put team policy in a project-owned rule, and
   never invent a profile path or infer the intended scope.
