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
value one of them already carries. `sync --check` adds `IS_SYNC_CHECK`: the engine
renders as it always does, compares every snapshotted path with what the render
left, restores the snapshot whatever the answer, and writes `same` or `differs`
to that file. A check changes no file, so the restore is not a failure path.

`engine/lib/contract.sh` owns the permanent top-level `schema_version` key, its
compatibility guard, and the stable `IS_STATUS` / `IS_RC_*` contract: `0` ok,
`1` error, `2` config missing, `3` ambiguous, `4` ahead, `5` aborted incomplete,
`6` needs update. Those numbers are public — the CLI and the meta-skills branch on
them, so never renumber one. `sync --check` alone reuses `2` for `out-of-date`,
which the engine never emits.

Preserve a command's real status with `rc=0; cmd || rc=$?`. Writing
`if ! cmd; then rc=$?` captures the negation instead, so a `6` arrives as `1` and the
caller loses the reason it must act on.

A list that decides what gets rendered must fail closed. `read_source_artifact_files`
fills `IS_SOURCE_FILES` in the caller's shell for that reason: a shorter list is
indistinguishable from a smaller project, so an enumeration that cannot answer has to
stop the run rather than shorten the answer. Never stream such a list out of a process
substitution — `done < <(producer)` discards the producer's exit status, and a pipe
write cut short (bash reports EINTR as `printf: write error: Interrupted system call`)
then reaches the adapter as fewer files, which renders an incomplete output that still
reports `IS_STATUS=ok`. Assemble in the current shell and check every pipeline that
feeds it.

## Rule routing

Always-on rules are inlined once into `AGENTS.md`. Cursor, Copilot, Codex, Pi and
OpenCode consume that file, so their adapters omit always-on rules from tool-specific
channels; path-scoped rules use native channels where those exist. Claude Code does
not consume `AGENTS.md`, so its adapter receives every rule.

The `agents` target is therefore required whenever an enabled target relies on
`AGENTS.md`. Adding an adapter means updating that list in `engine/sync.sh` in the
same change.

Tool-specific limits and diagnostics stay inside their adapter. Shared reporting
may expose measurements, but it does not interpret adapter policy. Compact sync
preserves generic context measurements and actionable adapter warnings.

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

A per-file loop never spawns a process per file: on Git Bash for Windows one fork
costs tens of milliseconds, so per-file awk/cp/mv turned large projects into
minutes of pure process creation. Batch the loop through the helpers built for
this — `finalize_output_files`, `finalize_copy_files`, `frontmatter_index`,
`emit_wrapped_bodies`, `copy_skill_bundle_dirs` / `copy_skill_bundle_dirs_for`,
`lint_frontmatter_files` — and read the manifest through `load_yaml_lists` /
`load_yaml_list` / the targets cache so a section is parsed once per run. The
single-file forms remain for cold paths and project adapters.

`$(...)` forks too, even around a shell function. A reader on a path every sync
takes has a `_var` form that returns through a variable — `read_schema_version_var`,
`engine_version_var`, `get_model_default_var`, `map_effort_var`,
`agents_output_path_var`, `count_matching_files`, `load_model_tiers` — and callers
there use it; the printing form wraps it, so there is still one parser.
`read_source_artifact_files` runs its `find | sort` once per section and replays
the answer to later callers while the engine sets `IS_SOURCE_FILES_MEMO`, which
is safe only because no output may land in a source. Adapters that list sources
with in-shell globs spawn nothing; moving them onto the helper would change their
locale-ordered listing to byte order.

Built-in adapters render concurrently (decision 0011): the plan comes from the
contract, so the contract has to tell the truth about order. Adapters whose
`managed` paths meet run as one chain; an adapter that reads another adapter's
output during sync declares `requires` on it, or it can run before that output
exists. Background work in `sync.sh` goes on `SYNC_BG_PIDS` and is reaped, never
killed, before anything is restored. `INTELLIGENCE_SYNC_SERIAL=1` is the serial
escape hatch.

`engine/adapters/_template.sh` is excluded from shellcheck because its `<name>`
placeholders parse as input redirection until they are scaffolded.

The adapter contract and the artifact formats are documented in
`packages/sync/references/adapters.md` and `packages/sync/references/conventions.md`.
