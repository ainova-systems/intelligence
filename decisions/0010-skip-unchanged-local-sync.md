# 0010 — Skip unchanged local sync after verifying inputs and outputs

Date: 2026-09-30
Status: accepted

## Context

A local project fixture with six adapters, 23 rules, 15 agents and 103 skills
took a median 18.2 seconds to sync without changes on Windows/Git Bash.
Every run rewrote 566 output files without changing their contents. Rendering
accounted for roughly ten seconds and preparation plus output snapshots for
four seconds. A separate scan of the full repository for unconfigured source
directories took another 4.4 seconds. These measurements identify repeated
local work independently of remote package acquisition.

The first delivery is a fast unchanged sync. Updating only the affected outputs
after a source edit is a later, separate improvement.

## Decision

1. The CLI owns an optional, disposable cache under `.intelligence/sync-cache/`.
   The engine keeps rendering local sources through its existing contracts;
   it neither acquires packages nor owns persistent project state.
2. Lifecycle, lock validation and missing-store restoration run before reuse.
   A hit requires content fingerprints of the manifest, lock, sources including
   skill resources, CLI and engine code, relevant configuration and invocation,
   and current adapter outputs. Names, entry types and executable state matter;
   file timestamps alone are insufficient. Output paths come from the current
   built-in contracts, never from an untrusted cached path list.
3. An unchanged run skips rendering, snapshots and repository-wide discovery
   without changing output bytes or modification times. It retains the normal
   success/status contract and useful diagnostics from the last full run.
4. There is one cache slot per project. Full and filtered invocations do not
   claim each other's coverage. All enabled output paths are checked
   conservatively, including shared destinations.
5. `intelligence sync [adapter] --force` bypasses reuse and refreshes both
   outputs and diagnostics. New unconfigured directories outside the declared
   sources are discovered on a full run, including `--force`; a cache hit
   replays the last full run's discovery results. `--compact` keeps its existing
   line contract and works with either mode.
6. A missing, damaged or unusable cache cannot authorize a skip. Project
   adapters and filesystem shapes whose dependencies cannot be fingerprinted
   safely use ordinary sync. The cache is data, never executable shell input.
7. Cache publication is atomic and follows successful rendering. Recheck inputs
   after rendering; an input change during the run must not bless outputs as
   current. Failure preserves the existing engine's rollback and exit status.
   Capture diagnostics while streaming renderer progress; capture failure cannot
   publish a success record. Normal output announces validation before preflight
   and ends with a clear result, separated from retained warnings on a cache hit.
8. Fingerprints detect changes relative to a successful local render. They do
   not authenticate installed package contents against an upstream release or
   replace the locked-acquisition integrity work.

## Acceptance criteria

- After a successful full sync of a fixture with local sources and an installed
  store, repeat the same sync: it succeeds without rendering, taking output
  snapshots or scanning the repository for unconfigured sources; output bytes
  and modification times are unchanged.
- Edit a rule, agent or skill resource, including a same-size edit with the old
  timestamp restored; add, rename or remove a source file: the next sync renders
  the current sources. Include binary skill assets and executable state.
- Delete or edit an output with unchanged sources: sync repairs it instead of
  trusting the previous source fingerprint.
- Change configuration, target selection or installed renderer code: sync
  cannot reuse results for the old inputs. A filtered run cannot stand in for a
  full run or silently bypass an ownership conflict.
- After a full run reports a warning, repeat with normal and compact output:
  useful warnings and context/status remain available. Add an unconfigured
  source directory outside the declared sources, then run `sync --force`: the
  new directory is reported. Forced compact sync also satisfies its line contract.
- Corrupt or remove cache data, use project adapters or unsafe link layouts:
  sync follows a safe ordinary path. Invalid lock/configuration, unreadable
  inputs and adapter failures cannot turn into cached success. After an adapter
  failure, prior outputs remain intact and a corrected retry performs the work.
- Exercise paths with spaces and special characters, POSIX executable bits and
  supported symlink cases, plus npm launcher execution on the CI host matrix.
- Run the repository verification command and compare repeated before/after
  timings on the same local project fixture. Keep timing assertions out of functional
  tests; prove skipped operations and correct outputs instead.

## Consequences

Repeated local sync avoids the expensive operations without requiring a
dependency graph for individual rendered files. Changes and repairs retain the
existing complete rendering and rollback behavior. Deleting the cache or using
`--force` is the recovery path; reverting this change makes every sync render
again without migrating project intent or the lock format.

Unconfigured-source discovery is explicitly a full-run diagnostic. Its saved
warnings remain useful on a hit, but discovering new unrelated directories
requires a full run. Document that boundary beside the command.

## Measured result

Five alternating runs of `main` at `5d364ce` and this implementation on identical
local source/store copies in Windows/Git Bash measured median unchanged-sync
times of 24.77 and 8.26 seconds, respectively (about 3x faster). The fixture had
six adapters and 566 output files. All output bytes matched; ordinary sync
rewrote all 566 files, while every cache hit preserved their modification times.
The fixture omitted the application's unrelated build and dependency trees, so
this comparison does not include the extra discovery cost in a full checkout.
Absolute timings vary with host load; regression tests assert skipped operations
and correct bytes rather than a timing threshold.

### Progress and fingerprint follow-up

Version 0.17.0 buffered renderer output until completion. Sync now streams that
output while capturing diagnostics, announces validation phases, and separates
retained warnings from its final unchanged result. Fingerprint list descriptors
stay open through enumeration instead of reopening a file for every entry;
content hashes and filesystem checks are unchanged.

On the same six-adapter Windows fixture, four additional timing pairs alternated
which implementation ran first. Released sync measured 10.27, 24.79, 14.66 and
11.82 seconds; the descriptor change measured 8.28, 7.49, 6.72 and 6.27 seconds
(medians 13.24 and 7.11 seconds). Five earlier pairs also favored the change,
but unrelated host activity made timings variable; these figures are observations,
not a latency guarantee. All 566 generated files matched the released output,
and a subsequent candidate cache hit preserved every file's bytes and mtime.

### Single-walk fingerprint follow-up

Version 0.19.0 keeps this decision's contract and cuts the processes a hit
starts (decision 0015): one `find | awk | git hash-object` pipeline fingerprints
tooling, inputs and outputs together, the package descriptor, manifest and lock
are read in one pass each of the CLI's and the engine's readers, and the record
is sealed by its own hash instead of a separate report check. Inputs are still
rechecked after rendering, outputs still come from the built-in contracts, and
a damaged or older record still authorizes nothing.

On a Windows/Git Bash scratch export of this repository's own project (four
adapters, about 300 tooling, source and output entries), seven alternating
cache hits measured a median 3.90 seconds for `main` and 0.74 seconds for this
change (runs 3.67 to 4.76 and 0.70 to 1.09). While other processes loaded the
host — a bare `bash` start took 94 to 122 milliseconds instead of 37 — the
medians were 6.02 and 1.04 seconds: both are process-bound. A forced render by
`main` followed by one from this change left no difference in the repository;
cache-hit, forced and compact output streams matched, and a hit kept every
output's bytes and modification time.

## Rejected

- Timestamp-only checks: editors can preserve timestamps and file sizes.
- Source-only checks: deleted or edited outputs would remain broken forever.
- A repository scan on every hit: it would remain the dominant local cost.
- Skipping lock validation or restore: performance must not weaken lifecycle
  refusals or the fresh-clone contract.
- Per-file incremental generation in this change: it adds dependency and output
  ownership work that unchanged-run detection does not need.
- A new Node or Python runtime requirement: the CLI already has the tools
  required to fingerprint files in batches.
