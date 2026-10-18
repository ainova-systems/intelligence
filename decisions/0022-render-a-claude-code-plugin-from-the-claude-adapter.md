# 0022 — Render a Claude Code plugin from the Claude adapter

Date: 2026-10-18
Status: accepted

## Context

Generated output goes stale the moment a source changes, and nothing in Claude
Code says so: a developer edits a rule, keeps working, and the session reads
yesterday's `.claude/rules/`. `intelligence sync --check` (decision 0018)
answers the question in one line and one exit code, but only when someone runs
it.

Claude Code 2.1.287 turned on *mods*: a plugin whose `hooks/hooks.json` names a
JavaScript hooks module that Claude Code loads in-process. A mod registers
hooks on events (`session.start`, `command.run`, `ui.render`) and acts through
the mods API `$`: it can run a process, draw a status line under the prompt and
a band above it with buttons, register a slash command and run work on a timer.
It has no Node.js APIs and no network or file access of its own. Earlier
versions load a mod only with `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1`
([create](https://code.claude.com/docs/en/plugins/mods/create),
[reference](https://code.claude.com/docs/en/plugins/mods/reference), read
2026-10-18).

Where a plugin can live decides who has to install it. Claude Code loads
plugins from marketplaces, from `--plugin-dir` and `CLAUDE_CODE_PLUGIN_DIRS`,
and from a project's skills directory, `.claude/skills/<plugin>/` with a
`.claude-plugin/plugin.json` inside — the "skills-dir" plugin the debug log
names `<plugin>@skills-dir`. It does not scan `.claude/plugins/`. A marketplace
needs publishing, a registration in `extraKnownMarketplaces` and an install per
user; the environment forms need every developer to set a variable. The skills
directory is one the Claude adapter already owns and rewrites on every sync.

The mod's job is to call the CLI; it is tooling, not content. `packages/sync/`
ships to consuming projects as rules, agents and skills, and an engine script
must never reach into it (decision 0001).

## Decision

1. `targets.claude.plugin: true` renders a Claude Code plugin into
   `<output>/skills/intelligence/`: `.claude-plugin/plugin.json` (name
   `intelligence`, `version` = `engine/VERSION`), `hooks/hooks.json` naming
   `./register.js`, the hooks module and a README that says the directory is
   generated. The field takes `true` or `false`; omission or an empty value is
   `false`, and any other value refuses the sync before anything is removed,
   naming the field.
2. The template lives in the engine, `engine/adapters/claude-plugin/`, beside
   the adapter that renders it, and is copied byte for byte except for the
   version stamp and LF normalization. `npm/build.sh` already bundles all of
   `engine/`.
3. The plugin lives inside `<output>/skills`, which the Claude contract owns.
   Ownership, Git policy (`.claude/*` ignored), snapshots and rollback,
   `sync --check` and `status --check` therefore apply unchanged, and the
   directory disappears with the next sync after the flag goes. A source skill
   whose rendered name is `intelligence` in any letter case collides with the
   plugin while the flag is on; sync refuses it, naming the skill's source path
   and the flag.
4. The mod informs the person and never Claude. At `session.start` it runs
   `intelligence sync --check` in the session root without waiting for it,
   repeats every five minutes, and registers `/intelligence [sync|check]`. It
   shows the verdict in the status line under the prompt and, when a sync is
   needed, failed or running, a band above the prompt; only a needed sync adds
   a `Sync now` button to it.
   Sync runs `intelligence sync --compact` with a ten-minute timeout and
   re-checks. It registers no tool and never submits a prompt.
5. The runner gains one gate for the template: `node --check` on the hooks
   module and `claude plugin validate` on the directory. Each is printed as
   skipped when its tool is absent, never as passed. CI's `lint-engine` scope
   carries it; no workflow step is added.
6. A command waits for a check instead of refusing it. `sync --check` holds
   the project lock (decision 0018) for as long as it runs, which is minutes
   on Git Bash, and the lock refused every second command at once. A status
   check that runs every five minutes would then make a person's own
   `intelligence sync`, `update` or package command fail whenever the two met.
   The check writes nothing a person keeps, so it marks its lock with a
   `kind` file, and a writing command that finds a check holding the lock
   waits for it, up to five minutes for each check, saying so. A check never
   waits: it refuses any holder at once, so it cannot queue ahead of a waiting
   writer, and the mod shows that as another command running. A writing
   holder is still refused at once, so the one-writer guarantee is unchanged. The mod's own sync first waits for a check it started.

## Consequences

- A project opts in with one manifest line and a sync; every developer with
  Claude Code 2.1.287 or later gets the status without installing anything.
  The plugin needs the `intelligence` CLI on `PATH`; without it the status
  line says so.
- A project-level plugin loads only in a trusted folder, and a cloud or
  remote session that does not load project plugins shows nothing. A cold
  `sync --check` renders the project in a private copy, which takes minutes on
  Git Bash; the mod waits for it up to just under the interval and never
  starts a check while one of its own is pending; a check abandoned at that
  timeout can still finish beside the next one. When another command holds the lock, the check yields and the
  status line says another command is running until the next tick.
- A command started while a check runs now pauses for it instead of failing
  at once. An older CLI does not write the mark, so its checks are still
  refused by every other command, as before.
- The plugin's `version` moves with `engine/VERSION`, so a release renders a
  new plugin without any change to the template.
- The engine now ships a JavaScript file. Nothing in the engine executes it;
  Claude Code does.

## Rejected

- **A marketplace plugin.** It needs publishing, an `extraKnownMarketplaces`
  entry and an install per developer, and its copy of the mod would drift
  from the CLI that renders the project.
- **`.claude/plugins/` or `CLAUDE_CODE_PLUGIN_DIRS`.** Claude Code does not
  scan the former; the latter is a per-user environment setting no sync can
  write.
- **Keeping the template in `packages/sync/`.** The hooks module is executable
  tooling, and an engine script reading the content package is the coupling
  decision 0001 removed.
- **A configurable interval or a `userConfig` dialog.** Neither has a user
  yet; the first keeps the mod one file with no settings to explain.
- **Rendering the plugin by default.** A mod runs code in every session; a
  project chooses that.
