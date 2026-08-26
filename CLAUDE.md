# CLAUDE.md

This file describes how to work safely and accurately in the v2 Intelligence product repository.

## Start here

Read `decisions/0001-split-v1-archive-from-v2-product.md` before changing architecture, layout, conversion behavior or release plumbing. Read `decisions/0002-consolidate-v2-cli-lifecycle.md` before changing the public command model. Do not reconstruct either model from historical code.

This repository is `ainova-systems/intelligence`, the v2 product. The archived v1 product remains in `ainova-systems/intelligence-sync`. Do not edit the v1 repository from this workspace. Do not add compatibility machinery back into v2.

v2 is not approved as a stable release. Do not publish a stable package or create a stable release unless the owner explicitly says the CLI is ready. If publishing is requested before then, use an `X.Y.Z-rc.N` prerelease and npm dist-tag `next`.

## Product model

The CLI owns a project's full lifecycle: initialization, package resolution, locked-store restoration, updates, schema alignment, v1 conversion and sync. `intelligence init` is the single entry point for setup, conversion and alignment. A v2 project contains:

```text
intelligence.yaml       root manifest
intelligence.lock       resolved package state; committed
intelligence/           project-owned rules, agents, skills and adapters
.intelligence/          CLI-owned package store; gitignored
AGENTS.md / tool dirs   generated output
```

No engine scripts live in consuming projects.

This repository deliberately separates the executable from its content:

```text
cli/                 dispatcher, commands, package manager and tests
engine/              executable sync engine bundled in the npm package
packages/sync/       rules, agents, meta-skills and references installed as @ainova-systems/sync
npm/                 Node launcher and distribution build
docs/                product/CLI documentation
examples/            v2 manifest fixtures
decisions/           internal architecture decisions; never package content
```

Keep `engine/` and `packages/sync/` separate. The bundle seed must copy package content only; engine scripts must never enter `.intelligence/packages/@ainova-systems/sync`.

`@ainova-systems/sync` remains in this repository while it is exact-pinned to `engine/VERSION`. Moving it to another repository requires independent pinning and is out of scope.

## Commands and validation

The public lifecycle surface is intentionally small:

```text
intelligence init [--preview|--apply]        initialize, convert v1, restore or align v2
intelligence sync [adapter]                 restore the locked store if missing, then render
intelligence update [@scope/name] [--preview|--apply]  plan, confirm or apply project/package updates
intelligence package <add|remove|list|search>   manage packages
intelligence adapter <list|create|enable|disable|remove>  manage adapters and target state
intelligence status [--check]               summarize state or run deep consistency checks
intelligence registry <list|add|remove>      manage the ordered registry trust list
```

Do not add top-level aliases for package or adapter subcommands. Conversion, v2 alignment, locked restore, deep checks and target-state edits are internal operations reached through the public commands above.

Mutating project-aware commands bring an older v2 manifest and exact sync-content pin to the bundled engine before continuing. CI refuses that tracked mutation and tells the user to run `intelligence init --apply` locally, review the diff and commit it.

Run the five CLI suites from the repository root:

```bash
bash cli/tests/unit-semver.sh .
bash cli/tests/unit-manifest.sh .
bash cli/tests/e2e-packages.sh .
bash cli/tests/e2e-lifecycle.sh .
bash cli/tests/e2e-negative.sh .
```

Build and inspect the npm distribution with:

```bash
bash npm/build.sh 0.0.0-dev
(cd npm/dist && npm pack --dry-run)
```

Lint commands matching CI:

```bash
shellcheck --severity=warning cli/intelligence
find cli -name '*.sh' -print0 | xargs -0 shellcheck --severity=warning
find engine -name '*.sh' -not -path '*/adapters/_template.sh' \
  -print0 | xargs -0 shellcheck --severity=warning
```

The adapter template is intentionally excluded because its `<name>` placeholders are not valid shell until scaffolded.

CI also verifies npm installation on Linux, macOS and Windows; v2 layout purity; engine/package stamp lockstep; sync behavior against examples; idempotence; and destructive-path guardrails. Keep local tests hermetic: package test fixtures use `file://` Git repositories and must not depend on a public registry.

## CLI architecture

`cli/intelligence` is a small dispatcher. The lifecycle commands are implemented in `cli/commands/{init,sync,update,package,adapter,status,registry}.sh`; shared CLI plumbing lives in `cli/lib/`.

Non-public mechanics live in `cli/internal/`: package operations, locked restore, deep checking, v1 conversion, v2 alignment and target-state editing. Keep them behind the lifecycle commands instead of expanding the dispatcher surface.

The repository and npm bundle both have one discovery layout: `<root>/{cli,engine,packages/sync}`. Do not add distribution-specific engine candidates.

`cli/lib/cli-common.sh` is the integration boundary:

- sources engine readers and the status contract;
- detects v2 versus archived vendored projects;
- derives the project content directory from `project.intelligence_dir`;
- describes `@ainova-systems/sync` from `cli/engine-package.yaml` rather than hardcoding its identity in commands;
- exports the environment used to invoke the engine.

The engine reads ordinary local paths from `sources:`. It does not resolve or fetch packages. Registry resolution, Git tags, semver ranges, store installation and `intelligence.lock` belong to the CLI.

The quoted-key `packages:` and `registries:` blocks are CLI-owned. Their parsing/editing belongs in `cli/lib/manifest.sh`; the engine deliberately does not read them. Reuse engine readers for shared manifest shapes instead of adding a parallel parser.

Registries are an ordered trust list and the only resolver for package names. Do not add a built-in catalog or infer a GitHub URL from `@org/name`. Explicit `github:` and `git+` specs remain the registry-free path. Names are global and one version of a package name may exist in a project.

## Engine architecture

`engine/sync.sh` sources `engine/lib/common.sh` and `engine/lib/contract.sh`, discovers built-in plus project-owned adapters, and runs enabled targets.

The CLI must export:

- `IS_CLI` — `1`;
- `CONFIG_FILE` — root `intelligence.yaml`;
- `REPO_ROOT` — project root;
- `IS_CONTENT_REL` — project content directory;
- `IS_MODULE_REL` — installed `@ainova-systems/sync` directory;
- `IS_MANIFEST_NAME` — `intelligence.yaml`;
- `IS_SYNC_CMD` — `intelligence sync`;
- `IS_PROTECTED_DIRS` — project content and package-store directories.

`sync.sh` is a pure synchronizer. It never changes schemas or fetches packages. The CLI preflight aligns older v2 schema/content before mutating commands; `init --apply` is the explicit reviewed path and `update` includes alignment in its plan.

`intelligence sync` is the normal fresh-clone path: it restores a missing `.intelligence/` store strictly from `intelligence.lock`, exports the engine contract and then renders. It never re-resolves package versions during restore.

`intelligence update` always prints the installed-CLI, project and package plan. `--preview` stops without prompting or writing, the default asks interactively, and `--apply` applies without prompting before syncing.

The permanent schema key is the top-level scalar `schema_version`. `engine/lib/contract.sh` owns its readers, compatibility guard and the stable `IS_STATUS`/`IS_RC_*` contract. Do not renumber return codes. Callers must preserve the command's real status, for example `cmd || rc=$?`; `if ! cmd; then rc=$?` captures the negation instead.

### Rule routing

Always-on rules are inlined once into `AGENTS.md`. Cursor, Copilot, Codex, Pi and OpenCode consume that file, so their adapters omit always-on rules from tool-specific channels. Path-scoped rules use native channels where available. Claude Code does not consume `AGENTS.md`, so its adapter receives every rule.

The `agents` target is therefore required whenever an enabled target relies on `AGENTS.md`. Keep that invariant synchronized with the list in `engine/sync.sh` when adding an adapter.

### Adapter contract

An adapter is one file defining:

```bash
sync_to_<name>(repo_root, config_file, output_dir)
```

Built-ins live in `engine/adapters/`. Project adapters live in `<content-dir>/adapters/`, survive upgrades, and override a built-in of the same name with a visible note.

Every emitted text file must pass through `finalize_output_file`; skill directories must be copied with `copy_skill_bundle`, and adapters sharing `.agents/skills/` must use `sync_open_skill_dirs`. Never delete an entire tool root when the adapter owns only subpaths. `validate_output_path` is the mandatory engine-side guard against source, store, root and out-of-repository writes.

See `packages/sync/references/adapters.md` for the adapter contract and `packages/sync/references/conventions.md` for artifact formats.

## Shell conventions

- Use Bash with `set -euo pipefail` and LF line endings.
- Engine code may rely on Bash, awk and ordinary POSIX utilities, but not jq, Python or GNU-only awk features.
- Strip `\r` in awk readers because inputs may use CRLF.
- Validate every manifest, registry, package-name, URL and ref value before it reaches Git arguments or filesystem operations.
- Prefer the shared parsers and helpers in `engine/lib/common.sh` and `cli/lib/`; do not copy YAML/frontmatter logic into commands or adapters.
- Keep transactional filesystem changes staged and verified before replacing project state.
- Comments explain constraints and intent, not visible syntax.

## Artifact authoring

Content under `packages/sync/` is installed into consuming projects. Do not put repository-only decisions or release instructions there.

Rules express constraints, skills express explicit procedures, and agents express personas. Follow `packages/sync/references/conventions.md`. The `intelligence-` prefix is reserved for engine-owned artifacts.

Meta-skills are interpreters of deterministic CLI behavior, not alternate implementations. Keep mechanics in commands; skills may research external formats, read changelog context, choose a command and interpret `IS_STATUS`.

## Initialization boundary

`intelligence init` detects absent, v2 and vendored v1 states. On v2 it restores or aligns idempotently; on v1 it previews a conversion and requires confirmation or `--apply`. An older v1 project must first reach schema `0.10.0` with its archived engine.

V1 conversion must remain transactional: stage, verify target/source equivalence, run a real staged sync, then commit and remove the vendored engine. `init --preview` writes nothing to the project.

## Documentation and changelog

Documentation must use v2 paths and CLI commands. References to `INIT.md`, a vendored `scripts/update.sh`, `packs:`, engine scripts inside a project, or `intelligence/sync/...` are v1 concepts and belong only in narrowly scoped migration/archive explanations.

Files inside any `docs/` directory use lowercase kebab-case (`cli.md`, `adapter-contract.md`). Standard root documents such as `README.md`, `CHANGELOG.md`, `CONTRIBUTING.md`, `CLAUDE.md` and `ROADMAP.md` keep their conventional names.

The v2 `CHANGELOG.md` is compact: one line per change, minimal context, no rationale. Put rationale in `decisions/`. A `### Breaking` subsection is a checklist of verifiable post-conditions consumed by the update skill.

## Versioning and releases

`engine/VERSION`, every example's `schema_version`, and every example's exact `@ainova-systems/sync` pin must stay in lockstep. `repo-purity` enforces this.

`npm/build.sh` assembles the distribution from `cli/`, `engine/` and `packages/sync/`. npm publishes with provenance, so `npm/package.json` repository metadata must continue naming this repository.

The `release-npm` workflow is manual:

- `X.Y.Z-rc.N` may publish from any ref to npm dist-tag `next`;
- stable `X.Y.Z` may publish to `latest` only from the matching `vX.Y.Z` tag;
- the v2 tag line starts at `v0.11.0`; never recreate v1 tags here.

Do not release, push to the public registry repository, or change the repository workflow from direct-main to branches/PRs without explicit owner direction.

## Commit messages

Use one capitalized, past-tense sentence. Do not add AI/tool attribution or `Co-Authored-By` trailers.
