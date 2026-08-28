---
paths:
  - "engine/**"
description: "Engine boundaries: pure synchronization, the status contract, rule routing and the adapter interface"
---

# Sync engine

`engine/sync.sh` sources `engine/lib/common.sh` and `engine/lib/contract.sh`,
discovers built-in plus project-owned adapters, and runs the enabled targets. It is a
pure synchronizer: it never changes a schema and never fetches a package. Schema and
content alignment is the CLI's preflight — `init --apply` is the reviewed path, and
`update` folds alignment into its plan.

## The contract the CLI exports

`IS_CLI=1`, `CONFIG_FILE`, `REPO_ROOT`, `IS_CONTENT_REL`, `IS_MODULE_REL`,
`IS_MANIFEST_NAME`, `IS_SYNC_CMD`, `IS_PROTECTED_DIRS`. Read them; never rederive a
value one of them already carries.

`engine/lib/contract.sh` owns the permanent top-level `schema_version` key, its
compatibility guard, and the stable `IS_STATUS` / `IS_RC_*` contract: `0` ok,
`1` error, `2` config missing, `3` ambiguous, `4` ahead, `5` aborted incomplete,
`6` needs update. Those numbers are public — the CLI and the meta-skills branch on
them, so never renumber one.

Preserve a command's real status with `rc=0; cmd || rc=$?`. Writing
`if ! cmd; then rc=$?` captures the negation instead, so a `6` arrives as `1` and the
caller loses the reason it must act on.

## Rule routing

Always-on rules are inlined once into `AGENTS.md`. Cursor, Copilot, Codex, Pi and
OpenCode consume that file, so their adapters omit always-on rules from tool-specific
channels; path-scoped rules use native channels where those exist. Claude Code does
not consume `AGENTS.md`, so its adapter receives every rule.

The `agents` target is therefore required whenever an enabled target relies on
`AGENTS.md`. Adding an adapter means updating that list in `engine/sync.sh` in the
same change.

## Adapters

One file defines both sides of the versioned interface:
`adapter_contract_<name>(configured_output)` and
`sync_to_<name>(repo_root, config_file, output_dir)`. Built-ins live in
`engine/adapters/`; project adapters live in `<content-dir>/adapters/`, survive
upgrades, and override a built-in of the same name with a visible note.

The contract declares every owned and shared managed write path, the required target,
onboarding legacy and preserved paths, and Git policy. Backup, rollback,
enable/disable checks and `status --check` all read that declaration — never restate
ownership in a CLI case statement.

Every emitted text file passes through `finalize_output_file`; skill directories are
copied with `copy_skill_bundle`; adapters sharing `.agents/skills/` use
`sync_open_skill_dirs`. `validate_output_path` is the mandatory guard against writes
into a source, the store, the repository root, or outside the repository. Never
delete a whole tool root when the adapter owns only subpaths — hand-authored sibling
files live there. A full sync is transactional across every selected adapter path.

`engine/adapters/_template.sh` is excluded from shellcheck because its `<name>`
placeholders parse as input redirection until they are scaffolded.

The adapter contract and the artifact formats are documented in
`packages/sync/references/adapters.md` and `packages/sync/references/conventions.md`.
