# Context compaction principles

Use these principles to decide what to remove, relocate, or keep. They summarize
current primary guidance; they do not replace repository evidence or an
artifact's semantic ledger.

## What consistently improves instruction context

- Keep persistent instructions specific, focused, and grounded in behavior the
  agent would otherwise miss. Current vendor guidance consistently recommends
  removing unclear or conflicting instructions because they reduce adherence.
- Scope narrow guidance so it loads only for matching work. Anthropic, GitHub,
  and Cursor all recommend path-specific rules instead of making framework or
  component guidance repository-wide.
- Prefer one authoritative statement. Duplicate instructions spend context;
  slightly different copies can also become a conflict whose winner is
  unpredictable.
- Keep what is non-obvious: project conventions, pitfalls, rationale, failure
  behavior, and evidence-backed exceptions. Remove generic tutorials and facts
  the agent can obtain directly from code or configuration.
- Use progressive disclosure for skills. Keep the executable core in
  `SKILL.md`; move optional detail to a nearby reference and name the exact
  condition under which the agent reads it.
- Test changes on representative work. Instruction quality is behavioral, so a
  byte reduction alone cannot prove that meaning or adherence survived.

## References are not automatically compression

Indirection saves context only when the target is not loaded until it is needed.
Anthropic explicitly notes that `@path` imports still enter startup context. A
plain Markdown link has the opposite risk: some tools will not load it at all.

Use a reference when all three conditions hold:

1. the parent artifact remains actionable without the detail;
2. the parent gives a precise condition for reading the reference; and
3. every adapter that needs the detail copies or can resolve the reference.

This works naturally for skill-local `references/`. It is usually the wrong fix
for an always-on rule: scope the rule, convert its procedure to a skill, enforce
it mechanically, or delete redundant material instead.

## Preserve natural language

Compaction changes the information architecture, not the desired voice of the
agent. Keep complete sentences, clear headings, reasons that support judgment,
and one concrete example where it prevents ambiguity. Do not achieve a smaller
file by instructing the agent to answer tersely or by rewriting the source into
telegraphic fragments. Persistent instructions shape behavior as well as task
decisions, so clipped source language is a quality risk rather than a valid
optimization.

## Primary sources

- [Claude Code memory documentation](https://code.claude.com/docs/en/memory) — specific instructions, path scoping, conflict removal, and why imports do not reduce startup context.
- [Agent Skills best practices](https://agentskills.io/skill-creation/best-practices) — omit generic knowledge, keep coherent units, and use conditional progressive disclosure.
- [GitHub Copilot custom-instruction guidance](https://docs.github.com/en/copilot/tutorials/customize-code-review) — short, focused instructions, path-specific files, concrete examples, and iteration.
- [Cursor rules documentation](https://docs.cursor.com/context/rules) — focused, actionable, scoped rules and composable rule files.
