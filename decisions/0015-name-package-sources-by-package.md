# 0015 — Name package sources by package

Date: 2026-10-07
Status: accepted

## Context

`sources:` named an installed package's content by its store path:
`.intelligence/packages/@ainova-systems/sync/rules`. Every project's source list
therefore carried a vendor scope, and the layout of the CLI-managed store became
part of the manifest a team reads and reviews. The name the project actually
chose — the `packages:` key — already identifies the directory.

Two facts constrained the replacement:

- Order is the override rule (decision 0009). Adapters copy sources in order
  and the last write wins, so where a package's entries sit in the list decides
  which artifact survives. Any spelling change has to happen in place.
- The engine resolved an entry as `$REPO_ROOT/<entry>` in every reader — each
  built-in adapter, the engine's own loops, `status --check`, the sync cache and
  the store check — and the CLI must see exactly what the engine renders
  (decision 0009, point 7). `resolve_source_dir` existed for the purpose, but
  nothing called it.

## Decision

1. A sources entry may name a directory inside an installed package as
   `package:<name>/<dir>`. `<name>` is the full `@scope/name`, or the part after
   its `/` when exactly one package declared in `packages:` carries that part.
   The full form never depends on the other declared names, but either form
   expands only to a package `packages:` declares.
2. Expansion happens in the engine's list parser (`read_yaml_list`,
   `load_yaml_lists` in `engine/lib/common.sh`), inside the awk pass that already
   reads the manifest. Every reader goes through it, so adapters, project
   adapters and the CLI see the store path without a change of their own, and
   the hot source-list cache costs no extra process. The engine now reads the
   names in `packages:` — only the names. Editors that rewrite the manifest read
   entries raw, and `status --check` classifies them with the same parser.
3. A token that resolves to no declared package passes through verbatim. It
   names no directory, so it is skipped like a missing source; `sync` prints a
   `WARNING:` naming it, and `status --check` reports it as a problem: no
   declared package matches it, two declared packages share its short name, or
   it is malformed.
4. The CLI writes one canonical spelling — short while no other declared
   package shares the short name, full for every package that does — through
   one function, `package_sources_respell`, that every wiring path calls:
   package add, remove and update, restore, the engine-content install and
   legacy conversion. An entry resolves against the names declared before the
   edit and is spelled for the set after it, so adding a colliding package
   rewrites the existing short tokens in full, and removing it returns the
   survivor to the short form. Nothing is reordered; `update` keeps a package's
   entries where they stand instead of wiring them first again.
5. Lifecycle alignment rewrites each `.intelligence/packages/<declared name>/<dir>`
   entry in place to its canonical token (migration 3). The generated output is
   byte-identical before and after. A store path of an undeclared package is
   left as written.
6. `source add` and `source remove` treat a `package:` token as package
   territory, as they treat `.intelligence/` paths, and accept one as a
   `--before` / `--after` anchor.
7. The change ships as `0.19.0`, a minor, with a `### Breaking` checklist item:
   every teammate needs CLI `0.19.0` or later. This is a deliberate exception to
   decision 0005, point 4: a CLI `0.18` or earlier is of the same major, so it
   is not refused — it reads a token as a path and renders the project without
   its package content.

## Consequences

- A project's `sources:` names packages the way `packages:` does, without the
  vendor scope or the store layout; examples and new projects use the short
  form.
- A team must move every member and CI job to `0.19.0` before committing the
  migrated manifest. Until then an older CLI produces a quiet partial render
  that reports `IS_STATUS=ok`; the CHANGELOG checklist is the only guard, which
  is the cost of the exception in point 7.
- The engine depends on the `packages:` key format (`"@scope/name":` at two
  spaces). That block remains CLI-owned and CLI-written; the engine reads the
  keys and nothing else.
- `update` no longer moves an updated package ahead of the others. Before, it
  reversed which of two packages' same-named files won whenever the second one
  was updated.

## Rejected

- **Wiring every `packages:` entry implicitly.** It removes the entries
  altogether, but sources would lose their explicit order: packages and project
  directories could no longer interleave, and migrating an existing manifest
  would have to reorder it — a lossy change to which artifact wins.
- **Spelling the token `@package/<name>/...`.** `@` is legal in a project path,
  so the token would be ambiguous with a directory the project owns. `:` is
  already refused in project entries (`source_entry_problem`), so a `package:`
  token can never collide with one.
- **Releasing as `1.0.0`.** Under decision 0005 a newer major makes an older
  CLI refuse the project loudly instead of rendering it partially; it was
  weighed and not chosen, and `1.0.0` remains a separate decision.
- **No automatic migration.** Existing manifests would keep the store path
  until someone edited each one by hand — a hand edit with no gate behind it —
  and both spellings would stay in the field indefinitely.
