---
name: intelligence-update
description: "Interpret an update plan and verify breaking post-conditions"
argument-hint: "[@scope/name]"
agent: intelligence-operator
---

# Update intelligence

The CLI owns planning and application. This skill interprets the plan, reads
the changelog across an engine-version gap, obtains approval, and verifies the
result.

## Steps

1. Run `intelligence update --preview` (or
   `intelligence update $ARGUMENTS --preview` for one named package). Use its
   CLI, project, and package sections as the complete plan; do not re-resolve
   versions independently.

2. If the CLI or project engine version would change, read the authoritative
   `CHANGELOG.md` at `https://github.com/ainova-systems/intelligence` for every
   release in **`current < release <= target`**. If it is unavailable, stop
   before changing versions. Turn every crossed `### Breaking` item into a
   post-condition to verify.

3. Show the plan and breaking checklist to the user. The command without a
   mode also shows the plan and prompts; after approval, use `--apply` for an
   unambiguous non-interactive execution.

4. If the plan reports a newer global CLI, run exactly the npm command it
   prints after approval, then rerun `intelligence update --preview` with the
   new executable. Apply the resulting plan with `intelligence update --apply`,
   or `intelligence update $ARGUMENTS --apply` when one package was requested.

5. Run `intelligence status --check`, then `intelligence sync`. Require final
   `IS_STATUS=ok`. Verify every crossed breaking post-condition directly and
   report any item that cannot be machine-verified.

Report versions before and after, the applied plan, post-condition results,
and any remaining action. On a refusal, preserve the full error and stop
instead of invoking hidden lifecycle operations.
