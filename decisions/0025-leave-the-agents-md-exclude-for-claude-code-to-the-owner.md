# 0025 – Leave the AGENTS.md exclude for Claude Code to the owner

Date: 2026-11-07
Status: accepted

## Context

Claude Code 2.1.277 and later reads `AGENTS.md` as project instructions when no
`CLAUDE.md`, `.claude/CLAUDE.md` or `CLAUDE.local.md` exists in the working
directory or above it, and keeps loading `.claude/rules/` beside it
([memory docs](https://code.claude.com/docs/en/memory#agents-md), checked
2026-11-07). Decision 0021 and the routing reference said it does not. An
Intelligence project usually has none of those three files, because `init`
ignores a root `CLAUDE.md` and onboarding moves its guidance into rules. With the
`claude` and `agents` targets both enabled, every always-on rule then loads twice,
from `.claude/rules/` and inlined in `AGENTS.md`, together with the agent and
skill tables. In one installed project that was about 13 KB in every session.

Two settings decide what loads. `claudeMdExcludes` skips files by glob, matched
against absolute paths, at the user, project, local or managed layer, with the
arrays merged across layers, and its patterns apply to `AGENTS.md`. The
**Project instructions** value, which can limit Claude Code to `CLAUDE.md`, is
read from user settings, a `--settings` file or managed settings and ignored in
project and local settings files, so a project cannot set it.

The Claude adapter's contract preserves `.claude/settings.json`, and the managed
`.gitignore` block keeps that file tracked.

## Decision

1. The project owner adds `"claudeMdExcludes": ["**/AGENTS.md"]` to the committed
   `.claude/settings.json`. Sync, `init` and the adapter never write that file.
2. `status --check` prints a note with the entry when both targets are enabled,
   the agents output is an `AGENTS.md` Claude Code reads, none of the three
   `CLAUDE.md` files exists, and no `claudeMdExcludes` entry in
   `.claude/settings.json` or `.claude/settings.local.json` matches it. It is a
   note and leaves the exit status alone, because the check cannot see the
   Claude Code version, the user's settings or the **Project instructions** value.
3. A package skill that meets a settings change in a check note shows it to the
   owner as the owner's step, with the exact JSON, and leaves the file alone.

## Consequences

- A project that enables both targets has one owner step, printed with the JSON
  to paste.
- `**/AGENTS.md` also hides any other `AGENTS.md` Claude Code would read in a
  parent or nested directory. A nested agents output is printed with its
  repository-relative path instead.
- The note stays on a machine whose user settings already exclude the file,
  which is one reason it is a note.
- Nobody has yet confirmed in a fresh session that the entry stops the load; the
  memory docs are the only source.

## Rejected

- **A generated `.claude/CLAUDE.md`.** It suppresses `AGENTS.md` only under the
  default **Project instructions** value; under `claude-md-and-agents-md`, set in
  user settings, Claude Code reads both. `.claude/CLAUDE.md` is also a documented
  place for hand-written project instructions, which the adapter would then own.
- **The adapter merging the key into `settings.json`.** It breaks the preserve
  contract that keeps shared settings in the owner's hands.
- **`init` adding the key when it creates the file.** `init` never creates
  `.claude/settings.json`.
- **A problem that fails the check.** Every project with both targets would fail
  CI on state the check cannot read.
