# 0024 — Route Codex scoped rules through its override

Date: 2026-10-23
Status: accepted

## Context

Codex reads root instruction files but does not attach Markdown rules by `paths:`
globs. The shared index lists scoped rules without their matching patterns, and
local scoped rules have no Codex delivery path. Generating nested instruction
files would write into application directories and cannot represent every glob.

## Decision

Extend the Codex override channel from decision 0021 with a compact index of
scoped rules selected for Codex. Each entry pairs the source patterns with a
source link. One instruction asks Codex to read and follow matching rules before
working on files, applying each rule only within its scope. Preserve the complete
shared `AGENTS.md` and additional always-on rules in the override.

## Consequences

- Routing is model-followed guidance, not a native matcher or loading guarantee.
- Local and targeted scoped rules use the existing ignored override path.
- Other adapters and the shared instruction file retain their behavior.
- The override exists while either scoped routing or extra always-on rules need
  it. Hand-authored overrides remain protected; existing size warnings apply.
- Source rules remain the only copies of their bodies; sync adds no nested files.

## Rejected

- Putting routing into shared `AGENTS.md`: tools with native scoped-rule channels
  would receive redundant loading instructions.
- Inlining scoped rule bodies: unrelated tasks would pay their full context cost.
- Nested `AGENTS.md`: intrusive output locations and incomplete glob coverage.
