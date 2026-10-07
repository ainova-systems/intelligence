# 0015 — Separate reasoning effort from the model tier

Date: 2026-10-07
Status: accepted

## Context

Decision 0013 let `tier` carry two meanings in one adapter. Every tool mapped it
to a model, and Codex additionally derived `model_reasoning_effort` from it —
`xhigh` for `frontier`, `high` for `heavy`, `medium` and `low` below — because
GPT-6 gives `frontier` and `heavy` the same model and effort was the only way to
tell them apart.

That coupling left an author no way to say what they meant:

- An agent could not ask for a model and an effort independently. A cheap model
  with deep reasoning, or the strongest model at low effort, had no spelling.
- Claude Code accepts `effort:` on subagents and skills (`low`, `medium`, `high`,
  `xhigh`, `max`), so a project wanting it there had to edit generated output.
- The same tier produced different behavior per tool: an effort in Codex, none
  in Claude Code, Copilot or OpenCode. A tier name was quietly an effort
  setting in one tool only.
- Codex's configuration reference lists `ultra` above `max`; Claude Code stops
  at `max`. A neutral scale has to say what a tool without the top level gets.

## Decision

1. **`tier` selects the model; `effort` selects the reasoning effort.** Neither
   sets the other in any tool. An agent or skill without `effort:` emits no
   effort anywhere, and the tool's own setting applies.
2. **One neutral scale**, lowest first: `low`, `medium`, `high`, `xhigh`, `max`,
   `ultra`, matched exactly and case-sensitively like `tier` and `access`.
3. **A level a tool lacks maps to the nearest lower level it has.** Claude Code
   receives `ultra` as `max`; Codex receives every level. Whether a particular
   model supports a level is not the engine's call: a manifest can override the
   model, and Claude Code itself falls back to the highest level the active
   model supports at or below the one set.
4. **Tools with no per-agent effort field emit nothing.** Copilot, Cursor,
   OpenCode, Antigravity and Pi never receive an `effort:` key, in agents or in
   their own skill copies.
5. **An off-scale value warns and is otherwise absent.** `effort: hiigh` or
   `effort: High` prints one `WARN` line naming the source file, the value and
   the allowed levels, renders as if `effort:` were not there, and leaves the
   exit code alone. The warning comes from the frontmatter lint every sync
   already runs over its sources, so it names the source once however many
   tools render it.
6. **An empty value is an absent effort**: `effort:` or `effort: ""` warns about
   nothing, and no generated file carries an empty `effort:` or
   `model_reasoning_effort`.
7. **Skills follow the same rules.** `.claude/skills/` receives Claude's level;
   the shared `.agents/skills/` tree keeps a valid level as written, as it keeps
   `disable-model-invocation`; an empty or off-scale value is removed from every
   tree. Codex has no per-skill effort, and nothing is derived for it.

This supersedes decision 0013's point 2, where Codex separated `frontier` from
`heavy` by reasoning effort, and point 3's clause that an agent without a tier
resolves to `heavy` for its Codex effort. The tier vocabulary and every model
default stay as 0013 set them.

## Consequences

- In Codex, `frontier` and `heavy` now render identical agents, as they already
  did in Copilot. An agent that relied on the derived `xhigh` or `high` keeps its
  behavior by stating `effort:` — or gets Codex's own default without it.
- A Codex agent without `effort:` no longer carries `model_reasoning_effort`, so
  a project's Codex configuration decides its effort.
- One spelling reaches every tool that has a native field. Adding a tool's
  effort field means one entry in `effort_levels_var`; the vocabulary does not
  change.
- A typo in an installed package's agent degrades to the tool default with a
  warning instead of failing the sync for everyone who installed it.

## Rejected

- **Failing sync on an unknown value.** Packages arrive from other authors and
  registries. A strict check would let one typo in someone else's package block
  every team that depends on it until its author released a fix.
- **Keeping effort derived from the tier as a default.** It reintroduces the
  hidden second meaning this decision removes, in one tool only.
- **Checking per-model level availability in the engine.** The engine does not
  know which model runs after a manifest override, and the tools already fall
  back on their own.
- **Passing an unsupported level through unchanged.** Claude Code documents no
  `ultra`; the nearest lower level is the closest honest rendering.
