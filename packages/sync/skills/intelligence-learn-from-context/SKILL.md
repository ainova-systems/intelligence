---
name: intelligence-learn-from-context
description: "Capture one approved lesson from a session in an established Intelligence project"
---

# Learn from Context

Use after repository onboarding is complete and a meaningful preference,
working pattern, or recurring friction emerged during the current session and
should persist. It runs analyze (read-only), then apply after approval. This
skill extends an established project; it does not perform first-run repository
analysis or migrate legacy instructions.

## Onboarding gate

1. Locate `<manifest>`, `<content-dir>`, and `<module>`, then run
   `intelligence status --check`.
2. If setup is missing or inconsistent, stop and ask the user to repair it with
   `intelligence init`; then use `/intelligence-learn-from-repository`. Do not
   reproduce CLI mechanics.
3. If the generated header says onboarding is pending, or preserved legacy
   evidence still has unresolved instructions, stop and route to
   `/intelligence-learn-from-repository`. A retained
   `<content-dir>/_backup/manifest.tsv` or converted legacy config alone does
   not mean onboarding is incomplete; those may remain as intentionally kept
   evidence after the transitional header and conflicts are resolved.

## Principle: positive framing

LLMs follow whatever is named. Negation ("never do X") often draws attention to X. Positive framing ("default to Y", "prefer Y") steers behavior more cleanly.

This skill translates user-stated lessons before encoding:
- "Don't use NOT-comparison structures" → "State positively what IS"
- "Stop generating 3 options" → "Default to one strong recommendation"
- "Never push toward architecture framing" → "Reflect the user's framing in their own words first"

The original negative pattern stays in the rule body as an illustrative example (paired with positive replacement), but the LLM-facing instruction is positive.

## Phase A — Analyze (read-only)

1. **Read authoring conventions first.** The paths below are localized to this project at sync time: `<content-dir>/` is the project content directory, `<module>/` the installed sync package, and `<manifest>` the root manifest. The meta-skills live in `<module>/skills/`, not directly under the content directory. Load `<module>/skills/intelligence-add-rule/SKILL.md`, `<module>/skills/intelligence-add-skill/SKILL.md`, `<module>/skills/intelligence-add-agent/SKILL.md`, and `<module>/references/conventions.md` (Authoring Discipline section). This skill writes nothing on its own — it delegates to the add-* skills, which carry the authoring conventions.

2. **Capture the lesson** from session context or user input. Strip session-specific detail, keep the underlying pattern.

3. **Translate to positive form**:
   - "Never do X" → "Default to Y"
   - "Stop doing Y" → "Do Z instead"
   - Already-positive lessons keep as-is.
   Confirm the translation with the user if removing the negation changes meaning.

4. **Route to the right artifact type**:
   - Behavioral preference, tone, communication style → **rule** (`<content-dir>/rules/<name>.md`)
   - Multi-step repeatable workflow → use `intelligence-extract-skill` instead
   - Knowledge scope / persona / expertise area → **agent**
   - Project-specific context tied to a path → scoped rule with `paths:` frontmatter

5. **Check for an existing artifact to extend**: list the target directory and read titles. When the lesson fits an existing artifact's scope, propose `UPDATE` rather than `CREATE`. Artifact proliferation costs context space.

6. **Output the proposal list** — one entry per change, each with:
   - Action: `CREATE` / `UPDATE` / `ARCHIVE`
   - Target file path
   - Brief draft of the change (positive framing applied)
   - One-line reasoning

   **No files are written in this phase.**

## User approval gate

Present the proposal list to the user. User accepts or rejects per item. Only accepted items move to Phase B.

## Phase B — Apply (after approval)

7. For each accepted item, delegate to the appropriate add-* skill or edit directly:
   - `CREATE` rule → call `intelligence-add-rule`
   - `CREATE` skill → call `intelligence-add-skill`
   - `CREATE` agent → call `intelligence-add-agent`
   - `UPDATE` existing artifact → edit the file directly, applying the proposed change
   - `ARCHIVE` → move to `<content-dir>/_archive/` and update cross-references that point at it

8. Run `intelligence sync` once all accepted items are applied. Require
   `IS_STATUS=ok`, then run `intelligence status --check`.

## Related skills

- `intelligence-learn-from-repository` — first-run onboarding and legacy instruction migration; use it before this skill
- `intelligence-extract-skill` — when the lesson is a multi-step workflow to be made reusable
- `intelligence-review-skills` — broader audit across existing intelligence/ artifacts
- `intelligence-add-rule`, `intelligence-add-skill`, `intelligence-add-agent` — each authors one artifact; Phase B delegates to them
