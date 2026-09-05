# Changelog

All notable changes to Intelligence are recorded here.

Legacy Intelligence Sync history remains in its [archive](https://github.com/ainova-systems/intelligence-sync/blob/main/CHANGELOG.md).

## [0.11.7]

### Changed

- Let a CLI older than the project keep working when `schema_version` is ahead by a minor or patch version: every project-aware command prints one warning naming both versions and proceeds, `status --check` reports the state as a note, and nothing restamps the project or re-pins its engine content downward. Only a newer major version is still refused with `ahead-of-engine` and exit code 4.

## [0.11.6]

### Fixed

- Resolved a `ref:`-pinned package against its remote commit during `intelligence update`, so a branch or `HEAD` pin follows upstream instead of reporting "up to date" forever while a fresh clone's frozen restore refused it as moved.
- Reported an unreachable remote or a ref deleted upstream as unchecked rather than up to date, and a `ref:` naming a commit as a pin that cannot move.

### Changed

- Printed the resolved commit beside a `ref:` pin in `intelligence package list`, `intelligence status --check` and the update plan.

## [0.11.5]

### Fixed

- Warned when a Codex-enabled `AGENTS.md` exceeds its project-instruction byte threshold, including during compact syncs, with one manifest field that accepts `false` to disable the warning or a positive byte count to change its trigger.
- Resolved default, directory and file forms of the shared agents output through one path rule, and stopped omitted target fields from borrowing values from the next manifest target.

### Added

- Reported always-on and custom source-context byte totals, file counts, and the rendered `AGENTS.md` size after every successful sync, including compact mode.
- Added a recommended 32 KiB `AGENTS.md` budget to the intelligence-layer audit.
- Added `/intelligence-compact-context` for approval-gated semantic compaction of rules, agents, and skills using scope, ownership, and progressive disclosure before prose shortening.

## [0.11.4]

### Changed

- Batched the sync engine's per-file processing into one awk pass per adapter section, cutting process count from O(files × adapters) to O(adapters); a full multi-adapter sync on Windows dropped from minutes to seconds and generated output stayed byte-identical.
- Cached manifest section and target parsing for the duration of a sync run, and memoized repeated output-path validations.
- Shared `.agents/skills/` content is now copied once per sync; the Codex, Pi and opencode adapters replay the first population instead of re-copying every skill.
- Pruned the unsynced-directory scan so it no longer walks `.git`, `node_modules`, `vendor`, `dist` or generated tool outputs.

## [0.11.3]

### Fixed

- Advanced stale npm `next` tags with stable releases without replacing a newer preview line.

## [0.11.2]

### Changed

- Made stable npm installation the documented default while keeping `next` for prerelease testing.

### Fixed

- Preserved multiline target header block scalars when enabling an adapter missing from the manifest.

## [0.11.1]

### Changed

- Quarantined backed-up legacy root instructions before the first render; failed or interrupted sync restores them exactly.
- Added consent-gated, sanitized GitHub issue drafting to `/intelligence-sync`, with session, personal, project-local, or team opt-out scope.

### Fixed

- Made settings reinclusions effective after pre-existing broad tool-directory ignores and made `status --check` detect overridden rules.
- Stopped suggesting `git rm --cached` for legacy paths already quarantined as worktree deletions.
- Made npm package smoke fail if repository-only CLI tests enter the published tarball.
- Made repository purity require the committed `AGENTS.md` entry point explicitly.

## [0.11.0]

### Breaking

- [ ] Project automation uses only `init`, `sync`, `update`, `package`, `adapter`, `status`, and `registry` lifecycle commands.
- [ ] The project has a root `intelligence.yaml`; the legacy nested `config.yaml` and vendored engine are gone.
- [ ] `intelligence.lock` is committed and `.intelligence/` is gitignored.
- [ ] The manifest uses `packages:`; no legacy `packs:` entries or mirrors remain.
- [ ] Each manifest package stores only requested `version` or `ref`; resolved source details remain in `intelligence.lock`.
- [ ] The manifest has one top-level `schema_version` and no obsolete `sync_version` key.
- [ ] `schema_version` and the exact `@ainova-systems/sync` pin match the installed CLI engine.
- [ ] Package artifacts use `<content-dir>` and adapters use `IS_CONTENT_REL`; no `<umbrella>` or `IS_UMBRELLA_REL` tokens remain.
- [ ] `intelligence sync` followed by `intelligence status --check` succeeds.

### Added

- Added versioned adapter contracts for owned, shared, legacy, preserved, required, ignored, and tracked paths.
- Added initial-onboarding backup manifests so recovery skills can distinguish original files from generated output.
- Added `/intelligence-learn-from-repository` for approval-gated repository onboarding after initialization or legacy conversion.
- Added the `@ainova-systems/intelligence` npm CLI with seven public lifecycle commands.
- Added root manifests, committed package locks, and restorable gitignored package stores.
- Added `intelligence init` as the single entry point for new setup, legacy Intelligence Sync conversion, project alignment, restoration, and first sync.
- Added `intelligence sync` restoration of a missing package store from the committed lock before rendering adapters.
- Added `intelligence update` plans covering the installed CLI, project schema/content, and package ranges.
- Added `update --preview`, interactive confirmation by default, and `update --apply` for non-interactive application.
- Added `package add|remove|list|search` for the complete package lifecycle.
- Added `adapter list|create|enable|disable|remove` for built-in and project-owned adapters.
- Added `status` for a quick project summary and `status --check` for deep consistency checks.
- Added registry-only name resolution through the manifest's ordered trust list and explicit `github:` or `git+` sources.
- Added stable-tag semver resolution, exact locks, offline bundled sync content, and frozen SHA verification during restore.
- Added npm publishing gates, cross-platform package smoke tests, and five hermetic CLI test suites.

### Changed

- Made multi-adapter sync transactional; a failure restores every selected adapter path to its exact pre-sync state.
- Split learning by lifecycle: `/intelligence-learn-from-repository` owns onboarding; `/intelligence-learn-from-context` captures later session lessons.
- Preserved custom root `AGENTS.md` in the initial backup and linked it from generated onboarding context until migration finishes.
- Added visible start/completion progress around init's compact sync, then printed adapter, Git policy, learning, and starter-package guidance.
- Ordered starter-package installation before repository learning and added package/project duplicate review.
- Kept newly enabled adapters inside the visible target list, before following commented manifest sections.
- Made repository learning migrate legacy root instructions into project-owned rules instead of preserving parallel entry points.
- Preserved existing AI instruction paths before first sync and restored format-aware, approval-gated onboarding migration guidance.
- Restored legacy tool-marker detection for `.cursorrules`, `.agents/`, and Copilot instruction, agent, and skill paths.
- Added `sync --compact`, which prints final status on success and full diagnostics on failure.
- Changed npm publication to run only when a matching tagged GitHub Release is published from `main`.
- Renamed the early CLI manifest schema stamp from `sync_version` to `schema_version`; `intelligence init` aligns RC manifests automatically.
- Reduced every manifest package entry to requested `version` or `ref`; resolved URL/path, tag/ref, and SHA now live only in `intelligence.lock`.
- Separated the products: `ainova-systems/intelligence-sync` archives legacy Intelligence Sync; `ainova-systems/intelligence` contains Intelligence.
- Consolidated package, adapter, project-state, conversion, alignment, and restore operations behind the seven lifecycle commands.
- Made mutating project-aware commands align older Intelligence schema and sync content before continuing.
- Made CI refuse tracked auto-upgrades and direct users to run `intelligence init --apply` locally, review, and commit the result.
- Made registries the only package-name resolver; the CLI has no built-in catalogue or name-to-GitHub guessing.
- Kept all engine meta-skills, including `intelligence-sync` and `intelligence-update`, in the CLI-installed sync package.
- Reduced meta-skills to CLI interpretation, changelog verification, and external tool-format judgement.
- Separated executable code in `engine/` from installable content in `packages/sync/`; projects contain no engine scripts.
- Removed legacy Intelligence Sync packs, mirrors, engine-side fetching, `update.sh`, migration chain, layout branches, and vendored compatibility jobs.

### Security

- Added Intelligence exclusions to existing publisher/build ignore files and exact untrack commands for Git-indexed ignored paths.
- Refused adapters with missing, malformed, unsupported, or unsafe ownership contracts before enable or sync.
- Validated package names, source URLs, refs, paths, and dispatcher command names before filesystem or Git operations.
- Staged package changes and project conversion before replacing live state; locked restoration refetches and verifies SHAs.
- Added containment checks, unpredictable temporary paths, YAML escaping, interrupt rollback, and fail-closed source validation.

### Fixed

- Excluded init-owned `_backup/` paths from unsynced-source warnings.
- Fixed tilde ranges, annotated-tag resolution, empty lockfile paths, and comment-preserving manifest edits.
- Fixed stale package sources during update, registry repoints under unchanged tags, and partial package replacement.
- Fixed package/project source precedence so project artifacts override same-named package artifacts.
- Fixed project-conversion rollback of `.gitignore` and preview handling without mutating the live legacy project.
- Fixed legacy conversion to reject conflicting Intelligence state and roll back every failure before verified sync.
- Fixed lifecycle alignment to refuse a missing package lock instead of creating a partial replacement.
- Fixed explicit `init --apply` alignment under CI and filtered sync of disabled adapters.
- Added committed locks to runnable examples so smoke tests exercise frozen store restoration directly.
