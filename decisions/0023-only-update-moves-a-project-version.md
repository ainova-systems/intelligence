# 0023 — Only `update` moves a project's version

Date: 2026-10-20
Status: accepted

## Context

Every project-aware command — `sync`, `package`, `source`, `adapter`, `registry`,
`init` on an existing project — runs lifecycle alignment first. When the CLI
is newer than the project, alignment rewrites `schema_version` in
`intelligence.yaml` and the `@ainova-systems/sync` pin and its lock row in
`intelligence.lock`. A plain `intelligence sync` therefore leaves a diff in two
tracked files that nobody asked for. A teammate who upgraded the CLI commits
it, or keeps discarding it, and the version the project is on changes as a
side effect of whoever synced last.

`update` already shows the CLI, project and package plan, asks or takes
`--apply`, and then syncs. It is the command whose purpose is to move versions.
Decision 0005 already covers the opposite direction: a project stamped ahead
of the CLI is left exactly as found.

## Decision

1. Only `intelligence update` changes `schema_version`, the
   `@ainova-systems/sync` pin and that package's lock row in an existing
   Intelligence project. Creating a project (`init` on an absent one) and
   converting a legacy one still write them.
2. A project stamped an older **minor or patch** within the engine's major is
   rendered as it is. Every entry point prints one `WARNING:` line naming both
   versions and `intelligence update`; the tracked files keep their bytes. The
   store is restored from the lock as committed, which can need the network
   for an older sync content pin.
3. A project that needs a change the current CLI cannot render around — an
   older **major**, a sync content `version` that is not an exact version, or a manifest
   shape that only migration reads — is refused
   with `IS_STATUS=needs-update` and exit 6, naming `intelligence update`. In
   CI the message is the same; there too only `update --apply` aligns.
4. `sync --check` follows `sync`: an older stamp is a warning, not "sync
   needed". `status --check` reports it as a note, as it reports a project
   stamped ahead.
5. Other mutating commands (`package`, `source`, `adapter`, `registry`) change
   only what they own and keep the stamp and the sync pin as found, behind the
   same warning.

## Consequences

- Upgrading the CLI changes no tracked file until someone runs `update` and
  commits its diff; the version a project is on is always a reviewed change.
- A project behind the CLI renders with the new engine and its committed sync
  content. The generated files may differ from what the older CLI produced;
  that difference is a sync result, reviewed like any other.
- A fresh clone of a project pinned to an older sync content version fetches
  that version instead of receiving the bundled one.
- Messages and docs that name `intelligence init --apply` for alignment name
  `intelligence update` instead; `init --apply` stays the conversion path for
  legacy projects.

## Rejected

- **Refusing every older project until `update` runs.** A teammate who
  upgraded first could not sync at all while the team is still on the old
  version — the cadence problem decision 0005 removed for the other direction.
- **Aligning in `sync` but leaving the files unstaged.** The diff still
  appears, and the next commit picks it up unreviewed.
- **Aligning silently in memory without writing.** The render would claim a
  version the committed files do not hold, and two teammates would render the
  same commit differently.
