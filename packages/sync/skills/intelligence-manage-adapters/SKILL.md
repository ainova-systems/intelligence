---
name: intelligence-manage-adapters
description: "Enable, disable, or remove adapters and assess generated-output cleanup"
argument-hint: "<enable|disable|remove> <adapter-name>"
agent: intelligence-operator
---

# Manage adapters

Operate existing built-in or project adapters through the CLI. Resolve the requested
action and adapter name as separate arguments; never pass the whole skill argument
string as an adapter name. The CLI owns target state, dependency checks, ignores,
scaffolding, and sync. Adapter implementation follows the public adapter guide.

1. Run `intelligence adapter list` and identify the requested adapter, its source,
   state, and output. If it does not exist, explain that implementation is needed
   and point to `<module>/references/adapters.md`. This package does not include
   an implementation skill; do not invoke a repository-only skill in consumers.

2. For **enable**, run `intelligence adapter enable <name>`. If it requires the
   shared `agents` target, enable that dependency first. Enabling performs a full
   sync; require `IS_STATUS=ok` and inspect output for the selected adapter. Correct
   Git policy in the contract instead of hand-editing `.gitignore` or ignoring a
   shared output root.

3. For **disable**, run `intelligence adapter disable <name>`. This changes target
   state and deliberately retains output. For **remove**, read and retain the
   contract's ownership information first so later cleanup remains attributable.
   Disable an enabled project adapter, then run `intelligence adapter remove <name>`
   (use `--apply` for already-approved non-interactive removal). Built-in adapter
   source cannot be removed.

4. Treat generated-output cleanup separately from disabling or removing source.
   Inspect the contract's owned and managed paths, including dependencies and any
   shared consumers. Present the exact deletion list and obtain approval before
   deleting output. Preserve shared roots and hand-authored siblings. Remove obsolete
   ignore entries only when no remaining adapter needs them. After disabling or
   removing, sync remaining enabled adapters when any exist, and require
   `IS_STATUS=ok` from that sync.

5. Verify with `intelligence adapter list` and `intelligence status --check`:
   requested target state is correct, retained files are intact, and only approved
   adapter-owned output was deleted. Report state, output paths, and any remaining
   implementation or cleanup work. Preserve CLI refusals instead of recreating
   lifecycle mechanics manually.
