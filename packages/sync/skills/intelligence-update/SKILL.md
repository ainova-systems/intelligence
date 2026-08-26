---
name: intelligence-update
description: "Interpret available updates, apply the right CLI flow, and verify breaking post-conditions"
agent: intelligence-operator
---

# Update intelligence

The CLI owns resolution, installation, migrations, and synchronization. This
skill supplies the judgement around those commands: understand the version
gap, choose `update` versus `upgrade`, and verify what a breaking change says
must be true afterward.

## Steps

1. Run `intelligence outdated`. Treat it as the read-only plan: package rows
   move with `intelligence update`; a CLI row means the executable must be
   updated before the project can be upgraded. Also run `intelligence status`
   to read the project's `sync_version` and bundled engine version.

2. Read the authoritative `CHANGELOG.md` in
   `https://github.com/ainova-systems/intelligence` for every release in the
   engine gap **`current < release <= target`**. If it is unavailable, report
   that and stop before changing versions. Collect each item under
   `### Breaking` as a post-condition to verify, not as prose to summarize.
   Show the proposed commands and breaking checklist before making a write.

3. Choose the smallest applicable flow:

   - Package ranges can move, but the engine does not: `intelligence update`
     (or `intelligence update <name>` when the request names one package).
   - The installed CLI is already the target but `sync_version` or the
     engine-content package is behind: `intelligence upgrade`.
   - The CLI itself is behind: update `@ainova-systems/intelligence` to the
     reported target with the package manager that installed it, then run
     `intelligence upgrade`.
   - Both kinds move: upgrade the CLI and project first, then update package
     ranges. Never use `update` to move the engine-content package; `upgrade`
     owns its exact pin and the schema stamp.

4. Capture the last `IS_STATUS=<code> [IS_DETAIL=...]` line from upgrade/sync:

   | Status | Interpretation |
   |---|---|
   | `ok` | Continue to verification. |
   | `needs-update` | Run `intelligence upgrade`; if it persists afterward, stop with the full output. |
   | `ahead-of-engine` | Do not downgrade; update the CLI to one that understands the stamped schema. |
   | `config-missing` | This is not an initialized v2 project; use `intelligence init`, or `intelligence migrate` for a final-schema v1 project. |
   | `aborted-incomplete` | The guarded operation left the project uncommitted; retry once, then stop with the full output. |
   | `ambiguous` or `error` | Report `IS_DETAIL` and stop. Do not improvise around the guard. |
   | no status | The command failed before the engine contract; show its output and stop. |

5. Verify with `intelligence doctor`, then `intelligence sync`. Require
   `IS_STATUS=ok`. For every crossed `### Breaking` item, test its stated
   post-condition directly; if it is not machine-verifiable, name that gap.
   Confirm the final `sync_version`, engine-content pin, and package versions
   match the plan from step 1.

Report versions before and after, commands chosen, each breaking
post-condition as pass/fail, and any remaining action.
