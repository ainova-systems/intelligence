# 0021 — Local and targeted source artifacts

Date: 2026-10-11
Status: accepted

## Context

Every rule, agent and skill in a configured source renders to every enabled
adapter. Nothing in a source can say "only on my machine" or "only for this
tool".

A machine-local preference has no place. The documented home is a hand-made,
gitignored root `CLAUDE.md`, which reaches one tool. A gitignored file placed in
a source directory leaks instead: `AGENTS.md`, committed by default (decision
0020), inlines an always-on rule's body and links every rule, agent and skill.
A teammate without the file renders `AGENTS.md` without it, and `sync --check`
in CI reports `out-of-date` for the same reason.

Tool-specific guidance has no place either: advice that matters to one tool
reaches all of them, and an always-on rule costs context in every one.

Two delivery paths are shared, not per tool. Codex, Cursor, Copilot,
Antigravity, Pi and OpenCode read `AGENTS.md` natively; Claude Code does not,
and receives every rule in `.claude/rules/`. Codex, Antigravity, Pi and OpenCode
read `.agents/skills/`. A filter can withhold an artifact from a shared path,
never from one of its readers.

Sources are enumerated two ways. `AGENTS.md` uses `find`, which returns
dotfiles; every other adapter uses a shell glob, which skips them, so a `.x.md`
rule reaches `AGENTS.md` and nothing else. `AGENTS.md` also lists and inlines
every same-named rule from every source, while the copying adapters let the
later source win.

## Decision

1. **Local is a name.** A rule or agent file named `*.local.md` and a skill
   directory named `*.local/` are local. That is the pattern `.gitignore`
   holds, so Git and the engine cannot disagree about which file is local:
   `init` writes `<content-dir>/rules/*.local.md`,
   `<content-dir>/agents/*.local.md` and `<content-dir>/skills/*.local/` to the
   managed block, beside `.intelligence/`. A pattern never applies to a file
   Git already tracks, and a source outside the content directory has none, so
   `status --check` names every tracked file with a local name in a
   project-owned source.
2. **A name is the file name without a leading `.`, `.md` and a trailing
   `.local`.** `.environment.local.md` and `environment.local.md` are the local
   rule `environment`; `.local.md` is the local rule `local`; `.draft.md` is the
   rule `draft`. A leading dot means nothing, so every adapter renders dotfile
   sources, as `AGENTS.md` already did. A skill directory `deploy.local/`
   renders as `deploy/`, so it still matches its own `name: deploy`.
3. **Names stay unique.** Across sources the later source overrides the
   earlier, as today, and now in `AGENTS.md` too. Sync refuses two artifacts
   with one name in one source directory (`x.md` beside `.x.md`), and a local
   and a non-local artifact with one name in any sources: a local file that
   overrides or yields to a committed one would change what committed output
   holds.
4. **Two frontmatter fields select adapters.** `targets:` lists the adapters an
   artifact is for; without it, every enabled adapter. `exclude_targets:`
   removes adapters from that set. Both take built-in or project adapter ids and
   the group `committed`, in the list syntax `paths:` accepts; skills carry them
   in `SKILL.md`. An unknown id refuses the sync. A known adapter that is not
   enabled is no target and no warning: enablement is the manifest's decision.
   `targets: []` renders the artifact nowhere. Both fields are removed from
   every rendered copy.
5. **`committed` is every output Git tracks**: an output path that no `ignore`
   record of its adapter's contract covers. It is resolved per path, not per
   adapter — OpenCode's agents are ignored while its commands are tracked —
   and `AGENTS.md` always belongs to it. `targets.copilot.commit_output: true`
   moves Copilot's four directories into it, so a sync that resolves
   `committed` evaluates contracts with the manifest. Decision 0020 kept that
   read off every sync; a sync whose sources have no local artifact and name no
   `committed` still has none.
6. **A local artifact excludes `committed` implicitly.** Its own `targets` and
   `exclude_targets` narrow the set further. A local artifact whose `targets`
   names a committed output refuses the sync: the source exists in no other
   clone and not in CI, which render that output without it.
7. **Shared paths are delivered whole.** An artifact whose set contains
   `agents` goes into `AGENTS.md`, and so reaches every tool that reads it,
   listed or not. An always-on rule whose set leaves `agents` out reaches a tool
   in its set through that tool's own channel:
   - Claude Code: `.claude/rules/`, as today;
   - Cursor: an `.mdc` file with `alwaysApply: true`;
   - Copilot: an `.instructions.md` file with `applyTo: "**"`;
   - Antigravity: `trigger: always_on`, the same Windsurf-lineage key family as
     its `trigger: glob`, not vendor-documented;
   - Pi: its generated rules extension, which adds the rule to the system
     prompt;
   - Codex: `AGENTS.override.md` beside `AGENTS.md`. Codex reads it instead of
     `AGENTS.md` in that directory, so it holds the `AGENTS.md` content plus the
     rules only Codex receives; Codex's contract ignores it, and it exists only
     while such rules do;
   - OpenCode: none — its `instructions:` live in a committed `opencode.json`.

   A skill whose set contains any reader of `.agents/skills/` lands there. Sync
   warns when a shared path delivers an artifact to an enabled adapter outside
   its set, and when an adapter in its set can receive it through no channel —
   for the adapters an artifact names explicitly and for a local artifact's
   implicit set. An artifact with neither field nor a `.local` name keeps
   today's routing and warnings.
8. **One enumeration.** `AGENTS.md`, every built-in adapter and the adapter
   template read sources through one function that applies the name rule,
   overrides, locality and the target set; the per-adapter globs go.
9. The work lands in one pull request, in two stages of commits: local
   artifacts with `committed` and the single enumeration first (items 1–3, 5,
   6, 8), then the fields, the new always-on channels and the shared-path
   warnings (items 4 and 7).

## Consequences

- A personal rule, agent or skill is a `*.local.md` file or `*.local/`
  directory in the content directory. It reaches every tool whose output is
  ignored and never changes a committed file. Tests hold that invariant:
  `AGENTS.md` is byte-identical with and without local artifacts, and
  `sync --check` passes in a clone that has none.
- With one enumeration, dotfile sources render in every adapter, and
  `AGENTS.md` applies source overrides. A project with a dotfile source sees
  new output in tool channels.
- Same-named artifacts in one directory, and local/non-local pairs, now refuse
  a sync that rendered before.
- Cursor, Copilot, Antigravity and Pi gain an always-on channel and Codex an
  override file; a project that never targets or localizes a rule never gets
  one. OpenCode can receive neither a local nor a tool-targeted always-on rule.
- A project adapter that enumerates sources itself bypasses locality and
  targets, so a committed output it writes can leak a local artifact. The
  template and the adapter guide point it at the shared function.

## Rejected

- **A `local: true` field.** It makes locality and the ignore pattern two facts
  that can disagree: a flagged file that is committed is shared anyway, and an
  ignored file without the flag leaks into `AGENTS.md`.
- **Detecting local files with `git check-ignore`.** It costs a process per
  sync, has no answer outside a Git work tree, and makes rendering depend on
  `.gitignore` contents instead of a visible name.
- **Target lists in `intelligence.yaml`.** Who an artifact is for is a property
  of the artifact; a manifest list is a second source that drifts from it. The
  list parser also reads a `rules:` key two spaces deep under any parent as a
  source list.
- **`exclude:` as the field name.** Beside `paths:` it reads as a path
  exclusion.
- **Negation inside `targets` (`!agents`).** Unquoted, `!agents` is a YAML tag,
  not a string.
- **Letting a local artifact name a committed output.** Every other clone and CI
  render that output without it, so it flips on each teammate's sync and fails
  `sync --check`.
- **Skipping dotfiles everywhere.** It gives a leading dot a meaning — "hidden"
  — that `targets: []` states in the file, and it would drop
  `.environment.local.md` silently.
- **Special-casing `.local.md`.** The name rule already yields `local`.
