# 0011 — Render independent adapters concurrently

Date: 2026-10-01
Status: accepted

## Context

After 0.17.2 removed most per-file and per-question processes, a full `sync` on
Windows/Git Bash is bound by the remaining serial work: adapters render one after
another, the rollback snapshot copies each owned path one after another, and the
post-render reports wait for each other. On a three-adapter production project
the three adapters alone took most of the engine's time, and nothing in their
work depends on the order they run in — except where it does:

- adapters that manage one tree (`.agents/skills` for Antigravity, Codex, Pi and
  opencode) prune and fill it, and `sync_open_skill_dirs` lets the later ones
  replay the first one's work in the same shell;
- Codex reads the rendered `AGENTS.md` to warn about its size, so it needs the
  `agents` adapter finished;
- the unsynced-directory scan walks the whole repository, adapter outputs
  included, so it can only run once every output exists.

Running a fixed hard-coded pairing would restate ownership the adapter contract
already declares, which the engine rule forbids.

## Decision

1. The engine plans the render from the contract records preflight already
   reads. Adapters whose `managed` paths are equal or nested form a chain and
   run in list order inside one job. A chain starts in a later wave than any
   chain holding an adapter one of its members `requires`. Waves run their
   chains as background jobs; Bash 3.2 has no `wait -n`, so a wave ends when
   all of its jobs end.
2. Each adapter writes one buffer, standard output and error together — the CLI
   already joins them. Buffers print in list order as soon as every earlier
   adapter's has printed, so the output of a successful run is byte-identical to
   the serial order and progress still appears adapter by adapter.
3. A failed adapter ends the run with its own exit status after the buffers of
   the adapters that completed before it in the list; the EXIT handler first
   waits for every background job, then restores every snapshot. Jobs are
   reaped, never killed: killing a job's shell would leave its `cp` or `awk`
   writing after the restore.
4. Snapshot copies of distinct paths run concurrently and are all collected
   before any adapter writes. The unsynced-directory scan runs beside the
   context and model reports and beside removing the snapshots, after the
   render; their output keeps its order.
5. A project adapter is executable code whose reads no contract declares, so
   any selected project adapter keeps the whole render serial, as project
   adapters keep the sync cache off (decision 0010). A plan that cannot be
   made — a requirement cycle, records that do not line up — is serial too.
6. `INTELLIGENCE_SYNC_SERIAL=1` restores the one-at-a-time order everywhere:
   render, snapshots and reports.

## Consequences

- Successful runs render the same bytes and print the same text as the serial
  engine; the A/B harness compares both on fresh project copies.
- On failure the repository ends in the same restored state with the same exit
  status and error text. What can differ is which earlier adapters' progress
  lines precede the error: an adapter listed before the failed one but planned
  for a later wave never ran, so its lines are absent.
- A new built-in adapter that reads another adapter's output must declare
  `requires` on it; the contract is what orders the render.

## Rejected

- **A dependency graph with per-job completion.** Starting each chain the moment
  its requirements finish would shave the gap a wave leaves, but needs `wait -n`
  or a polling loop that spawns `sleep`, and the gain over waves is small while
  every built-in requirement is `agents`.
- **Archiving snapshots with `tar`.** One process instead of one per path, but a
  new dependency on the rollback path whose options differ between GNU, BSD and
  BusyBox.
- **Running the unsynced scan beside the adapters.** Its result would depend on
  which outputs happened to exist when it walked the repository.
