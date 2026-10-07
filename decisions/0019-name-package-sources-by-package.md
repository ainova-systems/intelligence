# 0019 — Name package sources by package

Date: 2026-10-07
Status: accepted

## Context

`sources:` named an installed package's content only by its store path:
`.intelligence/packages/@ainova-systems/sync/rules`. The layout of the CLI-managed
store was the only spelling a person could write, though the name the project
chose — the `packages:` key — already identifies the directory.

Three facts constrained any other spelling:

- Order is the override rule (decision 0009). Adapters copy sources in order and
  the last write wins, so where a package's entries sit decides which artifact
  survives. A new spelling must never move an entry.
- The engine resolved an entry as `$REPO_ROOT/<entry>` in every reader — each
  built-in adapter, the engine's own loops, `status --check`, the sync cache and
  the store check — and the CLI must see exactly what the engine renders
  (decision 0009, point 7).
- Manifests in the field hold store paths, and teammates run CLIs of different
  versions against one manifest. Within a major, an older CLI keeps working on a
  project a newer one wrote (decision 0005).

## Decision

1. A `sources:` entry has three forms:
   - an ordinary repository path, exactly as before — including the store path
     `.intelligence/packages/@scope/name/<dir>`, which stays valid;
   - `@scope/name/<dir>`, folder `<dir>` of the package `packages:` declares as
     `@scope/name`. An entry is a reference only when its first two segments
     equal a declared package name; otherwise it is an ordinary path, as it
     always was, so nothing that works today changes meaning;
   - `<alias>:<dir>`, the same through the alias that package declares. The
     colon marks this form: a project path never contains one, and
     `source_entry_problem` already refused it.
2. Both references render exactly as the store path they stand for. Expansion
   happens in the engine's list parser (`read_yaml_list`, `load_yaml_lists` in
   `engine/lib/common.sh`), inside the awk pass that already reads the manifest,
   so every reader — adapters, project adapters, the engine's loops and the
   CLI — sees the store path without a change of its own, and the hot list cache
   costs no extra process. The engine now reads two things from `packages:`:
   each package's name and its `alias`, nothing else.
3. `<dir>` is one or more `/`-separated segments, none empty, `.` or `..`, and
   holds no backslash, so a reference never leaves its package.
4. An alias belongs to one package, is stored as `alias: "<alias>"` in that
   package's `packages:` entry, and is written only by the CLI: `package add
   --alias` and `package alias <@scope/name> <alias> | --remove`. It is two or
   more of `A-Z a-z 0-9 . _ -` and starts with a letter or digit — no `/`, `:`
   or `@`, no whitespace or quotes, never one letter that reads like a drive.
   The CLI refuses, before any write, an alias that is malformed or that another
   package declares, and refuses to remove or replace one `sources:` still uses,
   naming the entries. The engine reads an alias only as a lookup key, never as
   part of a path.
5. Nothing migrates and nothing rewrites. Lifecycle alignment leaves `sources:`
   alone; `init`, `package add|remove|update`, restore, the engine-content
   install and legacy conversion write store paths exactly as before. Wiring
   recognises every spelling: when a section already names a package's
   directory, it is left where it stands instead of gaining the store path
   beside it, so restore and alignment never undo a spelling a person chose.
   `package remove` removes every entry naming a directory of the package, in
   every spelling, and its alias with its entry; `update` removes only the
   entries of sections its new version lost, and keeps the others where they
   stand instead of wiring them first again.
6. A reference that names nothing — an alias no package declares or two declare,
   or a malformed `<dir>` — is left out of the parsed list, so no reader can
   take it for a path. `sync` names it in a `WARNING:` line; `status --check`
   reports it, a malformed or shared alias, and a section listing one package
   directory twice under different spellings. An `@...` entry that matches no
   declared package is an ordinary path, judged like any project directory.
7. `source add` and `source remove` refuse a reference in either form, as they
   refuse store paths, naming `intelligence package`; any spelling of a
   package's directory works as a `--before` / `--after` anchor.

## Consequences

- No migration is needed and none ships: store paths stay valid in every
  version, so a manifest a person never edits behaves exactly as before, and the
  release is an ordinary minor with nothing under `### Breaking`.
- A reference is opt-in, written by a person. A CLI of `0.18` or earlier knows
  no references: it reads one as a path that does not exist and skips it, so it
  renders that project without the referenced package content, and its restore
  or alignment wires the store path beside the reference — which a current
  `status --check` then reports as one directory listed twice. The docs and the
  CHANGELOG say so; a team that wants references moves to `0.19.0` first.
- The engine depends on the `packages:` key format (`"@scope/name":` at two
  spaces) and on the `alias:` field four spaces below it. The block stays
  CLI-owned and CLI-written.
- `package remove` also removes a hand-written store path to a non-standard
  directory of the package, which it used to leave dangling.
- `update` no longer moves an updated package ahead of the others; before, it
  reversed which of two packages' same-named files won whenever the second one
  was updated.

## Rejected

- **Short names, `package:sync/rules`.** A short name is ambiguous across
  scopes: `@ainova-systems/sync` and `@acme/sync` share it. Keeping one
  spelling per directory meant rewriting existing entries whenever a colliding
  package arrived or left, and a manifest's meaning depended on the whole
  declared set. A per-package alias names one package by construction.
- **A scope-only form, `@scope/<dir>`.** A scope holds several packages, so it
  names no single directory.
- **A `package:` or `@package/` prefix.** It adds a keyword for what the first
  two segments, or the alias and its colon, already say; and `@package/...` is
  a legal project path, so it would change the meaning of entries that work
  today.
- **Wiring every `packages:` entry implicitly.** It removes the entries
  altogether, but sources would lose their explicit order: packages and project
  directories could no longer interleave, and migrating existing manifests would
  reorder them — a lossy change to which artifact wins.
- **Automatic migration of store paths to references.** Store paths remain
  valid, so there is nothing to migrate. Rewriting them would make every
  teammate and CI job on `0.18` render the project without its package content,
  which within a major is exactly what decision 0005 rules out.
- **Releasing as `1.0.0`.** A major would make an older CLI refuse the project
  loudly instead of skipping a reference, but nothing here needs it: references
  are opt-in and store paths keep working, and the project is not ready for its
  first stable major.
