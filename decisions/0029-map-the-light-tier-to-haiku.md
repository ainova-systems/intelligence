# 0029 — Map the light tier to Haiku

Date: 2026-11-10
Status: accepted
Amends 0013: point 2's bullet "Claude Code and OpenCode map `light` to Sonnet, the same as `standard`", and its rejected item "Keeping Haiku for `light`". The rest of 0013 stands as 0015 left it.

## Context

Decision 0013 gave `light` the same Sonnet model as `standard` on Claude Code
and OpenCode, because Haiku 4.5 was retiring with no successor and a default
that stops resolving on a known date fails every agent that uses it.

That premise no longer holds. Claude Code's `haiku` alias resolves to Haiku 5.5
on the Anthropic API ([model configuration](https://code.claude.com/docs/en/model-config),
checked 2026-11-10), and its subagent `model` field lists `haiku` beside
`sonnet`, `opus` and `fable` ([subagents](https://code.claude.com/docs/en/sub-agents)).
OpenCode selects models by `provider/model` catalog IDs from models.dev
([models](https://opencode.ai/docs/models/)), whose Anthropic catalog lists
`claude-haiku-5-5` (checked 2026-11-10).

Meanwhile `light`, documented for lookups and simple formatting, renders the
same model as `standard` for every Claude user. A project gets a cheaper model
only by pinning `models.claude.light: haiku` itself, and a package cannot route
mechanical work to a cheaper rung at all.

## Decision

1. Claude Code maps `light` to `haiku`, the alias, so the default follows the
   vendor's current Haiku as `sonnet`, `opus` and `fable` already do.
2. OpenCode maps `light` to `anthropic/claude-haiku-5-5`, the catalog ID of the
   same model.
3. Every other tool and tier keeps its default, and the tier vocabulary does
   not change.

## Consequences

- A `light` agent costs less and reasons less on Claude Code and OpenCode
  after the upgrade, with no edit in the project. A project that wants the
  earlier model pins `models.claude.light: sonnet` and
  `models.opencode.light: "anthropic/claude-sonnet-5-5"`; sync's model-drift
  report names that override against the new default.
- `light` and `standard` render different agents on Claude-backed targets, so
  a package can route mechanical work to the cheaper rung.
- On Bedrock or Vertex the `haiku` alias resolves to whatever Haiku that
  provider offers, as `sonnet` and `opus` already do there.
- The OpenCode ID is concrete and moves with a later Haiku release by an edit
  of the default, as its other tiers do.

## Rejected

- **Keeping Sonnet and documenting the override.** Every project would carry
  the same pin to get what the tier already says it is for.
- **A tier table shipped by a package.** Model choice is the project's:
  `models:` lives in the manifest, and two packages shipping different tables
  would need a precedence rule for a decision that is not theirs.
