# Changelog

All notable changes to Intelligence are recorded here.

Legacy Intelligence Sync history remains in its [archive](https://github.com/ainova-systems/intelligence-sync/blob/main/CHANGELOG.md).

## [0.11.0] — 2026-08-24

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

- Validated package names, source URLs, refs, paths, and dispatcher command names before filesystem or Git operations.
- Staged package changes and project conversion before replacing live state; locked restoration refetches and verifies SHAs.
- Added containment checks, unpredictable temporary paths, YAML escaping, interrupt rollback, and fail-closed source validation.

### Fixed

- Fixed tilde ranges, annotated-tag resolution, empty lockfile paths, and comment-preserving manifest edits.
- Fixed stale package sources during update, registry repoints under unchanged tags, and partial package replacement.
- Fixed package/project source precedence so project artifacts override same-named package artifacts.
- Fixed project-conversion rollback of `.gitignore` and preview handling without mutating the live legacy project.
- Fixed legacy conversion to reject conflicting Intelligence state and roll back every failure before verified sync.
- Fixed lifecycle alignment to refuse a missing package lock instead of creating a partial replacement.
- Fixed explicit `init --apply` alignment under CI and filtered sync of disabled adapters.
- Added committed locks to runnable examples so smoke tests exercise frozen store restoration directly.
