# 0020 — Ignore generated Copilot output

Date: 2026-10-07
Status: accepted

## Context

Every built-in adapter declares its Git policy in its contract. Cursor and
Claude Code ignore their generated output; Antigravity, Codex, Pi and OpenCode
ignore their generated subdirectories. Copilot declared none, so the scoped
instructions, agents and skills it renders under `.github/` were committed in
every project that enabled it.

Nothing about Copilot in the editor justified the difference: VS Code reads
those files from disk after sync, exactly as Cursor reads `.cursor/`. Committing
them made every source change a second, generated diff in review, and a stale
committed copy was what a teammate's editor read until they synced.

One reader does need the files in the repository: Copilot on github.com — code
review and the coding agent — reads the repository and never runs a sync.

`.github/` is not Copilot's directory. It holds workflows, issue and pull
request templates and other hand-written files.

`AGENTS.md` is committed by default and stays so: it is the tool-neutral
fallback every tool reads, and a fresh clone has it only if it is committed.

## Decision

1. The Copilot contract ignores the four directories it owns under its output —
   `instructions/`, `prompts/`, `agents/` and `skills/` — and never `.github/`
   itself. Each is owned and rewritten by every sync, so the ignore covers
   generated output only. The legacy root file `copilot-instructions.md`
   follows the same policy, as `CLAUDE.md`, `.cursorrules` and `GEMINI.md` do
   for their tools: onboarding migrates its content into project rules, and a
   copy left behind makes Copilot ignore `AGENTS.md`.
2. `targets.copilot.commit_output: true` keeps them tracked for Copilot on
   github.com. It accepts `true` or `false`; omission is `false`, and sync
   refuses any other value and restores every output it touched.
3. A contract receives the manifest as an optional second argument, for Git
   policy only. Ownership never depends on it, so the engine and the sync cache
   — which read ownership alone — pass none and add no read to a sync; init,
   adapter enable and `status --check` pass it.
4. A new contract record, `unignore`, names an ignore line the policy must not
   hold. The `.gitignore` writer removes it from the block below its header,
   which is how opting in withdraws the lines an earlier init already wrote.
   `status --check` reports such a line until `intelligence init` removes it.
5. An existing project picks the patterns up through `intelligence init`, which
   reapplies every enabled adapter's Git policy and then prints a
   `git rm --cached` command for each generated file Git still tracks. It never
   untracks a file itself. Until then, `status --check` names each missing
   pattern and the command that adds it.

## Consequences

- A Copilot project no longer reviews generated diffs or commits copies that
  drift from their sources; a fresh clone runs `intelligence sync` for Copilot
  output, as it already did for every other tool.
- A project whose cloud Copilot relied on committed output loses it on the
  commit that applies the new patterns unless it opts in. The opt-in is one
  manifest field plus `intelligence init`.
- Contracts may now vary their Git policy with the manifest. A project adapter
  that ignores the second argument is unaffected.

## Rejected

- **Ignoring `.github/` wholesale.** It hides workflows and templates that every
  GitHub repository commits.
- **Keeping Copilot committed by default.** It made Copilot the only adapter
  whose generated output a team had to review, for the benefit of one reader
  that a project can opt into.
- **Filtering Copilot's ignore lines in the CLI.** Git policy belongs to the
  contract; a CLI case statement per adapter is the restated ownership the
  engine rules forbid.
- **Reading the field in every contract evaluation.** The engine evaluates
  contracts on every sync for ownership alone; the extra read would cost each
  sync a process for a value it never uses.
- **Asking the user to delete the lines by hand when opting in.** A hand edit
  has no check behind it; the writer that added the lines removes them.
