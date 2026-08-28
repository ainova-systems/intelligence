---
paths:
  - "cli/**"
description: "CLI boundaries: command surface, the integration seam, and who owns packages and the lock"
---

# CLI

`cli/intelligence` is a small dispatcher. The public lifecycle surface is `init`,
`sync`, `update`, `package`, `adapter`, `status` and `registry` — one file each in
`cli/commands/`. Shared plumbing lives in `cli/lib/`. Non-public mechanics —
package operations, locked restore, deep checking, legacy conversion, project
alignment, target-state editing — live in `cli/internal/` and are reached only
through a lifecycle command.

Do not add a top-level command or alias when one of those groups already owns the
state or the resource. Package and adapter verbs stay subcommands of their group.

## The integration seam

`cli/lib/cli-common.sh` is the only place that joins CLI and engine. It sources the
engine readers and the status contract, distinguishes an Intelligence project from a
legacy Intelligence Sync one, derives the content directory from
`project.intelligence_dir`, describes `@ainova-systems/sync` from
`cli/engine-package.yaml` instead of hardcoding its identity, and exports the engine
environment. A new export belongs there, not in a command.

The repository and the npm bundle share one discovery layout,
`<root>/{cli,engine,packages/sync}`. Do not add a distribution-specific engine
candidate.

## Who owns what

The engine reads ordinary local paths from `sources:` and nothing else. Registry
resolution, Git tags, semver ranges, store installation and `intelligence.lock` are
the CLI's. The quoted-key `packages:` and `registries:` blocks are CLI-owned: parse
and edit them in `cli/lib/manifest.sh`, and reuse the engine readers for shapes both
sides share rather than growing a parallel YAML parser.

Registries are an ordered trust list and the only resolver for a package name. There
is no built-in catalog and no `@org/name` to GitHub inference; explicit `github:` and
`git+` specs are the registry-free path. Names are global — one version of a name per
project.

A manifest package entry carries requested intent only, `version` or `ref`. Resolved
url, path, tag and SHA belong to `intelligence.lock`, including for the built-in sync
package. `update` follows the locked source; changing a source is an explicit
package re-add.

## Initialization and mutation

`init` detects absent, Intelligence and legacy Intelligence Sync states. On an
Intelligence project it restores or aligns idempotently; on a legacy one it previews
conversion and requires confirmation or `--apply`. An older legacy project must first
reach schema `0.10.0` under its archived engine. `init --preview` writes nothing to
the project.

Legacy conversion stays transactional: stage, verify target and source equivalence,
run a real staged sync, then commit and remove the vendored engine.

A mutating project-aware command brings an older manifest and exact sync-content pin
up to the bundled engine before doing its own work. CI refuses that tracked mutation
and directs the user to run `intelligence init --apply` locally, review the diff and
commit it.

`intelligence sync` is the fresh-clone path: it restores a missing `.intelligence/`
store strictly from `intelligence.lock`, never re-resolving a version during restore.
`intelligence update` always prints the installed-CLI, project and package plan;
`--preview` stops without writing, the bare form asks, `--apply` proceeds and syncs.

## Tests

Package fixtures use `file://` Git repositories. Every suite stays hermetic — no
public registry, no network.
