---
name: intelligence-sync
description: "Sync intelligence to enabled tool targets"
agent: intelligence-operator
context: fork
---

# Sync intelligence

1. Run `intelligence sync` (or `intelligence sync <target>` when one target was
   requested).
2. Require the final status to be `IS_STATUS=ok`; relay per-target counts and
   any model-drift or unsynced-source warnings.
3. On `IS_STATUS=needs-update`, invoke the `intelligence-update` flow. For any
   other failure, report the status and detail without editing generated output.
