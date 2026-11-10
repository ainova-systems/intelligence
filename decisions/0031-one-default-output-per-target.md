# 0031 — One default output per target

Date: 2026-11-10
Status: accepted

## Context

A target entry in `intelligence.yaml` may leave out `output:`. The engine then
rendered into `.<adapter>`, while the CLI assumed the tool's own location for
three adapters: `AGENTS.md` for `agents`, `.github` for `copilot` and `.agents`
for `antigravity`. `adapter list`, the Git policy that `init` and
`adapter enable` write, and the contract checks of `status --check` read the
CLI's answer, so for such an entry they named paths no sync writes: the ignore
lines covered `.github/` while sync wrote `.copilot/`.

`init` and `adapter enable` always write `output:` for a target they add, so
only an entry written by hand meets the default.

## Decision

1. The output of an entry without `output:` is `.<adapter>` for every adapter,
   `.agents/AGENTS.md` for `agents`. The engine declares it once,
   `target_default_output_var` in `engine/lib/common.sh`, and the engine, the
   sync cache and every CLI reader of an existing entry take it from there.
2. Where `init` and `adapter enable` put a target they add is a separate
   question, answered by the CLI alone (`init_target_output`): the tool's own
   location, written into the manifest. `adapter list` shows that location for
   a target the manifest does not hold, since it is what enabling it writes.

## Consequences

- For an entry without `output:`, `adapter list`, `status --check` and the
  ignore lines name the paths sync renders. A manifest with explicit outputs
  behaves as before.
- Rendered output does not move: a project that relied on the default keeps
  its files where they are.
- An entry written without `output:` still renders where its tool may not read
  it; `adapter list` now shows that path, and adding `output:` moves it.

## Rejected

- **The tool's own location as the engine default.** It would move rendered
  output for every hand-written entry on upgrade, and an `agents` entry would
  start overwriting a hand-written root `AGENTS.md` that `init`'s onboarding
  never backed up.
