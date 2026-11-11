# 0033 — Keep the Claude Code plugin quiet about an older CLI

Date: 2026-11-11
Status: accepted

## Context

Decision 0022 point 4 made the plugin's line above the prompt ask for
`intelligence upgrade`, in red, whenever the CLI on `PATH` was older than the
project, and withhold the sync, reasoning that such a CLI would drop the
plugin. The CLI itself treats a project stamped a newer minor or patch as
ordinary work (decision 0005): it syncs behind one `WARNING:` line and leaves
the project's stamp as found. A teammate who ran `intelligence update` on a
newer CLI therefore put a red line in front of everyone else on the project for
as long as they kept their CLI, while their own `intelligence sync` kept
working. When to upgrade is each developer's call, and the warning the CLI
prints on every sync already tells them.

The reasoning about dropping the plugin does not hold either. The plugin lives
in `.claude/skills/intelligence/`, which Git ignores, so the CLI on this
machine rendered it, and that CLI renders it again on its next sync.

The line also read as a log prefix (`intelligence: sync needed`), with the
product name in lower case and every state but one colored.

## Decision

1. A CLI behind the project is said once a session, in a toast naming
   `intelligence upgrade`, never as a line above the prompt or in the status
   line.
2. Behind by a minor or patch, the plugin keeps the CLI's verdict: the line
   shows a needed sync and offers `Sync now`, as when the versions match.
   Behind by a major, which the CLI refuses, there is no verdict to show:
   the plugin draws nothing, offers no sync, and `/intelligence` says why.
3. The line is one sentence that names the product, `Intelligence needs a
   sync`, `Checking Intelligence…`, `Intelligence check failed`, drawn in the
   default colors: dim while a check or a sync is pending and for a missing
   CLI, which the person cannot fix from the line. A failed check points to
   `/intelligence`, which prints the reason.
4. `cli/tests/plugin-hooks.mjs` drives the hooks module against a fake host
   in the plugin gate, wherever node runs it.

## Consequences

- A developer on an older CLI sees the same line as everyone else, plus one
  toast a session, and decides when to upgrade.
- A sync from the line on an older CLI renders with that CLI's engine, as an
  `intelligence sync` from their terminal does.
- The plugin's behavior is tested on CI, where node is installed and Claude
  Code is not.

## Rejected

- **A dim line for an older CLI instead of a toast.** It still stays in front
  of the prompt for as long as the person keeps that CLI, which is the nagging
  this decision removes.
- **Saying nothing at all.** The CLI's warning reaches only a person who runs
  sync in a terminal; a person who syncs only from the plugin would never learn
  that their CLI is behind.
- **Keeping red for a failed check.** The line is the person's to act on when
  it suits them; `/intelligence` carries the reason, and the line names it.
