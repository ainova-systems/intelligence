---
name: intelligence-uninstall-adapter
description: "Disable an adapter and assess its generated output"
argument-hint: <adapter-name>
agent: intelligence-operator
---

# Uninstall an adapter

1. Run `intelligence adapter list`, then
   `intelligence adapter disable $ARGUMENTS`. Disabling changes target state
   and deliberately keeps generated output.
2. If generated files should also be removed, inspect the adapter's cleanup
   block to identify exactly what it owns. Show that list and obtain approval
   before deleting it; never delete a shared output root.
3. For a project adapter that should be deleted, run
   `intelligence adapter remove $ARGUMENTS` after it is disabled. This prompts
   by default (`--apply` is the explicit non-interactive form) and also keeps
   generated output. Built-in adapter source cannot be removed.
4. Remove obsolete `.gitignore` entries only when no remaining adapter needs
   them. Sync the remaining enabled adapters when any exist.
5. Verify with `intelligence adapter list` and `intelligence status --check`:
   the adapter is disabled or removed as requested, retained files are intact,
   and only approved adapter-owned output was deleted.
