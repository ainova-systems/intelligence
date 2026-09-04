---
name: intelligence-compact-context
description: "Reduce rules, agents, and skills without changing behavior or teaching terse output"
argument-hint: "[target: rules|agents|skills|all]"
agent: intelligence-architect
---

# Compact intelligence context

Reduce persistent and on-demand prompt cost by changing structure before wording.
The result must preserve the layer's behavioral contract and ordinary, complete
language; a smaller file is not a success if agents become terse, vague, or less
reliable.

## Analyze

1. Resolve `<manifest>`, `<content-dir>`, and `<module>`. Enumerate the source
   directories declared under `sources.rules`, `sources.agents`, and
   `sources.skills`; skip installed package sources and generated adapter output.

2. Read `<module>/references/conventions.md`, the `intelligence-authoring` rule,
   and [references/principles.md](references/principles.md). The reference
   explains which forms of indirection save context and which merely move text.

3. Run `<sync-cmd> --compact` and save the `CONTEXT:` line as the baseline,
   including its rendered `agents-md` byte count. Record individual source-file
   byte and line counts for the requested target.

4. Invoke `intelligence-review-skills` for the same target. Reuse its findings
   for duplication, misplaced content, scope, stale artifacts, pressure markers,
   history narrative, and description budget; do not reproduce its audit.

5. Build a semantic ledger before drafting edits. For every candidate passage,
   record:

   - the behavior, constraint, procedure, or expertise it carries;
   - its one authoritative owner;
   - when it must load;
   - the reason or example needed to apply it correctly;
   - the repository evidence or external documentation that supports it.

   Two passages are duplicates only when those meanings match. Similar wording
   with different scope, priority, or failure behavior is not duplication.

## Draft the compaction

6. Apply structural reductions in this order:

   1. Replace an instruction with a deterministic gate or command when the
      repository already enforces it.
   2. Delete generic knowledge and facts the agent can read directly from the
      repository, unless a non-obvious interpretation is the instruction.
   3. Keep one owner for duplicated guidance and remove the copies. A skill may
      invoke another skill by name; an agent may list a skill; neither restates
      the called artifact.
   4. Add `paths:` to rules that matter only in part of the repository.
   5. Move multi-step procedures from rules or agents into skills, and move
      reusable constraints or expertise to the artifact type that owns them.
   6. Move optional skill detail into skill-local `references/` and state the
      exact condition that requires each file. Do not use an always-loaded
      import or an unconditional read step and call that compaction.
   7. Tighten prose only after the preceding reductions are exhausted.

7. Preserve language quality while tightening prose:

   - Use complete grammatical sentences and ordinary project vocabulary.
   - Preserve the reason when it guides judgment, and keep one minimal example
     when the rule would otherwise be ambiguous.
   - Preserve triggers, boundaries, ordering, failure behavior, verification,
     and output contracts exactly.
   - Shorten descriptions by retaining the unique trigger that distinguishes a
     sibling; never reduce them to vague labels.
   - Do not add instructions telling agents to be terse, abbreviated, clipped,
     or concise unless that response style is an explicit product requirement.
   - Do not turn prose into fragments, dense acronyms, slash-separated phrases,
     or unexplained labels. Compression targets redundancy, not grammar.

8. Treat references according to load behavior:

   - A conditional skill reference saves startup context.
   - An always-loaded import improves organization but does not save context.
   - A plain link is navigation, not guaranteed instruction loading; never hide
     a critical constraint behind one.
   - An always-on rule that is too large normally needs deletion, scoping, a
     gate, or conversion of its procedure into a skill—not a reference index.

## Approval and apply

9. Present a proposal grouped as `DELETE`, `MERGE`, `SCOPE`, `MOVE`,
   `REFERENCE`, or `REWRITE`. For each item show the owner, semantic contract,
   estimated bytes saved, and any behavior that could change. Ask for approval
   before changing meaning, ownership, scope, or load timing.

10. Apply only accepted items to project-owned sources. Preserve unapproved
    passages byte-for-byte and never edit generated output or installed package
    sources locally.

## Verify

11. Compare the semantic ledger with the diff. Every original behavior must be
    present once in its authoritative owner, deliberately removed with approval,
    or enforced by the named deterministic mechanism. Check that no move created
    a dead link, unconditional reference load, conflicting instruction, or
    broader scope.

12. Run `<sync-cmd> --compact`, require `IS_STATUS=ok`, then run
    `intelligence status --check`. Compare the new `CONTEXT:` line and per-file
    counts with the baseline.

13. Exercise three representative prompts when the environment supports agent
    evaluation: one direct case governed by a compacted instruction, one adjacent
    judgment case that needs its reason, and one ordinary explanation that would
    reveal clipped language. If behavioral evaluation is unavailable, report
    that explicitly; a smaller byte count proves size reduction, not quality.

14. Report bytes and percentage saved for always-on and custom context, the
    before-and-after `agents-md` size, the artifacts changed, the semantic
    checks performed, and any remaining item that needs an owner decision.
