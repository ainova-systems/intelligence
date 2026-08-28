---
description: What this repository builds, how executable and content stay separated, and the release status that gates publishing
---

# Intelligence product repository

`ainova-systems/intelligence` builds the Intelligence CLI: a zero-dependency Bash
lifecycle CLI, the sync engine it ships, and the content package that engine
renders into every tool's native format. Legacy Intelligence Sync is archived in
`ainova-systems/intelligence-sync`; never edit that repository from here and never
bring its compatibility machinery back.

Read `decisions/0001-separate-legacy-intelligence-sync-from-intelligence.md` before
changing architecture, layout, conversion behavior or release plumbing, and
`decisions/0002-consolidate-intelligence-cli-lifecycle.md` before changing the
public command model. Neither model can be reconstructed from historical code.

## Layout

| Path | Role |
|---|---|
| `cli/` | dispatcher, lifecycle commands, package manager, test suites |
| `engine/` | the sync engine bundled into the npm package |
| `packages/sync/` | rules, agents, meta-skills and references installed as `@ainova-systems/sync` |
| `npm/` | Node launcher and distribution build |
| `docs/` `examples/` `decisions/` | CLI reference, manifest fixtures, internal architecture records |

The executable and its content are separate on purpose: `engine/` holds scripts,
`packages/sync/` holds content installed into consuming projects. The bundle seed
copies content only — an engine script reaching
`.intelligence/packages/@ainova-systems/sync` means the two roles merged again, which
is the exact coupling this product split removed. CI's `repo-purity` job asserts it.

`packages/sync/` ships to every consuming project, so it carries no repository-only
decisions and no release instructions; those belong in `decisions/` and
`CONTRIBUTING.md`. `@ainova-systems/sync` stays in this repository while it is
exact-pinned to `engine/VERSION`.

## This repository is also a consumer of its own product

`intelligence.yaml`, `intelligence.lock` and `intelligence/` make it an Intelligence
project. `AGENTS.md` and every tool directory here are generated: change
`intelligence/rules`, `intelligence/agents` or `intelligence/skills`, then run
`intelligence sync`. A hand edit in generated output survives until the next sync.

Two directories now carry the word: `intelligence/` is this project's own content,
`packages/sync/` is the content the product ships. `repo-purity` still refuses
`intelligence/sync` and `intelligence/scripts` — the legacy vendored layout.

## Release status

Intelligence has a stable release line. Publishing a matching ordinary GitHub
Release sends `X.Y.Z` to npm dist-tag `latest`; publishing a GitHub prerelease
sends `X.Y.Z-rc.N` to `next`. Release timing remains an owner decision, and public
registry traffic changes are coordinated separately from product publishing.
