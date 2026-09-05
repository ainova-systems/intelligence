# 0006 — Expand skill interoperability while preserving project guarantees

Date: 2026-09-05
Status: accepted — architectural direction; schema and runtime changes need concrete designs

## Context

Intelligence manages project rules, agents and skills through versioned packages
and native adapters. External repositories increasingly provide useful skills in
different layouts, sometimes described by plugin manifests. Consuming that content
should not require its authors to publish an Intelligence-specific package.

The current implementation provides important boundaries: the CLI owns acquisition,
the engine reads local sources, and adapter contracts define transactional output.
There are also limitations to resolve before expanding imports:

- [Locked restore](../cli/internal/restore.sh) fetches the recorded ref and then
  compares its SHA. A moved branch prevents restoration even when the old commit
  remains available. An isolated local Git fixture confirmed this behavior.
- [Shared skill cleanup](../engine/lib/common.sh) intentionally removes every
  immediate skill directory or symlink. That current ownership contract does not
  permit another manager to safely share the destination.
- [Package wiring](../cli/lib/registry.sh) recognizes package-root `rules/`,
  `agents/` and `skills/`; it does not normalize root skills or nested catalogs.
- [Status checking](../cli/internal/check.sh) checks existence and consistency,
  rather than rehashing all installed content. [Package updates](../cli/internal/package-update.sh)
  publish package state before rendering; output rollback is not a transaction
  covering the entire package lifecycle.

Broader adapter support also needs a clear distinction between a tool that reads
skill directories and a tool with native scoped rules and custom agents. Directory
placement alone does not establish runtime compatibility.

## Decision

1. **Strengthen restore and ownership before broader installation.** Restore from
   the locked commit, verify identity before publishing content, and never replace
   an unavailable commit with current HEAD. Introduce explicit ownership for shared
   skill destinations, with a migration that preserves unknown content. Keep current
   mismatch refusal until the replacement has stronger tests and a documented backout.

2. **Normalize external content in the CLI.** Acquisition and format readers
   produce an inventory of source identity, plugin/path, component kind, display
   name, destination name, required files and compatibility status. Selected skill
   bundles become ordinary local sources for the existing engine. Keep one
   materialization path and the existing batched rendering helpers.

   Call the CLI input components **importers**, with format readers for each
   supported manifest/layout. Reserve **adapters** for the engine's output targets.
   Acquisition resolves and pins source content; a format reader interprets catalog
   and child manifests into the common inventory; selection and validation identify
   complete bundles; materialization publishes those bundles into managed local
   package storage. Existing output adapters then render them for enabled tools.
   A marketplace is a catalog input, not another output target. Remote plugin
   references go back through the CLI acquisition layer before materialization.

   Importers run during package acquisition, update or locked restoration. Ordinary
   sync reuses the stored package; enabling another output adapter does not require
   reimporting it. When sync must restore missing content, the CLI completes that
   restoration before invoking the engine. Importers do not depend on enabled targets.

   This transformation normalizes structure, metadata and resource paths. It does
   not automatically translate tool-specific prose or runtime behavior. Preserve
   supporting files and report unsupported requirements. Each input format maps to
   the common inventory, avoiding a separate converter for every input/output pair.

3. **Persist selection intent separately from resolution.** Exact skill selection,
   a source path and an output name are different identities. New upstream skills
   must not silently expand a selected subset. Every explicitly requested item must
   resolve; ambiguous normalization or missing selections fail before writes.
   Preserve deliberate project overrides while reporting unrelated collisions.

4. **Implement marketplace formats separately.** Begin with local plugin paths in
   a pinned Git repository. Claude and Cursor manifests have different path/default
   semantics; use their official specifications and dated conformance fixtures.
   Then add supported remote Git sources through the existing registry/package
   lifecycle. Pin the catalog configuration that influences selection as well as
   the plugin commit. Catalog versions do not automatically become Git tags.
   See [Claude marketplaces](https://code.claude.com/docs/en/plugin-marketplaces)
   and [Cursor plugins](https://cursor.com/docs/reference/plugins).

5. **Describe partial compatibility honestly.** Skill import does not activate
   hooks, MCP servers, custom commands, runtime variables or plugin dependencies.
   Report declared unsupported components and evident missing shared resources.
   Static analysis cannot prove arbitrary skill prose portable. Keep complete
   bundles, binary files, executable bits and safe relative resources; never copy
   contents from an escaping symlink automatically.

6. **Recommend installation for recurring work.** Team workflows use reviewed
   manifest/lock state. Temporary use is an optional evaluation and occasional-task
   path: materialize one inspectable bundle, record its source/commit/digest, and
   generate a prompt or entry point without registering skills or modifying the
   project lock. Promotion reuses the evaluated snapshot. Define temporary-file
   retention explicitly. Temporary use is not a sandbox, and prompt text does not
   enforce native permissions. Agent launching is a separate later capability.

7. **Add adapters based on current evidence and project fit.** Keep a dated
   capability inventory for skills, rules, custom agents and project/global scope.
   Distinguish native paths, detection paths and Intelligence-owned destinations.
   Consider maintained tools with substantial adoption evidence; installation
   counts, publisher-reported users and repository stars are different metrics.
   A skill-only target must not advertise full adapter support. Existing adapters
   stay supported without requiring a new popularity review.

8. **Preserve the public resource groups.** New inventory, import and temporary
   evaluation operations belong under `package`; catalog sources belong under
   `registry`; target capabilities belong under `adapter`. Concrete flags and
   schema are not defined by this record. Keep `github:...#path` semantics.

## Consequences

The CLI/engine split, requested/resolved separation and older-client policy remain
authoritative: [0001](0001-separate-legacy-intelligence-sync-from-intelligence.md),
[0002](0002-consolidate-intelligence-cli-lifecycle.md),
[0003](0003-separate-package-intent-from-resolution.md),
[0005](0005-gate-schema-compatibility-on-the-major-version.md).
An older CLI silently ignoring a selection is not safe compatibility. Design
versioned materialization and lock state before implementation; use a major release
if the contract cannot be represented safely for existing clients.

JSON parsing requires an explicit design under the zero-dependency Bash constraint.
Evaluate a maintained parser against a small CLI-only helper using the documented
Node prerequisite. The latter changes the Bash runtime boundary and requires a
separate accepted decision. Do not silently add jq/Python or parse JSON with regex.
The sync engine does not need a runtime rewrite to consume external skill bundles.

Validation must cover source/output overlap, junctions and symlinks, case collisions,
partial selection, supporting assets, retained shared consumers, unavailable refs,
unchanged-source/missing-output repair, and rollback of all state the operation
actually promises to transact. Gate changes belong in the single verification runner.

[ROADMAP.md](../ROADMAP.md) sequences these changes. This decision implements none
of them and does not authorize release timing, additional installed skills or new
native tool configuration.

## Rejected or deferred

- Whole plugin runtime emulation or execution of catalog-provided installation,
  authentication or hook commands during content discovery.
- Delegating managed installation to another package manager writing the same
  destinations, or replacing rendered copies with symlinks by default.
- Broad agent-count targets without maintained native contracts and adoption evidence.
- Global installation before project ownership and cleanup semantics are established.
- Hosted registries, artifact caches and signing infrastructure before demonstrated
  demand; HTTP sources need durable retrieval and integrity contracts first.
- Requiring publisher metadata before ordinary standard skill directories work.
