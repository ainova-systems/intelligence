# 0013 — Add a frontier model tier

Date: 2026-10-07
Status: accepted

## Context

Agents name a tool-neutral `tier` — `heavy`, `standard` or `light` — and each
adapter maps it to a model through the defaults in `engine/lib/common.sh`. In
October 2026 the vendors' lineups no longer fitted three tiers:

- Anthropic ships Claude Fable 5.1 above Opus 5.5, and Claude Code accepts a
  `fable` subagent alias. Haiku 4.5 retires no sooner than 2026-10-15 and has
  no successor.
- OpenAI's GPT-6 ships `gpt-6-astra`, `gpt-6.1-sol` ("near-Astra performance at
  a lower cost") and `gpt-6-luna`. There is no GPT-6 Terra, so the three GPT-5.6
  tiers have no one-to-one successors.
- Cursor documents only `inherit` or a concrete model ID for a subagent's
  `model`; `fast` survives only as a bracket parameter of a model ID.

An agent doing long-horizon autonomous work could ask for no more than `heavy`,
which on Claude meant Opus rather than Fable.

## Decision

1. A fourth tier, `frontier`, sits above `heavy`: the most capable model a tool
   offers, for work whose difficulty justifies its cost. The name describes the
   model class and stays clear of the `low`…`max` effort scale both Claude and
   Codex use.
2. Where a vendor has fewer models than there are tiers, tiers share a model
   rather than reach for one that is retiring or undocumented:
   - Codex and Copilot map `frontier` and `heavy` to `gpt-6-astra`, `standard`
     to `gpt-6.1-sol`, `light` to `gpt-6-luna`. Codex separates the first two
     by reasoning effort: `xhigh` for `frontier`, `high` for `heavy`.
   - Claude Code and OpenCode map `light` to Sonnet, the same as `standard`.
   - Antigravity maps `frontier` and `heavy` to `pro`; Cursor maps every tier
     to `inherit`.
3. An agent without a `tier` resolves to `heavy` for its model and, in Codex,
   its effort; the two never come from different tiers.

## Consequences

- A project picks the strongest model per tool with one word, and a manifest
  `models.<tool>.frontier` override pins it like any other tier.
- Some tiers render identical output for some tools. That is the honest
  mapping until the tool offers a distinct model or a per-tier effort the
  adapter emits; adding one changes the defaults, not the vocabulary.
- A project that pinned an old default under `models:` keeps it, and sync
  reports it as differing from the new default.

## Rejected

- **`max` as the tier name.** It reads as the effort level of the same name.
- **`gpt-5.6-terra` for `standard`.** It remains available only during the
  GPT-6 rollout, so it would be the next default to break.
- **Keeping Haiku for `light`.** A default that stops resolving on a known date
  turns every `light` agent into a failure a project did not cause.
