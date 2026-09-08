---
name: intelligence-update-context
description: "Create, revise, or remove project rules, agents, and skills"
argument-hint: "[rule|agent|skill] [request or accepted proposals]"
agent: intelligence-architect
---

# Update project context

Own the authoring procedure for rules, agents, and skills. A direct request,
accepted session lesson, repository-onboarding proposal, or review finding enters
the same procedure. Updating the layer can create a new artifact.

## Resolve and draft

1. Read `<manifest>` and resolve its `sources.rules`, `sources.agents`, and
   `sources.skills` directories. `<content-dir>` names the project's content
   directory; `<module>` is installed package content. Read the
   `intelligence-authoring` rule and `<module>/references/conventions.md`.
   Edit project-owned sources, never installed packages or generated output.
   When working in a package's own repository, use its authoritative source tree.

2. Inspect existing artifacts, including configured package sources, for overlap.
   Prefer extending an existing owner, merging duplicates, or enforcing a
   convention mechanically. Resolve the writable directory from the manifest;
   create a pre-listed missing directory without changing the source list. Add a
   source entry only when an accepted destination is outside the listed groups,
   and add it with `intelligence source add <rules|agents|skills> <dir>` rather
   than by editing the manifest: the list is ordered, and its order decides which
   artifact wins.

3. Establish the evidence and artifact type. A constraint is a rule, a repeatable
   procedure is a skill, and a persona or expertise boundary is an agent. Verify
   repository claims in code or executable configuration. An accepted session
   preference is evidence of the user's intent; an observed workflow supplies its
   working steps. Preserve that evidence rather than inventing repository precedent.

4. Reuse the existing domain vocabulary. If none fits, derive it from the project
   name or component: for example `backend`, `frontend`, `devops`, `core`, or
   `tests`. Project artifacts do not use the package-reserved `intelligence-`
   prefix. Resolve an unclear scope before writing. Read only the relevant
   artifact reference, for both new content and changes to existing content:
   - Rule: [references/rules.md](references/rules.md).
   - Agent: [references/agents.md](references/agents.md).
   - Skill: [references/skills.md](references/skills.md).

5. Draft the smallest change with its action, source path, evidence, and reason.
   Supported actions include `CREATE`, `UPDATE`, `REMOVE` (`DELETE` in a review), `ARCHIVE`, `MERGE`,
   `MOVE`, `SCOPE`, `REFERENCE`, and `REWRITE`. Preserve an upstream proposal's
   behavior checklist, approval scope, and verification requirements. Present
   changes to meaning, ownership, scope, or load timing that the user has not
   already authorized. Accepted proposals do not need a second approval round.

## Apply and verify

6. Apply the authorized changes and update every affected invocation, link, and
   agent binding. Archive to the project content directory's `_archive/` when
   requested; remove only the accepted sources. For a move or merge, retain each
   behavior once in its new owner. Preserve unapproved passages byte-for-byte.

7. Check the relevant artifact reference, frontmatter, configured source coverage,
   and all changed cross-references. Confirm the intended triggers, boundaries,
   ordering, failure handling, and verification survived. Run tests for bundled
   helpers or changed executable behavior using the project's verification gate.

8. Run `/intelligence-sync` once after the complete batch, require `IS_STATUS=ok`,
   then run `intelligence status --check`. Verify that each enabled target received
   the intended artifacts and resources and that removed names are absent. When
   called by onboarding, defer this batch's sync to its final migration check so
   the accepted manifest header and content are verified together.

9. Report the created, updated, removed, or archived artifacts and their checks.
   Return control to the originating workflow for its additional semantic,
   compaction, migration, or packaging verification; those checks remain required.
