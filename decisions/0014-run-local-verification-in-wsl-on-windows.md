# 0014 — Run local verification in WSL on Windows

Date: 2026-10-07
Status: accepted

## Context

`bash cli/tests/verify.sh tests` could not finish inside a working session on the
maintainer's Windows host. Under Git Bash the seventeen suites took 52 minutes,
all passing: `e2e-sync-cache` 635 s, `e2e-negative` 633 s, `e2e-lifecycle` 573 s,
and `unit-manifest` 56 s for a parser suite. On the same host, in a WSL 2 Ubuntu
distribution, all seventeen suites took 167 s, and `cli-e2e` takes 79 s on
`ubuntu-latest`.

The cause is the platform's process cost, not the code under test or the files it
reads. Git Bash emulates `fork` and takes 55–120 ms to start a process; Linux
takes about one. The suites start tens of thousands of processes: unit
assertions pipe through `awk` and `grep`, and the e2e suites invoke the CLI
hundreds of times. WSL only helps when the files are on its own
filesystem: a `/mnt/<drive>` path goes through 9P, and the engine measured two to
four times slower there than under Git Bash.

## Decision

1. On Git Bash, outside CI, `verify.sh` runs the scope it resolved in WSL when
   a distribution provides the tools that scope needs: `git`, `awk`, `tar` and
   `mktemp`, plus `shellcheck` for a lint scope. `INTELLIGENCE_VERIFY_WSL_DISTRO`
   names a distribution other than the default.
2. The runner copies the working tree as git sees it into a private directory
   on the distribution's filesystem: tracked and untracked files, without
   ignored files or unstaged deletions. Every run gets a fresh copy, which is
   removed afterwards. Uncommitted work is verified exactly as it would be in
   place.
3. A bare run resolves its scope from the diff on Windows and hands an explicit
   scope to WSL, so the skipped list and the verdict come from the caller.
   The exit status of the WSL run decides the verdict, so a run that could not
   start or unpack cannot report success.
4. Delegation is never silent. A run states that it went to WSL. When no
   distribution can run the scope, it says so and stays in Git Bash.
   `INTELLIGENCE_VERIFY_NATIVE=1` keeps every run in Git Bash.
5. CI runs exactly what it ran before. The Windows CI job calls its suites
   directly, so `verify.sh` never delegates there.

## Consequences

- On the maintainer's host the test scope finishes in under three minutes
  instead of close to an hour, and lint in 16 s.
- A delegated run tests Linux semantics, as CI does, and does not test Git
  Bash. Windows-only paths in the suites, such as the junction case in
  `e2e-sync-cache` and the `cygpath` spellings in `unit-upgrade`, run only under
  `INTELLIGENCE_VERIFY_NATIVE=1` or in the Windows CI job. Run natively when a
  change touches Windows path handling.
- `unit-upgrade` skips its launcher cases when the distribution has no `node`,
  and says so.
- Lint inside WSL uses that distribution's `shellcheck` version, which can differ
  from the version installed on Windows.
- Reverting this change restores in-place Git Bash runs. It changes no product
  behaviour and no shipped file, because npm builds drop `cli/tests/`.

## Rejected

- **Running the suites against `/mnt/<drive>`:** 9P file access is slower than
  Git Bash.
- **Copying `.git` into the distribution:** only the bare run reads git, and the
  caller already resolved it, so the copy needs only the tree.
- **Reusing a persistent mirror:** removed or renamed files would linger in
  it, and two concurrent runs would share it. A fresh copy of about 2.5 MB costs
  seconds.
- **Making WSL opt-in:** the default would stay unusable, and every run of
  the documented command would keep exceeding a working session.
