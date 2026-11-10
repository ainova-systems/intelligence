# 0030 — Render the package an artifact came from as `<package-dir>`

Date: 2026-11-10
Status: accepted

## Context

A package can ship a package-level `references/` folder beside its rules,
agents and skills, such as `references/labels.md`, and its rules cite it in
prose ("the package's `references/labels.md`"). The engine renders only rules,
agents and skills, so in an installed project that file exists only in the
package store, `.intelligence/packages/@scope/name/references/`, and no rendered
text says where. An agent in Cursor or Copilot looks for `references/labels.md`
at the repository root, does not find it, and improvises.

The four layout tokens are global, one value per project. `<module>` names the
store path of one package, the sync package, and nothing names any other. A
package cannot write its own store path: it depends on the name the project
installed it under, and `sources:` may name its directories by store path, full
name or alias (decision 0019).

## Decision

1. A fifth layout token, `<package-dir>`, renders in every rendered file of an
   artifact as the repository-relative root of the installed package that
   artifact came from, `.intelligence/packages/@scope/name`. In an artifact the
   project authored, and in text no artifact wrote (a manifest header, the
   plugin template), it renders as the content directory, the value
   `<content-dir>` has.
2. The package is read from the artifact's source path. Every `sources:`
   spelling of a package directory expands to its store path before any
   renderer reads it (decision 0019), so the path names the package by
   construction: no name map is built and no process is added.
3. It is one more row of `IS_LAYOUT_TOKENS`, marked as following the artifact.
   Expansion, the backslash escape (`\<package-dir>`), the YAML, TOML and
   TypeScript escapers and the source lint derive from that row as they do for
   the other four.
4. Each program renders the token where it knows the artifact. One that reads
   sources takes it from the file it reads, and one that writes a file only
   after reading the next names that file's source. A skill copy maps every
   output file to the skill directory it came from, bundled files included. A
   reader whose text lands in a file several artifacts share, such as
   `AGENTS.md`, Codex's `AGENTS.override.md`, Pi's extension or an `AGENTS.md`
   table row, expands the token as it reads.
5. An older CLI leaves `<package-dir>` as written. A package uses it only in a
   release that requires CLI `0.27.0` or later.

## Consequences

- A package can point its artifacts at any file it ships, `references/`
  included, and every tool reaches the installed copy in the store. Nothing new
  is copied and no adapter owns a new path.
- A project with no `<package-dir>` anywhere renders byte for byte as before.
  The token is reserved in every source: text that already wrote
  `<package-dir>` meaning something else now needs `\<package-dir>`, and the
  source lint names a project source where it reads as part of the text.
- The store is ignored by Git, so the rendered path resolves in a checkout
  after a sync, not on the forge; `AGENTS.md` lists package artifacts by name
  for the same reason.
- A project adapter that writes an artifact's text by other means and
  finalizes it with `finalize_output_file` has no artifact to follow, so the
  token renders as the content directory there. The helpers that render an
  artifact carry it.
- A package directory wired through a project path instead of the store, such
  as a vendored copy, is project content by its path and gets the content
  directory.

## Rejected

- **Copying `references/` into every tool output.** Seven copies of the same
  file, and a new owned path in every adapter contract, each with its cleanup,
  snapshot and Git policy, for a file the store already holds.
- **Packages restating the references inline.** Restating is what their own
  rules forbid: the copy agrees the day it is written and diverges the day the
  reference is extended, and the copy nobody updated is the one an agent reads.
- **The name `<package>`.** It is a common prose placeholder, as in
  `npm install <package>`, and the reservation would silently rewrite every
  such placeholder in every source.
