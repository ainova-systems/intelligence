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
2. Read `<manifest>` and resolve `<content-dir>` and the configured source
   directories. Load `<module>/references/conventions.md` and the bundled
   `intelligence-add-rule`, `intelligence-add-skill`, and
   `intelligence-add-agent` skills before proposing authored content.
3. Inspect repository evidence: its README and contributor instructions,
   language and package manifests, build and test entry points, source layout,
   CI, existing agent instructions, and existing project-owned rules, agents,
   and skills. Treat documentation as a claim and verify important behavior in
   code or executable configuration.
4. Inventory what initialization already preserved or installed. Do not
   recreate package-owned content, duplicate existing instructions, or convert
   generated target output into source content.
5. Propose the smallest useful project-owned layer. Prefer updating an existing
   artifact over creating a sibling. Each proposal must state:
   - `CREATE`, `UPDATE`, or `KEEP`;
   - the source path;
   - the repository evidence supporting it;
   - the concise content or responsibility it would add.

Analysis is read-only. Present the proposal and request approval per change.
It is valid to recommend no new artifacts when the repository already explains
itself well.

## Apply after approval

6. Apply only accepted proposals. Delegate new artifacts to
   `intelligence-add-rule`, `intelligence-add-skill`, or
   `intelligence-add-agent`; update an existing project-owned artifact directly
   when that is the smaller change. Never edit installed package content or
   generated tool output.
7. Run `intelligence sync`, then `intelligence status --check`. Completion
   requires `IS_STATUS=ok` and a clean consistency check.
8. Report what was created, updated, or deliberately left unchanged. Remind the
   user to review and commit generated and source changes according to project
   policy.

## Related skill

Use `intelligence-learn-from-context` later to preserve a lesson learned during
a working session. This skill learns the repository's existing structure and
workflow during onboarding.
