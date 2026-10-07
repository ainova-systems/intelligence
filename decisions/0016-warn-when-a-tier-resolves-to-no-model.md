# 0016 — Warn when a tier resolves to no model

Date: 2026-10-07
Status: accepted

## Context

An agent's `tier` resolves per tool through the built-in defaults in
`engine/lib/common.sh` and any `models.<tool>.<tier>` override in
`intelligence.yaml`. A tier neither defines — a misspelled `haevy`, as a rule —
rendered an empty `model` for every tool while sync exited 0 and printed
nothing, so the mistake surfaced only when a tool refused the agent or quietly
fell back to its own default (issue #39). Custom tier names are legitimate: a
project may define `models.claude.review-deep` for one tool and no other.

## Decision

1. A tier that resolves to no model still renders, with an empty `model`, and
   sync prints one `WARNING:` per tool and tier — naming both and the two ways
   out: a standard tier, or a `models.<tool>.<tier>` override. The warning is
   deduplicated across every agent carrying the tier.
2. It is a `WARNING:` line, not an indented note, so `sync --compact` and an
   unchanged compact run keep it.
3. A tier the manifest defines for a tool resolves quietly for that tool.

## Consequences

- A typo is visible on the first sync without blocking anyone's render.
- A project using a custom tier for one tool sees a warning for each other tool
  until it defines the tier there too; that is the information it needs.
- Nothing refuses the render, so a project that ignores warnings can still ship
  an agent without a model.

## Rejected

- **Refusing the sync.** A project that deliberately defines a custom tier for
  one tool would fail on every other enabled tool until it added an override
  for each.
- **Falling back to `heavy`.** It hides the typo and silently spends a costlier
  model than the author chose.
- **Leaving it silent.** The issue this record closes.
