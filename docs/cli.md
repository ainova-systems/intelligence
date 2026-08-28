# The Intelligence CLI

The CLI owns a project's complete Intelligence lifecycle: initialization, legacy Intelligence Sync conversion, project alignment, package resolution, lock restoration, adapter management, consistency checks and rendering.

Install the stable CLI from npm:

```bash
npm install -g @ainova-systems/intelligence
```

## Project layout

```text
project/
├── intelligence.yaml      # manifest; commit it
├── intelligence.lock      # resolved package state; commit it
├── intelligence/          # project-owned rules, agents, skills, adapters
├── .intelligence/         # restorable package store; gitignored
├── AGENTS.md              # generated canonical context
└── .claude/ .cursor/ …    # generated native output
```

No engine code lives in an Intelligence project. Engine scripts ship with the npm CLI. Engine-owned content—the authoring rule, agents, meta-skills and package docs—is `@ainova-systems/sync`, exact-pinned to the bundled engine version and seeded from the npm bundle when versions match.

## Public commands

### `intelligence init`

Universal project entry point:

```text
intelligence init [--targets a,b] [--dir name] [--bare] [--no-sync]
                  [--preview | --apply] [--force]
```

Behavior depends on discovered project state:

| State | Default behavior | `--preview` | `--apply` |
|---|---|---|---|
| No setup | Create an Intelligence manifest, lock/store, requested adapters and first sync | Show what would be created | Create without an interactive decision |
| Legacy Intelligence Sync | Stage and display conversion, then ask before applying | Stage/verify and write nothing to the project | Apply non-interactively after verification |
| Existing Intelligence project | Align schema/content if needed, restore missing store, sync | Show alignment/restoration plan only | Apply alignment explicitly after reviewing a CI refusal locally |

`--force` applies only to archived-project conversion when a dirty worktree must be accepted deliberately. `--bare` omits `@ainova-systems/sync`; `--no-sync` stops after project state is ready.

New-project adapter selection always enables `agents`. Other adapters come only from repository markers or explicit `--targets`; the CLI never invents a tool directory.

Before first sync, init preserves existing root and tool-specific AI
instructions and preserved tool settings under the content directory's
gitignored `_backup/`. Its `manifest.tsv` declares `initial-onboarding` and
lists exact source paths and legacy entry points. Settings remain in place.
Legacy entry points are quarantined for the transactional first render; a
failure restores them exactly, while success leaves them inactive for
repository learning. The backup is removed only after separate approval and
verified output.

Legacy-project conversion requires final Intelligence Sync schema `0.10.0`. Older projects first bring themselves to that schema using their archived engine. Conversion remains transactional: stage, verify manifest/source/adapter equivalence, run a staged sync, then replace old state.

After a new setup or conversion completes, the CLI first recommends
`intelligence package add @ainova-systems/core`, then suggests
`/intelligence-learn-from-repository`. It repairs or verifies mechanical setup,
recognizes initial backup state, then performs repository analysis and
migration; no semantic proposal is applied before individual approval. The CLI
remains the only owner of
initialization and legacy conversion mechanics.

Setup announces the start and completion of its first compact sync. It then prints exact commands for reviewing
and toggling adapters and explains the generated-output version-control
choices. Installing the starter package before learning lets repository
analysis detect overlap with package-owned content. The CLI ignores restorable adapter-owned output while keeping
`AGENTS.md`, `.github/`, and shared tool settings trackable. The exact patterns
are listed in the [artifact conventions](../packages/sync/references/conventions.md#generated-output-and-version-control).
When `.vscodeignore`, `.npmignore`, or `.dockerignore` already exists, init
also adds packaging exclusions for Intelligence development context and
adapter outputs. It reports exact `git rm --cached` commands when Git already
tracks a covered path that remains in the worktree; quarantined legacy paths
are reported by Git as normal deletions instead.

### `intelligence sync`

```text
intelligence sync [adapter] [--compact]
```

For Intelligence projects, sync performs lifecycle preflight before rendering:

1. Align tracked project schema/content with the installed CLI when safe.
2. If `.intelligence/` is missing, restore it strictly from `intelligence.lock` without registry lookup or range resolution.
3. Validate each selected adapter's versioned ownership contract and required
   targets before writing.
4. Snapshot every declared owned or shared managed path, then run every enabled
   adapter or only the named enabled adapter.
5. Commit the generated state only when all selected adapters succeed. Any
   failure restores every path to its exact pre-sync state.

A filtered adapter must be enabled explicitly; naming it does not bypass target
state. Project adapters without a valid contract are refused before sync.

A missing store with no lock fails and directs the user to restore the committed
lock. In a legacy Intelligence Sync project, sync delegates to that project's own vendored
engine until conversion.

`--compact` prints only the final machine-readable status and completion line
when sync succeeds. If lifecycle preflight, restore or rendering fails, it
prints the complete captured diagnostics and preserves the original exit code.

If the manifest declares packages but `intelligence.lock` is missing, every
mutating lifecycle command fails before alignment or restoration. Restore the
committed lock; the CLI never invents a partial replacement from the packages
that happen to be locally available.

### `intelligence update`

```text
intelligence update [@scope/name] [--preview | --apply]
```

One plan covers:

- the globally installed CLI against its npm channel (`next` for a prerelease, otherwise `latest`);
- project schema and engine-content alignment against the installed CLI;
- package ranges that can move to a newer stable tag.

Modes:

| Mode | Behavior |
|---|---|
| no flag | Print the plan and ask before writes; a non-interactive shell refuses |
| `--preview` | Print the plan and write nothing |
| `--apply` | Apply project/package changes without asking, then sync |

The plan reports the npm command required to replace the global executable; it never mutates the global npm prefix itself. `ref:`-pinned packages and the exact engine-content pin do not move as ordinary ranges.

### `intelligence package`

```text
intelligence package add <spec> [--name @scope/name] [--no-sync]
intelligence package remove <name> [--force] [--no-sync]
intelligence package list
intelligence package search [term]
```

`package add` resolves, fetches, wires sources, writes the manifest/lock and syncs. Accepted specs:

- `@scope/name[@range]` through trusted registries only;
- `github:org/repo[#path]` as an explicit GitHub source;
- `git+<url>[@ref][#path]` as an explicit Git source.

Every form writes the same manifest contract: only requested `version` or
`ref`. The resolved source URL/path is recorded in the lock, not duplicated in
the manifest. Re-adding a package is the explicit way to change its source.

`package remove` removes manifest, source, lock and store state. Removing `@ainova-systems/sync` requires `--force` because it removes engine-owned meta-content from generated outputs while rendering itself remains available.

`package list` shows requested and locked state. `package search` combines what trusted registries offer with what the project has.

### `intelligence adapter`

```text
intelligence adapter list
intelligence adapter create <name>
intelligence adapter enable <name>
intelligence adapter disable <name>
intelligence adapter remove <name> [--apply]
```

- `list` shows built-in and project adapters, source, state and output; project adapters override built-ins by name.
- `create` scaffolds `<content-dir>/adapters/<name>.sh` from the bundled template and refuses to overwrite.
- `enable` updates manifest state and immediately runs a full sync so shared `AGENTS.md` context stays current.
- `disable` updates manifest state but keeps generated output for adapter-aware cleanup.
- `remove` accepts only a disabled project adapter, asks before deleting its source unless `--apply` is used, and keeps generated output.

Names match `[a-z][a-z0-9_]*`. Enabling an adapter that relies on `AGENTS.md` also requires the `agents` adapter.

### `intelligence status`

```text
intelligence status [--check]
```

Without a flag, report detected project mode, manifest/schema, lockfile, engine-content package and bundled engine. For legacy Intelligence Sync, report the vendored location and point to `intelligence init`.

`--check` performs deep consistency validation and exits nonzero for
manifest/lock divergence, missing package content, stale schema/content or
invalid sources. Frozen store restoration verifies the locked commit SHA.

### `intelligence registry`

```text
intelligence registry list
intelligence registry add <repository-url> [--force]
intelligence registry remove <repository-url>
```

Registries are an ordered project trust list. `add` verifies that the Git repository exposes `index.yaml`; `--force` records an unavailable or not-yet-published registry deliberately. The first trusted registry declaring a package name wins.

## Automatic project alignment

A newer globally installed CLI cannot update projects at npm installation time because it does not know which repositories the user owns. Instead, every project-aware mutating command passes through one shared preflight. On the first such call in an Intelligence project, the CLI applies any required idempotent schema/content alignment before continuing.

This includes normal sync, package mutations, adapter mutations and registry mutations. Read-only listing, searching, preview and ordinary status do not mutate project state.

CI is intentionally different. When `CI` is true and tracked alignment is pending, implicit preflight refuses and prints:

```text
run 'intelligence init --apply' locally, review and commit the diff
```

CI therefore never hides a schema/content change inside generated output. The committed alignment must arrive as a reviewed repository diff.

## Packages

A package name is its global identity in the manifest, lock and store (`.intelligence/packages/@scope/name/`). One version of a name may exist in a project because generated tool namespaces are flat and duplicate versions would collide artifact-by-artifact.

Whichever top-level `rules/`, `agents/` and `skills/` directories a package provides are wired into the corresponding manifest sources. Package sources precede project sources, so a same-named project artifact may override package content deliberately.

### Resolution and trust

`registries:` is the only resolver for package names. There is no built-in catalog and no `@org/name` → GitHub guessing. A name no trusted registry declares is refused with suggestions. Registry-free acquisition always uses an explicit `github:` or `git+` source.

### Versions

Stable `x.y.z` Git tags, optionally prefixed with `v`, are package versions. Ranges (`^1.2.0`, `~1.2.0`, an exact version or `latest`) match stable tags from `git ls-remote`; prerelease tags are invisible to ranges and GitHub Releases are not consulted. A branch, commit or other deliberate pin uses `ref:`.

### Lock and restore

Per package, `intelligence.lock` records requested version, source URL/path, resolved tag/ref and commit SHA. Restoration reads only the lock and checks the resolved commit; it does not consult registries or choose a newer tag. Updates keep using that locked source; a deliberate source change is a new `package add`. This is the reproducibility contract used automatically by `sync` after a fresh clone.

## Manifest ownership

The engine reads `project:`, `schema_version:`, `sources:`, `targets:`, `models:`, `ignore:` and `submodules:`. The CLI owns the quoted-key `packages:` and ordered `registries:` blocks:

```yaml
packages:
  "@acme/backend":
    version: "^1.2.0"
  "@acme/experimental":
    ref: "main"

registries:
  - "https://github.com/acme/intelligence-registry.git"
```

`project.intelligence_dir` selects a content directory other than `intelligence/`. `schema_version` is the permanent top-level applied-schema contract and always remains a plain engine version without an npm prerelease suffix.

Package entries never contain `url` or `path`. Those resolved fields live in
the committed lock whether the package came from a registry, `github:`,
`git+`, or the CLI's built-in sync-package descriptor.

## Engine invocation contract

The Intelligence engine runs outside the project. The CLI supplies:

| Variable | Value |
|---|---|
| `IS_CLI` | `1` |
| `CONFIG_FILE` | `<root>/intelligence.yaml` |
| `REPO_ROOT` | project root |
| `IS_CONTENT_REL` | configured content directory |
| `IS_MODULE_REL` | `.intelligence/packages/@ainova-systems/sync` |
| `IS_MANIFEST_NAME` | `intelligence.yaml` |
| `IS_SYNC_CMD` | `intelligence sync` |
| `IS_PROTECTED_DIRS` | `<content-dir>:.intelligence` |

The engine reads local sources only. Package/network mechanics and project schema alignment remain CLI responsibilities.

## Developing the CLI

`cli/tests/verify.sh` is the single gate runner. Bare, it reads the diff against `main` and runs the gates that diff can affect, printing the ones it skipped; `all`, `lint`, `lint-cli`, `lint-engine` and `tests` select a scope explicitly. CI calls the same scopes, so adding a gate means editing the runner rather than a workflow.

```bash
bash cli/tests/verify.sh
bash cli/tests/verify.sh all
```

The `tests` scope runs six hermetic suites (`unit-semver`, `unit-manifest`, `unit-release`, `e2e-packages`, `e2e-lifecycle`, `e2e-negative`); the lint scopes need `shellcheck` on `PATH` and refuse to report success without it.

Build the npm payload with `bash npm/build.sh 0.0.0-dev`. To release, create and push a tag from `main`, then publish a GitHub Release for it. Prerelease tag `vX.Y.Z-rc.N` goes to npm dist-tag `next`; stable tag `vX.Y.Z` goes to `latest` and advances a stale `next` without replacing a newer preview line. Mark an RC Release as a prerelease; the workflow rejects a tag outside `main`, a base version that differs from `engine/VERSION`, or a mismatched prerelease flag.
