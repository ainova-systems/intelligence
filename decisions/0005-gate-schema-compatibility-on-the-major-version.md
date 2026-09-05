# 0005 — Gate schema compatibility on the major version

Date: 2026-09-05
Status: accepted

## Context

`check_version_compat` refused every project whose `schema_version` was newer than the installed
engine, at any SemVer level. A teammate on `0.11.0` could not run `intelligence sync` in a project
stamped `0.11.6`, although no manifest shape had changed: each release restamps every project it
touches, so a team whose members update the global CLI at different moments was blocked by ordinary
release cadence rather than by a real incompatibility.

The opposite direction was already safe: a newer CLI aligns an older project upward through
lifecycle preflight, and CI refuses that tracked mutation.

## Decision

1. A project stamped a newer **major** than the engine is refused with `IS_STATUS=ahead-of-engine`
   and exit code 4, as before.
2. A project stamped a newer **minor or patch** within the same major proceeds. Every entry point
   prints one `WARNING:` line naming both versions and the CLI update command; `status --check`
   reports the state as a note, not a problem.
3. An older CLI never rewrites a project stamped ahead: preflight skips alignment, so
   `schema_version`, the `@ainova-systems/sync` pin and `intelligence.lock` keep the newer version
   and `sync` renders the content the lock names. Alignment only ever moves a project up to the
   installed CLI.
4. The manifest is therefore additive within a major. A change an older engine of the same major
   cannot read is a breaking change and is released as a major bump.

## Consequences

- Release cadence no longer blocks teammates; only a major bump does, and it says so.
- `0.x` versions gate on the leading `0`, so nothing refuses before `1.0.0`. Deliberate: the
  manifest shapes have been stable across the `0.11` line, and the refusal was the only thing a
  patch bump changed for an older CLI.
- A fresh clone on an older CLI restores `@ainova-systems/sync` from the lock's tag over the
  network instead of the offline bundle, because the bundle seed matches only the CLI's own version.
- The CLI-side preflight (`project_needs_upgrade`) and the engine gate agree on one rule; a change
  to either side updates `cli/tests/e2e-compat.sh` in the same change.

## Rejected

- **Keep refusing any newer stamp.** Right only if every release could change the manifest shape,
  which the additive-within-major contract now forbids; the cost was blocking a team on release day.
- **Treat the minor as the major while `0.x`** (npm caret semantics). It would keep refusing exactly
  the `0.11.x` gaps this decision exists to admit, and the shape has not changed within the line.
- **Let an older CLI align the project to its own version.** That is a downgrade: the next teammate
  on the current CLI moves everything back and the tracked diff ping-pongs between versions.
