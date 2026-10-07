# 0017 — Render symlinks that stay inside their source

Date: 2026-10-07
Status: accepted

## Context

A skills source can hold symlinks: a whole skill directory
(`skills/x -> ../../shared/x`), its `SKILL.md`, a bundled resource, or the
`agents/openai.yaml` Codex reads. Only project content and local-path packages
can; packages fetched from Git are checked out with `core.symlinks=false`.

The adapters disagreed about them. Claude, Cursor and Copilot listed skills with
a glob and copied each link verbatim with `cp -R`, so a relative link resolved
in the output only while the output sat at the source's depth, and an absolute
one pointed out of the repository. The shared `.agents/skills` tree, the
`AGENTS.md` skill index and the context report listed skills with
`find -type d`, which skips a linked directory, so Codex, Pi, OpenCode and
Antigravity lost such a skill without a word. A linked `SKILL.md` stayed a
link in every tree, with a warning compact output dropped: no frontmatter
quoting, no layout tokens, no `effort:` rendering, no Codex invocation policy,
so an owner-only skill stayed selectable in Codex. A linked
`agents/openai.yaml` was left unenforced.

Decision [0006](0006-safe-skill-imports-and-adapter-growth.md) already rules
out copying contents from an escaping symlink automatically.

## Decision

1. **A link that stays inside its source renders as what it points at.** A
   symlink in a configured skills source is resolved by physical path. When it
   reaches a regular file or directory inside the same source directory, sync
   renders it exactly like that file or directory, as regular files in every
   skill tree. Everything that runs on a skill runs on that copy: frontmatter
   quoting, layout tokens, each tool's `effort:` level
   ([0015](0015-separate-reasoning-effort-from-the-model-tier.md)), the Codex
   invocation policy, and any transform added later.
2. **Any other link is left out, and said so.** A link that resolves outside
   its source — elsewhere in the repository included — that dangles, or that
   points to a directory enclosing it, is never read through and never copied.
   Sync prints one `WARNING:` line per link, naming the skill and the path that
   is the link. A skill whose directory or `SKILL.md` is such a link is left out
   of every output; any other such link only drops that path from its skill.
3. **One decision per run, for every consumer.** The skills listing settles
   every link once, fail-closed: a link it cannot resolve stops the run rather
   than shorten the list. The shared tree, the glob-listing adapters, the
   `AGENTS.md` index, OpenCode's commands and the frontmatter lint all take the
   same answer.
4. **Generated skill trees never hold a link.** A link no listing covered — a
   copy from outside every skills source — is removed with a warning, and a
   link an earlier sync left in an owned skill tree is pruned.

## Consequences

- An alias inside one source (`skills/x -> _shared/x`) and a resource shared by
  two skills of one source work in every tool. A skill kept elsewhere is added
  as its own source (`intelligence source add`) or a package; both render it in
  full.
- A source without links still costs one `find`, which now walks below the
  skill directories to see a link inside a bundle, and replaces the separate
  `find` the frontmatter lint ran. A source with links resolves them in one
  extra process, plus one `readlink` call per link-chain hop for all its file
  links together, never per file.
- A source with links already bypasses sync reuse, which refuses to fingerprint
  a link ([0010](0010-skip-unchanged-local-sync.md)), so a change behind a link
  always renders.
- Rule and agent sources are not covered here. A rule or agent file that is a
  link is still followed by the adapters that glob it, wherever it points, while
  `AGENTS.md` and the context report skip it; settling that needs its own
  decision.

## Rejected

- **Emit the link and warn** — what a linked `SKILL.md` used to get. The link
  resolves against the output's location instead of the source's, escapes the
  repository when absolute, and skips every transform a skill needs, which in
  Codex makes an owner-only skill selectable by the model.
- **Leave out every link** — safe, but breaks in-source aliases and resources
  shared between skills of one source, which cost nothing to support safely.
