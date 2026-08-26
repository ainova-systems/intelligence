# 0001 — v1 archives in place; v2 becomes its own repository

Date: 2026-08-26
Status: accepted

## Context

`intelligence/sync/` served three roles at once: the payload that frozen downstream `update.sh`
clients copy from `main` HEAD, the source of the npm bundle's engine, and the content of the
`@ainova-systems/sync` package. One tree in three roles forced every content file to be
mode-aware — layout tokens that branch on mode, a CI-mirrored second copy of `docs/`, meta-skills
that branch, and two golden CI jobs whose only purpose was proving the two modes stayed identical.
Every item on the "legacy weight" list was a symptom of that single decision.

The CLI work additionally made the v1 engine CLI-aware. Merging it into the v1 line would leave
the vendored lineage as v1 with v2 scaffolding grown into it — the wrong thing to archive.

## Decision

1. **The lineages split at `d124af6` (v0.10.1).** The CLI branch never merges into the v1 line.

2. **`ainova-systems/intelligence-sync` freezes in place as the v1 archive**, at the same URL its
   clients already clone, so a frozen `update.sh` keeps working with no action from anyone. Its
   final release **0.10.2** adds an EOL banner to `sync.sh`, `update.sh` and `INIT.md` and nothing
   else; it ships only once the CLI is ready to receive the migrations that banner recommends.
   No rename: past ~100 clones/week a renamed namespace is retired irreversibly (we run ~150), and
   with 4 stars and 0 forks a rename would preserve nothing.

3. **`ainova-systems/intelligence` is the v2 product**, seeded by pushing the CLI branch as `main`.
   History travels; **tags do not** — the resolver enumerates versions with `git ls-remote`, and
   v1 tags point at trees where `packages/sync` does not exist. The v2 tag line starts at `v0.11.0`.

4. **Target layout from the first commit**: `cli/ engine/ packages/sync/ npm/ docs/ examples/`, no
   `intelligence/`. Two artifacts leave this repo through two channels — an executable (npm) and a
   content package (git tags) — and the tree names which is which.

5. **v1 machinery is deleted from the v2 engine**: `packs:`/mirrors/`.pack`, `update.sh`,
   `lib/migrations.sh`, the legacy branch in `layout.sh`, the mode branches in `expand_tokens`,
   the `legacy-golden*` jobs and the `[golden-skip]` mechanism, and the vendored `docs/` mirror.

6. **V1 conversion requires the final v1 schema.** A project older than that runs its own
   `update.sh` first — possible forever, because the archive stays at the URL its frozen script
   hardcodes. This is what lets v2 drop `lib/migrations.sh`: no v1 chain survives into v2.

7. **`packages/sync` stays in the product repo** while it is exact-pinned to the engine version.
   Repo boundary follows versioning boundary: it moves to `intelligence-dev-packs` only together
   with independent pinning, never before.

8. **Meta-skills become interpreters, not implementations.** In v1 a skill carried the whole
   procedure because there was no program; v2 has one, so a skill carries only what a program
   cannot. The originally proposed command split was superseded by
   [decision 0002](0002-consolidate-v2-cli-lifecycle.md).

9. **The CHANGELOG carries what changed, one line per change, no rationale.** The why lives here.
   Decisions sit at the repo root rather than under `docs/`, because `docs/` is content of the
   `@ainova-systems/sync` package and would otherwise install our internal decision log into every
   consuming project.

## Consequences

- Vendored clients do nothing: same URL, final engine, and once 0.10.2 lands the EOL banner prints
  locally from then on. There is no deletion deadline and no migration window to police.
- Issues, pull requests and stars stay with the archive.
- The v2 repo must re-point: `npm/package.json` `repository`/`homepage`/`bugs` (npm publishes with
  `--provenance`, which verifies that field against the publishing repo), `cli/engine-package.yaml`
  url and `path: packages/sync`, the `@ainova-systems/sync` entry in the public registry index,
  documentation links, and the `NPM_TOKEN` secret.
- Early `0.11.0-rc.*` lockfiles pin the old package URL; `status --check` reports that drift.

## Rejected

- **Rename `intelligence-sync` and reclaim the old name for the archive.** It would have kept the
  audience with v2 and redirected old clients for free, but namespace retirement past 100
  clones/week is irreversible and reversible only by GitHub support.
- **A minimal placeholder on `main`.** Actively destructive: a frozen `update.sh` runs
  `rsync -a --delete` over the client's `scripts/`, so an echo-stub would replace a working engine.
  A *missing* `scripts/` directory fails closed before any write — deletion is the safe operation,
  stubbing is not.
- **Recreating the v2 repo from scratch.** 571 KB and 56 commits; it would lose blame on the
  newest and least settled code and save no pipeline work, since the restructuring rewrites the
  pipelines either way.
- **Moving `packages/sync` to `intelligence-dev-packs` now.** It would convert a free lockstep
  invariant into cross-repo release choreography and break the offline bundle-seed, buying only a
  prettier repo boundary.
