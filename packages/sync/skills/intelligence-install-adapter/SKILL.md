---
name: intelligence-install-adapter
description: "Research, implement, and enable a tool adapter"
argument-hint: <target-name>
agent: intelligence-operator
---

# Install an adapter

The CLI owns scaffolding and manifest edits. This skill owns the part a
program cannot infer: how the target tool represents rules, agents, and skills.

## Steps

1. Try `intelligence target enable $ARGUMENTS`. If it succeeds, continue at
   step 5. If it reports that the adapter is missing, scaffold the
   project-owned adapter with `intelligence adapter new $ARGUMENTS`.

2. Research the tool's current, authoritative documentation for instruction,
   agent, and skill formats: discovery paths, frontmatter/schema, scoping,
   naming, and whether it reads `AGENTS.md`. Record links and distinguish
   verified behavior from assumptions.

3. Implement `sync_to_$ARGUMENTS()` in the scaffolded adapter. Follow the
   bundled adapter contract and existing adapters for shared helpers. Keep all
   writes beneath the configured output, make re-runs idempotent, and make the
   cleanup block name only paths this adapter owns. Add only those owned paths
   to `.gitignore`; shared roots remain trackable.

4. Run `bash -n` on the adapter, then
   `intelligence target enable $ARGUMENTS`. If the tool relies on `AGENTS.md`,
   enable `agents` first when the CLI guard requests it.

5. Run `intelligence sync $ARGUMENTS`. Require `IS_STATUS=ok`, inspect the
   generated files against the researched format, and run the tool's own
   validator when one exists. Report the evidence, output paths, and any
   unsupported artifact type explicitly.
