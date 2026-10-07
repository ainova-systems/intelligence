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
| Existing Intelligence project | Align schema/content if needed, restore missing store, reapply every enabled adapter's Git policy, sync | Show alignment/restoration plan only | Apply alignment explicitly after reviewing a CI refusal locally |

`--force` applies only to archived-project conversion when a dirty worktree must be accepted deliberately. `--dir name` names the project's content directory — where its own rules, agents, skills and adapters live — when it should not be `intelligence/`; the name is recorded as `project.intelligence_dir` and must be a plain directory inside the repository, never an absolute path, a `..` path or the `.intelligence/` package store. Like `--targets` and `--bare`, it applies only when creating a new project. `--bare` omits `@ainova-systems/sync`; `--no-sync` stops after project state is ready.

New-project adapter selection always enables `agents`. Other adapters come only from repository markers or explicit `--targets`; the CLI never invents a tool directory.

Before first sync, init preserves existing root and tool-specific AI
instructions and preserved tool settings under the content directory's
gitignored `_backup/`. Its `manifest.tsv` declares `initial-onboarding` and
lists exact source paths and legacy entry points. Settings remain in place.
Legacy entry points are quarantined for the transactional first render; a
failure restores them exactly, while success leaves them inactive for
repository learning. The backup is removed only after separate approval and
verified output.

Legacy-project conversion requires final Intelligence Sync schema `0.10.0`. Older projects first bring themselves to that schema using their archived engine. Conversion remains transactional: stage, verify manifest/source/adapter equivalence, run a staged sync, then replace old state. When the legacy content directory is not `intelligence/` and holds project sources, the converted manifest records it as `project.intelligence_dir`.

Each mirrored package must retain its `.pack` ownership stamp with a valid recorded
commit SHA. A valid stamped mirror converts offline; an absent or invalid SHA
refuses conversion before changing the legacy project. Restore the trusted stamp
from history or refresh the mirror using its archived engine before retrying.
Resolving today's remote ref cannot prove which commit produced an older mirror.

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
`AGENTS.md`, hand-written `.github/` files, and shared tool settings trackable;
`targets.copilot.commit_output: true` keeps Copilot's output tracked too. The exact patterns
are listed in the [artifact conventions](../packages/sync/references/conventions.md#generated-output-and-version-control).
When `.vscodeignore`, `.npmignore`, or `.dockerignore` already exists, init
also adds packaging exclusions for Intelligence development context and
adapter outputs. It reports exact `git rm --cached` commands when Git already
tracks a covered path that remains in the worktree; quarantined legacy paths
are reported by Git as normal deletions instead.

### `intelligence sync`

```text
intelligence sync [adapter] [--compact] [--force] [--check]
```

For Intelligence projects, sync performs lifecycle preflight before rendering:

1. Validate any existing lock, then align tracked project schema/content with the installed CLI when safe.
2. If a package in `.intelligence/` is missing or holds a commit other than the one `intelligence.lock` pins — a pull that moved the lock leaves the ignored store behind — restore it strictly from `intelligence.lock` without registry lookup or range resolution. The store records each package's installed lock row in `.intelligence/packages/.installed`; a package without that record is fetched again once.
3. When inputs and outputs match a previous successful sync, reuse its result
   without rewriting outputs or taking snapshots. Otherwise validate each
   selected adapter's versioned ownership contract and required
   targets before writing.
4. Snapshot every declared owned or shared managed path, then run every enabled
   adapter or only the named enabled adapter.
5. Commit the generated state only when all selected adapters succeed. Any
   failure restores every path to its exact pre-sync state.

A filtered adapter must be enabled explicitly; naming it does not bypass target
state. Project adapters without a valid contract are refused before sync.

Built-in adapters render concurrently where their contracts allow it: adapters
that share a managed directory run in order together, and an adapter that
requires another starts after it. Each adapter's output still prints in list
order, once its job and every adapter listed before it have finished. A selected
project adapter keeps the whole render serial, and `INTELLIGENCE_SYNC_SERIAL=1`
restores the one-at-a-time order for any run.

Normal sync announces its checks immediately and streams rendering progress as
adapters finish. An unchanged run separates retained warnings from the result and ends
with `Unchanged: no files needed updating`. Cached results still require reading
source and output contents; the check is not a timestamp-only shortcut.

For built-in adapters, unchanged sync compares file contents and filesystem
entries, including skill resources, generated outputs, manifest/lock, and the
installed CLI/engine. An edited or missing output triggers rendering even when
sources have not changed. Output modification times stay untouched on a hit.
The disposable state lives in `.intelligence/sync-cache/`; it is gitignored
with the package store. Full and filtered invocations do not reuse each other's
results. Project adapters and filesystem layouts that cannot be fingerprinted
safely use ordinary sync. Missing or damaged cache data also uses ordinary sync.

`--force` always renders and refreshes diagnostics, including the search for
unconfigured source directories elsewhere in the repository. A cache hit replays
the last full run's useful warnings and context summary, and skips that repository
scan. Use `intelligence sync --force` to discover newly added directories outside
the configured sources. It can be combined with a target and `--compact`.

One command writes a project at a time. `sync`, `update`, package add, remove and
update, adapter enable, disable and removal, alignment and store restore hold
`.intelligence/sync.lock` while they write, and the commands they run join it. A
second writer refuses, naming the holder's process and host. A lock is taken over
only when no process of its holder's process group remains on this machine — a
killed wrapper whose render still runs keeps it — or when it never got an owner
and is older than a minute. An abandoned takeover is reported for a person to
remove rather than recovered automatically.

A missing store with no lock fails and directs the user to restore the committed
lock. In a legacy Intelligence Sync project, sync delegates to that project's own vendored
engine until conversion.

Restoration fetches each package's locked commit, even after its branch or tag
moves. It verifies that commit before replacing the package and keeps the manifest's
requested ref and the lock unchanged. An unavailable commit fails without substituting
the current ref or HEAD. Missing or malformed required commit SHAs are refused before
restoration writes; use `intelligence update` to deliberately advance a ref.

Lock validation runs before lifecycle alignment and mutations, even when the
package store is already installed. `init --preview`, `update --preview`,
`status` and `package list` use the same metadata checks. Read-only reports use
restore requirements when package content is missing, so an unpinned bundle is
not reported as restorable. An invalid lock fails with its location or affected
field; see [Recovering a lock](#recovering-a-lock) before continuing.
Validation does not silently repair, discard or reinterpret malformed entries.

Matching bundled sync content remains available offline. A release bundle with a
known SHA must match the locked SHA; otherwise restoration fetches the locked commit
from its recorded source. Development bundles or bundle-seeded locks without a SHA
retain the offline path with an explicit warning that commit verification is unavailable.
Metadata validation also recognizes version-tagged development bundles at the
built-in URL/path within the CLI's major version, so older projects can align and an installed newer same-major
bundle remains usable. It reports that commit verification is unavailable for
these cross-version empty-SHA entries. `engine_version` records the lock writer
and can differ from a preserved bundle pin. A missing cross-version bundle still
needs a valid SHA: the metadata exception never authorizes fetching an unpinned ref.
Repeated validation prints each development-bundle metadata warning once per command.
This verifies acquisition identity, not every byte of an already installed store.
Sync fingerprints local source contents to detect changes since a successful
render; those fingerprints do not authenticate a package against its upstream
commit. `status --check` does not rehash installed package contents.

The output rollback in steps 4–5 covers adapter-declared paths. Package restoration
publishes one verified package at a time before rendering; a later fetch or render
failure can leave earlier packages restored. It is not a transaction spanning the
package store, manifest and lock. Lifecycle alignment in step 1 is also separate.

Every successful sync reports context pressure in one line: byte totals and file
counts for always-on rules, then for custom context (scoped rules, agent prompts
and skill entry points), followed by a numeric rendered `AGENTS.md` byte count
and its `generated`, `not-generated`, or `disabled` status. Supporting skill
assets are excluded because they load only when a skill reads them.

`--compact` prints that context summary and actionable one-line warnings,
followed by the final machine-readable status and completion line when sync
succeeds. If lifecycle preflight, restore or rendering fails, it prints the
complete captured diagnostics and preserves the original exit code.

If the manifest declares packages but `intelligence.lock` is missing, every
mutating lifecycle command fails before alignment or restoration. Restore the
committed lock; the CLI never invents a partial replacement from the packages
that happen to be locally available.

#### Checking whether sync is needed

`intelligence sync --check` answers whether `intelligence sync` would change any
generated file, and changes none itself. It prints one status line,
`IS_STATUS=<code> IS_DETAIL=<reason>`, and exits:

| Exit | `IS_STATUS` | Meaning |
|---:|---|---|
| 0 | `ok` | Generated files are what sync would leave |
| 2 | `out-of-date` | Sync would change generated files, or the project needs alignment first |
| other | | An error, with sync's own status: an invalid lock or no Intelligence project (1), a newer-major schema (4, `ahead-of-engine`), a failing renderer. A failure that would end in 2 is reported as 1 |

The check runs sync's preflight and takes the project lock like sync. It
restores a missing or mis-recorded package store from `intelligence.lock`,
because that store is ignored, reproducible state; restore progress and every
diagnostic go to stderr. It never applies tracked alignment: when the project
needs it, the check exits 2 and names `intelligence init --apply`, in CI and
locally alike. A legacy Intelligence Sync project is an error.

It answers in one of two ways:

- **From the record.** A record left by a successful sync or check, made with the
  same CLI and engine code in the same environment — adapter filter, project
  root, layout, bash, locale, `PATH`, umask — answers without rendering. Equal
  sources and generated files exit 0. When the project's sources (manifest,
  lock, configured sources, installed packages) or its generated files differ
  from the record, the check exits 2 at once and names the side that changed:
  `sources changed` or `generated files changed`. A source change may still
  render to identical files — a manifest comment, for example; `--force` gives
  the exact answer.
- **By rendering.** Without a usable record — none yet, damaged, from an older
  CLI, or made by other code or in another environment (a different `PATH` is
  enough) — the engine renders inside its rollback transaction, compares every
  owned and managed path with the snapshot it took first, and restores that
  snapshot whatever the result, so bytes and modification times stay as they
  were. A clean result is recorded under sync's rules, so the next check is
  fast; a difference records nothing.

`--check --force` always renders: the strict answer. An adapter name scopes the
check to that adapter, and full and filtered records never stand in for each
other. `--compact` is accepted and changes nothing, because the check already
prints a single line.

### `intelligence update`

```text
intelligence update [@scope/name] [--latest] [--preview | --apply]
```

One plan covers:

- the globally installed CLI against its npm channel (`next` for a prerelease, otherwise `latest`);
- project schema and engine-content alignment against the installed CLI;
- package ranges that can move to a newer stable tag, and `ref:` pins whose commit moved.

Modes:

| Mode | Behavior |
|---|---|
| no flag | Print the plan and ask before writes; a non-interactive shell refuses |
| `--preview` | Print the plan and write nothing |
| `--apply` | Apply project/package changes without asking, then sync |

When a newer CLI is on its npm channel, the plan names `intelligence upgrade`; `update` never mutates the global npm prefix itself. The exact engine-content pin does not move as an ordinary range.

A `ref:` pin is compared by commit, not by ref name: the plan resolves the ref on the remote and reports `<ref> <old sha> -> <new sha>` when it moved, so a branch or `HEAD` pin follows its upstream and a re-cut tag is visible. A ref that is itself a commit reports `(pinned commit)` and never moves — that is how a source is frozen. A remote that cannot be reached is reported as not checked, never as up to date.

A range is a ceiling as well as a floor, so the plan reports both sides of it. When the remote carries a newer stable version the range excludes, the package's line names it and the command that follows it, and a final line counts those packages separately:

```text
  @acme/core: v0.4.1 -> v0.4.2 — 0.6.1 available outside '^0.4.0'
      follow it: intelligence update @acme/core --latest
updates available: 1 package(s)
outside the requested range: 1 package(s) — read the changelog, then run the 'follow it' command above
```

They are counted apart because no ordinary mode installs them. This matters most before `1.0.0`, where the caret holds the minor, so `^0.4.0` follows `0.4.x` only.

`--latest` is that deliberate crossing: it moves the named package to the newest stable version and rewrites its requested range to `^<that version>`, keeping the manifest a record of what the project asked for and the next boundary a decision. It shares the plan's modes, so `--preview` shows the move and the new range without writing. It requires the package to be named, because one confirmation must not cover several unrelated changelogs; it refuses a `ref:` pin, which is frozen by intent, and the engine-content package, whose pin follows `intelligence upgrade`. The widened range reaches the manifest only after the new content is installed and wired. See the [range practice](../packages/sync/references/conventions.md#choosing-a-range).

### `intelligence upgrade`

```text
intelligence upgrade [--next] [--preview | --apply]
```

Replaces the installed CLI with the newest version on its npm channel: `next` when the running version is a prerelease or `--next` is given, otherwise `latest`. The command asks the registry, prints `installed -> available` with the exact `npm install -g --prefix … <package>@<version>` it will run as one pastable command, and follows the `update` modes: no flag asks first and a non-interactive shell refuses, `--preview` writes nothing, `--apply` installs without asking. The version installed is the one the plan showed, never a moving tag, and success is what the freshly installed launcher reports, not what npm returned. A CLI already at its channel's version exits 0 without writes; one ahead of its channel exits 0 too and names the command that moves it back deliberately, because `upgrade` never downgrades. A registry that does not answer is a refusal, never "up to date".

`upgrade` replaces the installation it runs from and touches no project. It reads the npm prefix off its own location (`<prefix>/lib/node_modules/<package>` on POSIX, `<prefix>/node_modules/<package>` on Windows), accepts it only when the shim npm linked at that prefix (`bin/intelligence`, or `intelligence.cmd` on Windows) points at this tree, and passes it to npm explicitly, so the CLI on `PATH` is the one replaced under nvm, Homebrew or a custom prefix alike; the registry is asked in that same global configuration. Anything else — a source checkout, an `npx` run, a checkout linked with `npm link`, a project's own dependency, another package manager's store (pnpm, yarn, bun, Volta, Nix) — is refused before any network call, with the command that upgrades that installation where it lives. After upgrading, run `intelligence update` in each project to align it with the new CLI; a project stamped by a prerelease CLI needs `upgrade --next`.

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

### `intelligence source`

```text
intelligence source add <rules|agents|skills> <dir> [--first|--last|--before <entry>|--after <entry>]
intelligence source remove <rules|agents|skills> <dir>
intelligence source list
```

Manages the project's own entries in `sources:` — a monorepo's per-component
directories, or a pack developed inside the repository that ships it. Installed
package content is not managed here: `.intelligence/` entries belong to
`package add` / `package remove`, and an entry hand-placed under the store does
not survive the next lifecycle alignment.

`sources:` is an ordered list and the order is the override rule, so placement
is the command's real work. `add` appends by default: the end of the section is
the project's own territory, where a directory the project added wins over every
installed package. `--before` / `--after` place an entry relative to one the
section already lists — this is how content that should behave like a package
lands after the store entries and ahead of the project's own. Adding an entry
the section already holds is a no-op; adding it *with* a position moves it.
Every mutation prints the resulting order.

Five inputs are refused. Four of them fail silently after a green sync; the
fifth renders the wrong thing loudly:

- an absolute path — the engine resolves every entry as `$REPO_ROOT/<entry>`, so it matches nothing and the source is simply skipped;
- a path leaving the repository (`../`, or a symlink pointing out) — it renders, but has no committable path, so `AGENTS.md` carries bare artifact names instead of links;
- a path under `.intelligence/` — package territory, as above;
- a path a double-quoted YAML scalar cannot carry verbatim (quotes, `#`, `:`, backslashes);
- the repository root itself (`.` and `./`) — it *is* a directory, so every top-level `*.md` beside it would be read as an artifact of that section.

Spellings of the same directory are one entry: `./intelligence/rules/`,
`intelligence/./rules` and `intelligence/rules` are stored, compared and
reported identically.
`status --check` reports the same five through the same definition, so an entry
a hand edit placed before this command existed is judged identically.

A directory that does not exist yet is a warning, not a refusal: the manifest
documents intent, and sync renders the source once the directory appears.
`remove` drops the entry only — the directory is untouched, and its artifacts
leave the generated output at the next sync.

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

An invalid lock makes `status` and `package list` exit nonzero and mark locked
content as unchecked. `status --check` continues independent schema, source,
adapter and ignore-policy checks after reporting the lock error; it skips checks
that require trusted lock rows.

`--check` performs deep consistency validation and exits nonzero for
manifest/lock divergence, missing package content, a package holding a commit
other than the locked one or recording none, stale schema/content or invalid
sources. Each package line reports the commit the store holds. Frozen store
restoration verifies the locked commit SHA.

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

The gate runs the other way too. A CLI **older** than the project compares `schema_version` with its engine by SemVer level. A newer major refuses every project-aware command with `IS_STATUS=ahead-of-engine` and exit code 4, because the manifest may carry shapes that engine cannot read. A newer minor or patch within the same major prints one `WARNING:` line naming both versions and continues: `sync` renders with the engine content the lock names, and no command restamps `schema_version` or re-pins `@ainova-systems/sync` downward — alignment only ever moves a project up to the installed CLI. `status --check` reports that state as a note rather than a problem. Update the CLI (`intelligence upgrade`) to align the project again.

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

`ref:` is requested intent like a range, and its resolution is a commit. A branch or `HEAD` pin therefore follows its upstream across `intelligence update`, and only a `ref:` naming a commit is immutable.

### Lock and restore

Per package, `intelligence.lock` records requested version, source URL/path, resolved tag/ref and commit SHA. For a `ref:` pin the resolved column repeats the ref name, so the SHA is the field that records which commit is installed; `package list` and `status --check` print it as `<ref>@<sha>`. Restoration reads only the lock and checks the resolved commit; it does not consult registries or choose a newer tag. Updates keep using that locked source; a deliberate source change is a new `package add`. This is the reproducibility contract used automatically by `sync` after a fresh clone.

Lock format v1 requires `lockfile_version: 1`, a numeric `X.Y.Z` `engine_version`
and a `packages:` block, nonempty when the project manifest declares packages.
Each quoted package key has scalar fields at four-space
indentation. URL and resolved ref must be nonempty and safe for acquisition; SHA
must be 40 or 64 lowercase hexadecimal characters, apart from the bundle exception
above. An omitted or empty path selects the repository root; other paths must be
safe relative subdirectories. Duplicate top-level keys, packages or fields fail.
The generated format supports comments, CRLF, simple plain or double-quoted scalars
and additive scalar metadata. Top-level and package-field keys are unquoted and
must match `[A-Za-z_][A-Za-z0-9_]*`. Double-quoted values support the writer's
`\\` and `\"` escapes, decoded once; read/write cycles preserve their literal
values. Other escapes, containers, aliases and multiline scalar forms are outside
this reader's format and are refused. Validation and ordinary field/row reads use
one shared tokenizer. A future lock format reports its unsupported version before
body-shape errors, so the reader can be upgraded. These are metadata checks;
they do not establish physical path containment or verify installed package bytes.

### Recovering a lock

Run `intelligence status --check` to see the damaged location and the remaining
project checks. If the format version is newer than the CLI supports, update the
CLI first. For damaged data, save the current project state before recovery.

If a trusted commit, teammate checkout or backup contains a valid lock matching
the manifest, restore that whole file. For Git history, `git restore --source=<trusted-commit> --
intelligence.lock` restores a chosen version; the latest committed copy is not
necessarily valid.

Whenever replacing a lock, move any existing `.intelligence/packages` directory
to a saved location outside the project before running `intelligence sync`.
Keep the remaining `.intelligence` state in place. Sync then restores the package
bytes from the replacement lock; keeping an old store could otherwise leave old
content under new recorded identities, because installed bytes are not rehashed.
Run `intelligence status --check` after sync and inspect the generated changes.

If no valid copy exists, the old commit identities cannot be reconstructed from
package names or version ranges. Rebuild a replacement deliberately through the
CLI in a separate temporary directory outside any Intelligence project:

1. Run `intelligence init --bare --no-sync` there.
2. Add the trusted registries with `intelligence registry add <url>`, then run
   `intelligence package add <spec> --no-sync` for every package in the original
   manifest, including its sync package. For explicit Git sources, supply the
   confirmed URL/ref/path and `--name @scope/name`. Preserve each manifest request;
   inspect which commits the CLI selected, since a moved ref or range can now
   select different content.
3. Review the complete generated lock and confirm its package set and requested
   values match the original manifest. Copy that whole lock into the original
   project, retaining the saved previous file. Move its old package store aside as
   described above, run `intelligence sync` and `intelligence status --check`, then
   review and commit the resulting state.

This rebuild selects a new recorded state; it does not recover unknowable old
SHAs. If the old identities are required, obtain them from a trusted source before
proceeding. There is no automatic repair or validation-bypass flag. Do not repair
individual generated rows by hand. Replacing the file is reversible by restoring
the saved project state, including the matching lock/store pair and generated
outputs; the saved lock may still require recovery before the CLI can use it.

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

`sources:` is engine-readable but CLI-edited: `package add` / `package remove` own the `.intelligence/` entries, `source add` / `source remove` own the project's own, and both place entries in a list whose order decides which artifact wins.

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
| `IS_SYNC_CHECK` | set by `sync --check` only: a file to which the engine, after rendering, comparing and restoring every snapshotted path, writes `same` or `differs` |

The engine reads local sources only. Package/network mechanics and project schema alignment remain CLI responsibilities.

## Developing the CLI

`cli/tests/verify.sh` is the single gate runner. Bare, it reads the diff against `main` and runs the gates that diff can affect, printing the ones it skipped; `all`, `lint`, `lint-cli`, `lint-engine` and `tests` select a scope explicitly. CI calls the same scopes, so adding a gate means editing the runner rather than a workflow.

```bash
bash cli/tests/verify.sh
bash cli/tests/verify.sh all
```

The `tests` scope runs every hermetic suite named in the runner's `SUITES` list; the lint scopes need `shellcheck` on `PATH` and refuse to report success without it. On Windows the runner moves the scope into WSL when a distribution can run it; `CONTRIBUTING.md` covers the switches.

Build the npm payload with `bash npm/build.sh 0.0.0-dev`. To release, create and push a tag from `main`, then publish a GitHub Release for it. Prerelease tag `vX.Y.Z-rc.N` goes to npm dist-tag `next`; stable tag `vX.Y.Z` goes to `latest` and advances a stale `next` without replacing a newer preview line. Mark an RC Release as a prerelease; the workflow rejects a tag outside `main`, a base version that differs from `engine/VERSION`, or a mismatched prerelease flag.
