---
name: intelligence-sync
description: "Sync intelligence to enabled adapters"
agent: intelligence-operator
context: fork
background: false
---

# Sync intelligence

1. Run `intelligence sync` (or `intelligence sync <adapter>` when one adapter
   was requested). For Intelligence projects, this command renders the project
   at its committed versions and first restores a missing package store strictly
   from `intelligence.lock`. Unchanged inputs and outputs can reuse a successful run.
   Use `--force` when a fresh render or a new search for unconfigured source
   directories is requested; an unchanged run replays the previous diagnostics.
2. Require final `IS_STATUS=ok`; relay reported counts and any integrity,
   model-drift or unsynced-source warnings.
3. A warning that project versions trail the CLI is not a failure: relay it.
   `IS_STATUS=needs-update` (exit 6) means the project needs a migration only
   `intelligence update` applies; report that, and never edit the manifest or
   lock by hand to get past it. A frozen restore refusal means the
   manifest and lock disagree or the locked commit cannot be verified or restored;
   report it without hand-copying package content.
4. On a probable Intelligence defect, end the result with a block headed
   `Probable Intelligence defect` that holds only safe facts: the CLI and engine
   versions from `intelligence version`, the command, the expected and the actual
   behavior, and error text with nothing confidential or specific to the project.
   Follow it with an issue draft built from those facts alone. The result is the
   only place they go: send and file nothing, and use no telemetry. Filing the
   draft is a separate request the person makes.
