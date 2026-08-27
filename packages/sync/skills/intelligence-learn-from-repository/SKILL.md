---
name: intelligence-learn-from-repository
description: "Tailor Intelligence to an initialized repository"
---

# Learn from Repository

Use after `intelligence init` creates or converts a project. The CLI owns the
mechanical setup; this skill adds only repository-specific judgement.

## Analyze

1. Run `intelligence status --check`. If setup is missing or incomplete, stop
   and ask the user to run `intelligence init`; do not reproduce CLI mechanics.
   A clean check proves only that the mechanical setup is healthy; do not call
   repository onboarding complete while legacy instruction migration or other
   proposed tailoring still awaits approval.
2. Read `<manifest>` and resolve `<content-dir>` and the configured source
   directories. Load `<module>/references/conventions.md` and the bundled
   `intelligence-add-rule`, `intelligence-add-skill`, and
   `intelligence-add-agent` skills before proposing authored content.
   When existing AI instructions, `<content-dir>/_backup/`, or overwritten
   tracked tool output is present, also read
   `<module>/references/onboarding-migration.md` and use its inventory,
   reverse-mapping, and stale-reference procedure.
   When `<content-dir>/_backup/manifest.tsv` declares
   `state<TAB>initial-onboarding`, treat each `path` record as the exact
   pre-Intelligence state. Never infer that files beside the backup are the
   originals after sync.
3. Inspect repository evidence: its README and contributor instructions,
   language and package manifests, build and test entry points, source layout,
   CI, existing agent instructions, and existing project-owned rules, agents,
   and skills. Detect submodules and treat them as separate repositories unless
   the user explicitly includes them. Treat documentation as a claim and
   verify important behavior in code or executable configuration.
4. Inventory what initialization preserved or installed. Do not
   recreate package-owned content, duplicate existing instructions, or convert
   current generated target output into source content. Treat committed legacy root
   instruction files such as `.cursorrules` and instruction-bearing `CLAUDE.md`
   as migration sources, not permanent parallel entry points: propose moving
   still-valid guidance into project-owned rules and removing the legacy file
   after the generated output is verified. Keep one only for genuinely local,
   gitignored configuration that an adapter cannot represent. `AGENTS.md`
   remains the only shared root instruction entry point.
   Review `.gitignore` against the enabled adapters and the generated-output
   ownership table in the conventions. Treat missing CLI-managed patterns as a
   setup correction, not as a new repository convention; preserve shared
   settings and never ignore `.github/` or `AGENTS.md`.
5. Propose the smallest useful project-owned layer. Prefer updating an existing
   artifact over creating a sibling. Each proposal must state:
   - `CREATE`, `UPDATE`, `REMOVE`, or `KEEP`;
   - the source path;
   - the repository evidence supporting it;
   - the concise content or responsibility it would add.
   When `targets.agents.header` is absent or generic, also propose a concise
   manifest header with the project name, verified stack summary, and a link to
   its canonical context rule. Keep it to 3-5 lines.
   When the header says Intelligence onboarding is pending, replacing that
   transitional backup pointer is part of the proposal; do not leave it after
   the original `AGENTS.md` guidance has been migrated and verified.

Analysis is read-only. Present the proposal and request approval per change.
It is valid to recommend no new artifacts when the repository already explains
itself well.

## Apply after approval

6. Apply only accepted proposals. Delegate new artifacts to
   `intelligence-add-rule`, `intelligence-add-skill`, or
   `intelligence-add-agent`; update an existing project-owned artifact directly
   when that is the smaller change, and edit an accepted manifest header
   directly. Never edit installed package content or generated tool output.
7. Run `intelligence sync`, then `intelligence status --check`. Inspect the
   relevant generated `AGENTS.md`, Cursor rules, and Claude rules to verify that
   the migrated guidance reached each enabled target. Only then remove each
   separately approved legacy root instruction file and rerun the consistency
   check. Completion requires `IS_STATUS=ok`, a clean final check, and no
   `onboarding is pending` header after migrated guidance is accepted.
8. Report what was created, updated, or deliberately left unchanged. Remind the
   user to commit source, manifest, lock, `AGENTS.md`, and shared `.github/`
   changes; generated local adapter output should match the reviewed ignore
   policy.

## Related skill

Use `intelligence-learn-from-context` later to preserve a lesson learned during
a working session. This skill learns the repository's existing structure and
workflow during onboarding.
