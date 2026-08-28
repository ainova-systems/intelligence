---
name: intelligence-learn-from-repository
description: "Recover and complete first-time Intelligence repository onboarding"
---

# Learn from Repository

Use once after `intelligence init` creates or converts a project. This is the
only skill that owns initial backup migration, interrupted-setup recovery, and
the first repository-specific Intelligence layer. The CLI owns deterministic
mechanics; this skill supplies repository judgement.

## Recover or verify setup

1. Locate `<manifest>`, `<content-dir>`, and `<module>`. If first sync failed
   before the slash command was installed, these instructions can be opened
   directly from
   `.intelligence/packages/@ainova-systems/sync/skills/intelligence-learn-from-repository/SKILL.md`.
2. Inspect `<content-dir>/_backup/manifest.tsv`. A
   `state<TAB>initial-onboarding` record identifies the byte-preserved state
   from before Intelligence first wrote adapter output. Read every `path`
   record and treat it as migration input, never generated output. A
   `.intelligence/backup/config.yaml` file identifies a converted legacy
   Intelligence Sync project; use the converted sources and that config as
   migration evidence.
3. Run `intelligence status --check`. If the project is missing, inconsistent,
   or its first sync failed, run `intelligence init --preview`, show the exact
   repair plan, and request approval. After approval run
   `intelligence init --apply`. Do not reproduce manifest, package, adapter,
   backup, or ignore-file mechanics manually.
4. Run `intelligence sync`. Sync is transactional: a failure restores every
   adapter-owned path. Resolve the reported cause and retry. Do not begin
   semantic migration until `IS_STATUS=ok` and `intelligence status --check`
   is clean.

## Analyze repository evidence

5. Read `<manifest>` and resolve the configured source directories. Load
   `<module>/references/conventions.md` and the bundled
   `intelligence-add-rule`, `intelligence-add-skill`, and
   `intelligence-add-agent` skills before proposing authored content. When
   preserved or legacy instructions exist, also read
   `<module>/references/onboarding-migration.md` and use its inventory,
   reverse-mapping, packaging-safety, and stale-reference procedures.
6. Inspect the README and contributor instructions, language and package
   manifests, build and test entry points, source layout, CI, existing agent
   instructions, and project-owned rules, agents, and skills. Detect
   submodules and treat them as separate repositories unless the user includes
   them. Treat documentation as a claim and verify important behavior in code
   or executable configuration.
7. Inventory what initialization preserved or installed. Compare project-owned
   rules, agents, and skills with every configured package source. Do not
   recreate package-owned content, duplicate existing instructions, or convert
   generated target output into source content. When a project artifact is
   materially covered by package content, propose `REMOVE` or a smaller
   `UPDATE`; require a content comparison, not merely a matching name.

   Treat committed legacy root instructions such as `.cursorrules` and an
   instruction-bearing `CLAUDE.md` as migration sources, not permanent parallel
   entry points. Propose moving still-valid guidance into project-owned rules
   and removing the legacy file after generated output is verified. Keep one
   only for genuinely local, gitignored configuration an adapter cannot
   represent. `AGENTS.md` remains the shared root instruction entry point.

   Review `.gitignore` and every existing `.vscodeignore`, `.npmignore`, and
   `.dockerignore` against the CLI-managed policy. Detect tracked files which
   still bypass newly added Git ignore rules. Treat missing managed patterns as
   setup corrections, preserve unrelated entries, and verify actual package or
   build contents before release.
8. Propose the smallest useful project-owned layer. Prefer updating an existing
   artifact over creating a sibling. Each proposal states:
   - `CREATE`, `UPDATE`, `REMOVE`, or `KEEP`;
   - the source path;
   - repository evidence;
   - the concise content or responsibility it adds.

   When `targets.agents.header` is absent or generic, also propose a concise
   manifest header with the project name, verified stack summary, and link to
   its canonical context rule. Keep it to 3-5 lines. Replacing any
   `onboarding is pending` backup pointer is part of completion.

Analysis is read-only. Present the proposal and request approval per change. It
is valid to recommend no authored artifacts when the repository already
explains itself well.

## Apply after approval

9. Apply only accepted proposals. Delegate new artifacts to
   `intelligence-add-rule`, `intelligence-add-skill`, or
   `intelligence-add-agent`; update an existing project-owned artifact directly
   when smaller, and edit an accepted manifest header directly. Never edit
   installed package content or generated tool output.
10. Run `intelligence sync`, then `intelligence status --check`. Inspect the
    relevant generated `AGENTS.md`, Cursor rules, Claude rules, and any
    packaging/build file list affected by ignore policy. Only then remove each
    separately approved legacy root instruction file and rerun the consistency
    check. Completion requires `IS_STATUS=ok`, a clean final check, and no
    `onboarding is pending` header after accepted migration.
11. Report what was created, updated, removed, or deliberately kept. Remind the
    user to commit source, manifest, lock, `AGENTS.md`, and shared `.github/`
    changes. Keep or remove the initial backup only by separate user approval.

## Later learning

After onboarding is complete, use `/intelligence-learn-from-context` to capture
a durable lesson from a working session. It does not repeat repository
onboarding.
