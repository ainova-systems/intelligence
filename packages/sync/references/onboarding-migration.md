# Migrating Existing AI Instructions

Read this reference only when repository onboarding finds pre-existing AI
instructions, an `<content-dir>/_backup/` created by `intelligence init`, or a
Git diff showing that the first sync replaced tracked tool output.

## Inventory and recovery

When `<content-dir>/_backup/manifest.tsv` contains
`state<TAB>initial-onboarding`, it is the authoritative inventory from before
the first generated write. Read each `target` and `path` record before looking
at current adapter output. If `path<TAB>AGENTS.md` is present, the backed-up
file is the original custom project contract; keep following it while deciding
how to migrate its durable guidance.

Treat these as migration inputs, not as current generated output:

- root `AGENTS.md`, `CLAUDE.md`, `.cursorrules`, and
  `.github/copilot-instructions.md`;
- Claude and Cursor rules, agents, skills, and commands;
- Copilot instructions, prompts, agents, and skills;
- Codex/Open Agent Skills, Pi rules/prompts, and OpenCode agents/commands;
- scripts or documentation that describe an older sync path.

Prefer the copy under `<content-dir>/_backup/`. If it is absent and the first
sync changed tracked files, inspect their pre-sync content read-only through
Git (`git diff` and `git show HEAD:<path>`). Never restore old content directly
into an adapter output directory.

Build one conflict report before proposing changes:

- `MIGRATE`: instruction-bearing files whose useful content needs a
  project-owned destination;
- `PRESERVE`: settings and unrelated shared files the adapters do not own;
- `REPLACE`: adapter-owned paths that sync regenerates;
- `STALE`: references to removed paths or commands requiring a decision.

Always preserve `.claude/settings.json`, `.claude/settings.local.json`,
`.cursor/settings.json`, Git metadata, workflows, and non-AI repository files.

## Reverse mappings

Migrate meaning, not tool syntax:

| Existing format | Project-owned destination |
|---|---|
| Root `AGENTS.md`, `CLAUDE.md`, `.cursorrules`, Copilot root instructions | Split verified guidance by topic into rules; keep local machine preferences in a gitignored root file only when no adapter representation exists |
| `.claude/rules/*.md` | Rule; preserve valid `paths:` |
| `.cursor/rules/*.mdc` | Rule; rename `globs:` to `paths:` and remove `alwaysApply:` |
| Claude/Cursor/Copilot agents | Agent; map native model/readonly/tool fields back to `tier:` and `access:` |
| Claude/Cursor/Copilot skills or commands | Skill when the procedure is repeated, multi-step, stable, and verifiable; otherwise a rule or no artifact |
| Pi/OpenCode/Codex prompt artifacts | Rule, agent, or skill according to responsibility, after removing tool-specific wrappers |

Verify every retained claim against repository code or executable
configuration. Do not preserve stale instructions merely because they existed.
Prefer updating an existing project-owned artifact to creating a sibling.

## Apply and cleanup

Obtain approval per `CREATE`, `UPDATE`, `REMOVE`, or `KEEP` proposal. Apply
project-owned source changes first, then run `intelligence sync` and
`intelligence status --check`. Inspect the enabled targets to prove the
migrated guidance arrived before removing old root instructions or tool files.

For every removed or renamed path, search all tracked files with `git ls-files`
and report remaining references with file and line number. Apply an unambiguous
replacement directly; ask about narrative or otherwise ambiguous references.

The CLI owns generated-output `.gitignore` entries. Verify its patterns against
the enabled adapters and preserve `AGENTS.md`, `.github/`, shared settings, and
unrelated files under shared tool roots.

Keep `<content-dir>/_backup/` until the user separately approves its removal
after migration and reference checks pass. The backup remains gitignored.
