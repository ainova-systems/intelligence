# 0015 — Check whether sync is needed

Date: 2026-10-07
Status: accepted

## Context

Save hooks, editor tasks and CI jobs need one answer: would `intelligence sync`
change a generated file? Until now the only way to ask was to run sync, which
writes, and the cheapest answer it could give — an unchanged run that reuses
its cache (decision 0010) — took 4.3 to 4.9 seconds on Windows/Git Bash for this
repository's own project: four adapters, about 300 tooling, source and output
entries.

Profiling that cache hit showed where the time went. A process start costs 40
to 120 milliseconds under Git Bash (a `$(...)` fork about 55, `awk` about 96,
`git` 65 to 120), while one `find | git hash-object --stdin-paths` over every
input and output together costs about 0.19 seconds: the cost is the number of
processes, not the bytes. A hit started about 45 external commands plus their
subshells: loading the libraries took about 150 milliseconds, lifecycle
preflight 430 to 590, the store check 230 to 390, deriving the cache's
dependencies 700 to 960, the input and output fingerprints 850 to 1100 and 720
to 820, and reading the record 250. Each fingerprint ran its own walk, two
sorts, a `cygpath` and two `git` processes; the manifest and lock were parsed
by fourteen `awk` runs; every enabled adapter contract cost two forks.

## Decision

1. `intelligence sync [adapter] --check` changes no generated file. It exits 0
   when generated files are what sync would leave, 2 when sync would change
   them, and with the failure's own status otherwise — sync's refusals keep
   theirs, such as 4 for a newer-major schema. It prints one status line:
   `IS_STATUS=ok` or the new `IS_STATUS=out-of-date`, with the reason in
   `IS_DETAIL`. Code 2 is shared with `config-missing`, which a check cannot
   report, and a failure that would end in 2 is reported as 1, so under
   `--check` 2 means only "sync needed".
2. The check runs sync's preflight under the project lock: schema
   compatibility, lock validation, and restoring a missing or mis-recorded
   package store from `intelligence.lock` — ignored, reproducible state the
   comparison needs. It never applies tracked alignment; a project that needs it
   is reported as `out-of-date` naming `intelligence init --apply`, in CI and
   locally alike.
3. The cache record keeps three fingerprints apart: **tooling** (CLI and engine
   code, plus the invocation and environment that shape rendering — adapter
   filter, root, layout, bash, locale, `PATH`, umask), **inputs** (manifest,
   lock, configured sources with installed packages, the project adapter
   folder) and **outputs** (every path the enabled built-in adapters own or
   manage). A record made by the same tooling answers without rendering: equal
   inputs and outputs exit 0; different ones exit 2 at once and name the side
   that changed. CLI and engine code count as tooling, so an upgrade renders
   instead of claiming that the project needs a sync.
4. Without such a record — none yet, damaged, from an older format, from other
   tooling or another environment — and always under `--check --force`, the
   engine renders inside its existing snapshot transaction (`IS_SYNC_CHECK`),
   compares every snapshotted path with what the render left (names, entry
   kinds, bytes, executable bits) and restores the snapshot whatever the
   answer, so bytes and modification times stay as they were. A clean answer
   is recorded under decision 0010's publication rules, so the next check is
   fast; a difference records nothing.
5. Full and filtered checks never stand in for each other: the adapter filter
   is part of the tooling fingerprint. `--compact` is accepted and changes
   nothing, because the check already prints a single line.
6. A cache hit, of sync or of the check, is budgeted in processes:
   - one `find | awk | git hash-object` pipeline fingerprints all three groups:
     find reports entry kinds by printing directories twice and, where
     executable bits are real, executable files three times; on NTFS its walk
     order is already stable, so the sort other filesystems need is skipped
     and files stream to `git` during the walk; paths reach Git for Windows
     translated from the mount table instead of through `cygpath`;
   - the record is a `state` file sealed by its own hash in `seal`, which the
     same `git` run computes, so a damaged record is recognized without
     another process;
   - the CLI's package descriptor, the manifest and the lock are read in one
     qmap pass, and the manifest's engine shapes in one pass of the engine's
     own readers, the two side by side; readers answer from that preload, and
     a child that may rewrite either document refreshes it;
   - every enabled contract is read in one subshell, built-in adapters stop
     re-sourcing the shared library through a `dirname` process, and the
     dispatcher sources `sync` instead of starting another bash.

## Consequences

- A check answers from the record in well under a second on the Windows host
  that took 4.3 to 4.9 seconds for a cache hit, and a sync hit is several times
  faster than before with byte-identical output and output streams.
- A fast "sync needed" can be a source change that renders identically, such as
  a manifest comment; `--check --force` gives the exact answer.
- A record made under another `PATH`, locale or CLI does not answer; that
  check renders and records the result for its own environment.
- Records written by an earlier CLI are ignored: the first sync after the
  upgrade renders once. Reverting the change makes every sync render again
  once, with nothing to migrate.

## Rejected

- **Answering only from the cache.** A missing record proves nothing either
  way, and CI has none: the check would be unusable exactly where it is most
  needed.
- **A committed, portable fingerprint**, such as an input hash in
  `intelligence.lock`. Every source edit would churn a tracked file and conflict
  on merge, and line-ending and checkout settings make the same content hash
  differently on different machines.
- **Rendering on every check.** Seven to eight seconds per check on this
  Windows host, more under load — too slow for a hook. It stays available as
  `--check --force`.
- **Trusting Git's index or file timestamps** to skip hashing: decision 0010
  already rejected timestamps as proof of unchanged content.
- **Leaving installed packages out of the input fingerprint.** Deferred: it
  needs an amendment to decision 0010.
- **Reading adapter contracts in the background while the preflight runs.** It
  measured no gain on a loaded host, where process starts compete for the same
  CPU, and added a job the lock release would have to wait for.

## Measured result

Medians of seven runs on a Windows/Git Bash scratch export of this repository's
own project, alternating with `main` where both apply (the cache-hit figures
are decision 0010's):

| Run | Median |
|---|---:|
| `sync`, cache hit, `main` | 3.90 s |
| `sync`, cache hit, this change | 0.74 s |
| `sync --check`, answered from the record | 0.73 s |
| `sync --check`, sources changed, answered from the record | 0.58 s |
| `sync --check` without a record: render, compare, restore | 8.2 s (3 runs) |
| `sync --check --force` with a changed source | 7.2 s (3 runs) |

Under load from other processes the record answers stayed near one second
while `main`'s cache hit took six. These are observations on one host, not a
latency guarantee; the tests prove skipped renders, untouched files and exit
codes instead of timings.
