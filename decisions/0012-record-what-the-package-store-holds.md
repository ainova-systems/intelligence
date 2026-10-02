# 0012 — Record what the package store holds

Date: 2026-10-02
Status: accepted

## Context

A consuming project rendered a stale package for weeks. Its `intelligence.lock`
pinned one commit while `.intelligence/packages/<name>/` held a much older copy,
and `intelligence status --check` reported the package as good.

The store holds plain files only: acquisition copies the tree and drops `.git`,
so nothing on disk says which commit a package directory came from. `sync`
restored a package only when its directory was missing, and `status --check`
checked existence and then printed the SHA it read from the lock. The ordinary
team flow produced the gap: a teammate moves a package and commits the lock; a
`git pull` brings the lock but not the ignored store; `sync` keeps the old
content. Switching to a branch with a different lock does the same. The bundled
`@ainova-systems/sync` usually escaped only because alignment rewrites its lock
row on upgrade.

## Decision

1. Every write of a package into the store records the lock row it now
   satisfies — name, url, path, resolved ref and SHA — in
   `.intelligence/packages/.installed`, one row per package, fields separated by
   the lock's unit separator. Package add, update, remove, locked restore, the
   bundled-content install and legacy conversion maintain it.
2. The record lives beside the packages, not inside one. A file in a package
   directory is package content: the engine would render or discover it.
3. A package is installed only when its directory exists and its record equals
   its lock row. `sync` restores any package that is missing, unrecorded or
   recorded differently, through the existing verified path: fetch the locked
   commit into staging, verify it, then replace the directory.
4. `status --check` reports the store's recorded commit, not the lock's, and
   fails for a package that records none or records another.
5. A store written before this record exists is fetched again once. Trusting a
   directory without a record is the defect; the bundled engine content seeds
   offline, and packages from Git needed the network to install in the first
   place.

## Consequences

- A pull or branch switch that moves the lock is followed by the matching
  store on the next `sync`, without `--force` and without deleting `.intelligence/`.
- The first `sync` after upgrading the CLI fetches every Git package once.
- The record is local, ignored state like the rest of the store. It states what
  the CLI installed; it does not authenticate bytes someone edited by hand, which
  remains the integrity work the roadmap lists separately.

## Rejected

- **Storing the SHA inside each package directory.** The engine reads package
  directories as content.
- **Trusting a directory that has no record.** That is the behaviour that let
  the stale copy render.
- **Hashing every package on each sync.** It would detect hand edits too, but
  costs a full read of the store on every run; the record answers the question
  that caused the incident — which locked row was installed — for the price of
  reading one small file.
