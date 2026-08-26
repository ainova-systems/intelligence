# Changelog

All notable v2 changes to Intelligence are recorded here.

The v1 history remains in the [intelligence-sync archive](https://github.com/ainova-systems/intelligence-sync/blob/main/CHANGELOG.md).

## [0.11.0] — 2026-08-24

### Breaking

- [ ] The project has a root `intelligence.yaml`; the v1 `<umbrella>/config.yaml` is gone.
- [ ] `intelligence.lock` is committed and `.intelligence/` is gitignored.
- [ ] The manifest uses `packages:`; no v1 `packs:` entries or mirrors remain.
- [ ] `@ainova-systems/sync` is pinned exactly to the CLI engine version from `ainova-systems/intelligence`, path `packages/sync`.
- [ ] No vendored v1 engine remains under the project's intelligence content directory.
- [ ] `intelligence install --frozen`, `intelligence doctor`, and `intelligence sync` succeed.

### Added

- Added the `@ainova-systems/intelligence` npm CLI for project initialization, package lifecycle, synchronization, diagnostics, and v1 migration.
- Added root `intelligence.yaml` manifests, committed `intelligence.lock` files, and gitignored `.intelligence/packages/` stores.
- Added registry-only package-name resolution through the manifest's ordered trust list.
- Added explicit `github:` and `git+` package sources for installs without a registry.
- Added stable-tag semver resolution for exact, caret, tilde, and `latest` ranges; `ref:` pins branches and commits.
- Added offline restoration from the lockfile and strict manifest, lock, source, and SHA checks with `install --frozen`.
- Added `intelligence search` to list trusted-registry packages and their local state.
- Added transactional `intelligence migrate`, including `--dry-run`, verification, backup, and rollback.
- Added `@ainova-systems/sync` as the exact-pinned engine-content package, seeded offline from the npm bundle.
- Added `<manifest>` and `<sync-cmd>` content tokens for CLI-driven synchronization.
- Added `adapter new` and `target enable|disable` for project-adapter scaffolding and manifest target state.
- Added npm build, prerelease/stable publishing gates, cross-platform package smoke tests, and five hermetic CLI test suites.

### Changed

- Split v1 and v2: `ainova-systems/intelligence-sync` remains the v1 archive; `ainova-systems/intelligence` is the v2 product.
- Replaced the vendored product layout with `cli/`, `engine/`, and `packages/sync/`; projects no longer contain engine scripts.
- Kept engine executable code in `engine/` and package content in `packages/sync/` with one repository and npm-bundle layout.
- Made registries the only name resolver; the CLI has no built-in catalogue or package-name-to-GitHub guessing.
- Made `intelligence init` create a minimal manifest, detect targets, and add `@ainova-systems/sync` unless `--bare` is used.
- Made `intelligence update` move ranged packages only; `intelligence upgrade` moves the engine-content pin and schema stamp together.
- Kept all engine meta-skills, including `intelligence-sync` and `intelligence-update`, in the CLI-installed sync package.
- Reduced meta-skills to CLI interpretation, changelog verification, and tool-format judgement; deterministic mechanics now live in commands.
- Made v1 migration require the final v1 schema; older projects must run their archived `update.sh` before migration.
- Removed v1 packs, mirrors, engine-side remote fetching, `update.sh`, the v1 migration chain, layout branches, and vendored compatibility jobs.

### Security

- Validated package names, source URLs, refs, paths, and dispatcher command names before filesystem or git operations.
- Staged installs, updates, and migrations before replacing live state; frozen installs refetch and verify locked SHAs.
- Added containment checks, unpredictable temporary paths, YAML escaping, interrupt rollback, and fail-closed source validation.

### Fixed

- Fixed tilde ranges, annotated-tag resolution, empty lockfile paths, and comment-preserving manifest edits.
- Fixed stale package sources during update, registry repoints under unchanged tags, and partial package replacement during re-add.
- Fixed package/project source precedence so project artifacts override same-named package artifacts.
- Fixed migration rollback of `.gitignore` and dry-run handling without mutating the live v1 project.
