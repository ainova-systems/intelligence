---
name: intelligence-install-adapter
description: "Research, implement, and enable a tool adapter"
argument-hint: <adapter-name>
agent: intelligence-operator
---

# Install an adapter

The CLI owns adapter inventory, scaffolding, target state, and sync. This skill
owns the judgement a program cannot infer: how the target tool represents
rules, agents, and skills.

## Steps

1. Run `intelligence adapter list`. If `$ARGUMENTS` already exists, enable it
   with `intelligence adapter enable $ARGUMENTS`; that command also runs a full
   sync. Continue at verification.

2. For a missing adapter, research the tool's current authoritative
   documentation: discovery paths, frontmatter/schema, scoping, naming,
   agents, skills, and whether it reads `AGENTS.md`. Record links and separate
   verified behavior from assumptions.

3. Run `intelligence adapter create $ARGUMENTS`, then keep
   `adapter_contract_$ARGUMENTS()` aligned with every path the adapter writes
   and implement `sync_to_$ARGUMENTS()` in the scaffolded project adapter. Follow
   `<module>/references/adapters.md` and the closest built-in. Keep writes beneath
   the configured output, make reruns idempotent, distinguish exclusive
   `owned` paths from marker-based/shared `managed` paths, and declare exact
   legacy, preserved, dependency, ignore, and include records when applicable.

4. Run `bash -n` on the project adapter, then
   `intelligence adapter enable $ARGUMENTS`. If the CLI says the adapter
   requires `agents`, enable that adapter first.

   The CLI derives generated-output ignores from the adapter contract. Do not
   edit `.gitignore` manually; correct the contract when policy is wrong, and
   never ignore a shared output root.

5. Require `IS_STATUS=ok`, inspect generated files against the researched
   format, deliberately fail a later test adapter to prove transactional
   rollback when contributing a built-in, run the tool's validator when one exists, and finish with
   `intelligence status --check`. Report evidence, output paths, and any
   unsupported artifact type.
