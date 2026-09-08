---
name: dev-build-adapter
description: "Implement and verify built-in or project-owned Intelligence adapters"
argument-hint: "<adapter-name> [built-in|project]"
---

# Build an Intelligence adapter

This repository-only skill owns adapter research and implementation. It is excluded
from the distributed sync package. Consumers retain the public CLI and adapter guide.

1. Resolve the repository root, project profile, engine adapter directory, public
   adapter guide, artifact conventions, and test entry points from the product and
   engine rules. Read the applicable architecture decisions. Determine whether the
   request changes a built-in here or a project adapter in an explicitly named
   disposable fixture. Inspect the existing adapter before proposing a replacement.

2. Research the target tool's current authoritative documentation for discovery
   paths, schemas, frontmatter, rule scoping, names, agents, skills, and whether it
   reads `AGENTS.md`. Record links and dated evidence in the public guide; distinguish
   verified support from assumptions and unsupported artifact types.

3. For a new built-in, use the engine's adapter template in its adapter directory.
   For a project adapter, run `intelligence adapter create <name>` in the fixture.
   Implement `adapter_contract_<name>()` and `sync_to_<name>()` using the public
   contract and shared helpers. Keep every written path declared and reruns
   idempotent. Distinguish exclusive `owned` from shared `managed` paths; declare
   required targets, legacy and preserved inputs, ignores, and includes as needed.
   Keep output within validated destinations and preserve hand-authored siblings.

4. Update built-in discovery/defaults and dependency declarations where the engine
   rules require them. Reuse batched source enumeration, finalization, skill-bundle,
   and shared-output helpers from the closest built-in. Correct ignore policy in
   the contract rather than hand-editing generated policy. Resolve movable fixture
   paths from its manifest; implementation remains in source, never generated output.

5. Add regression coverage for generated formats, declared ownership, dependencies,
   preserved siblings, and failures. Run `bash -n` on the completed adapter.
   In a disposable project, enable required
   targets and the adapter through the CLI; require `IS_STATUS=ok`, inspect every
   supported artifact against the researched format, run the tool's validator when
   available, and finish with `intelligence status --check`.

6. Run a second sync and compare output to prove idempotence. Deliberately fail a
   later test adapter and prove all earlier adapter-owned output is restored.
   Exercise disable/remove retention and approved cleanup without deleting a shared
   root. Use isolated fixtures for failure and cleanup checks, then run the
   project's verification gate over the completed implementation and tests.

7. Update the public adapter guide and applicable examples with supported mappings,
   limitations, and evidence. Report changed source, test results, output paths,
   rollback proof, and any tool validation that was unavailable. Changes to an
   existing adapter receive the same verification as a new one.
