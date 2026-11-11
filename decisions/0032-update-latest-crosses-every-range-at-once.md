# 0032 — `update --latest` crosses every range at once

Date: 2026-11-11
Status: accepted

## Context

`intelligence update @scope/name --latest` (0.14.0) moves one package past its
range to the newest stable version and rewrites the requested range to
`^<that version>`. It refused to run without a package name, on the reasoning
that each SemVer boundary is a changelog to read and one confirmation must not
cover several unrelated ones.

A project whose packages have all fallen behind therefore needed one command per
package, each with its own plan and confirmation, to reach a state the plain
`update --preview` had already described in full: every package's line names the
newest version outside its range and the command that follows it. The per-package
loop added no information the plan lacked; it only repeated the confirmation.

## Decision

1. `intelligence update --latest` without a package name crosses the range of
   every package that has one, in one plan and one confirmation, with the same
   preview / ask / apply modes. Each crossing prints its own line with both
   versions and both ranges, so the plan the confirmation covers is a list a
   reviewer reads package by package, and the manifest diff records every
   widened range.
2. Every rule of the named form holds for each package in the sweep: the newest
   stable version is taken, the caret is kept so the next boundary is still a
   decision, a newest version inside the range is an ordinary move that widens
   nothing, and a range reaches the manifest only after its content is installed
   and wired.
3. In the sweep, a `ref:` pin and the engine-content package are treated as a
   plain `update` treats them: a branch pin follows its ref and stays a ref, a
   commit pin stays put, and the engine content is skipped because its pin
   follows the installed CLI. Naming either one with `--latest` still refuses,
   because there the flag asks for a conversion that never happens.
4. The installed CLI is not part of the sweep. `update` keeps naming
   `intelligence upgrade` for it, as decision 0007 requires.
5. The plain plan's outside-range summary names the sweep beside the per-package
   `follow it` command.

## Consequences

- Reading the changelog for each crossed version stays the reader's job, as it
  was for each named run; the plan names every crossing, and the
  `intelligence-upgrade` meta-skill still reads the plan before applying it.
- A project can still cross one boundary at a time by naming the package.

## Rejected

- **Keeping the name requirement.** It repeated a confirmation without adding
  anything to the plan, and the plain preview already listed every crossing.
- **A separate flag (`--all`) for the sweep.** `--latest` already means "the
  newest version"; a second flag would be new vocabulary for the same move, and
  `update` without a name already means every package.
- **Refusing the sweep when the project holds a ref pin or the engine-content
  package.** Both are ordinary in a project; a sweep that stopped on them could
  never run on most projects.
- **Upgrading the CLI inside the sweep.** Decision 0007 rejected folding the npm
  write into a project command, and a sweep is a project command.
