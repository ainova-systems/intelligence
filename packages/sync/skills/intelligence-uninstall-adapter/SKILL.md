---
name: intelligence-uninstall-adapter
description: "Disable a tool target and assess its generated output"
argument-hint: <target-name>
agent: intelligence-operator
---

# Disable an adapter target

1. Run `intelligence target disable $ARGUMENTS`. The CLI changes only the
   manifest and deliberately keeps generated output.
2. If the user also wants generated files removed, inspect the adapter's
   cleanup block to identify exactly what it owns. Show that list and obtain
   approval before deleting it; never delete a shared output root.
3. Remove obsolete `.gitignore` entries only when no remaining target needs
   them, then run `intelligence sync` for the targets still enabled.
4. Verify `IS_STATUS=ok`, the target is disabled, retained files are intact,
   and only explicitly approved adapter-owned output was removed. Report both
   removed and deliberately retained paths.
