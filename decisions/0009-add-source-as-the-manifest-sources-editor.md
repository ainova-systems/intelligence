# 0009 — Add `source` as the editor of project-owned `sources:` entries

Date: 2026-09-08
Status: accepted

## Context

`sources:` is the one engine-readable block with no command behind it. `package add` and
`package remove` own its `.intelligence/` entries; every other entry — a monorepo's
per-component directories, a pack developed inside the repository that ships it — was
added by editing the manifest by hand. The engine itself asked for that edit: the
unsynced-directory warning ended in "Add these paths to sources: in intelligence.yaml".

A hand edit here is not merely inconvenient. Four spellings fail *silently*, after a sync
that still reports `IS_STATUS=ok`:

- an absolute path — the engine resolves every entry as `$REPO_ROOT/<entry>`, so
  `/abs/rules` becomes `$REPO_ROOT//abs/rules`, matches no directory, and is skipped;
- a path leaving the repository (`../`, or a symlink pointing out) — it renders, but
  `repo_rel_link_var` returns nothing for a file outside the root, so `AGENTS.md` carries
  bare artifact names instead of links;
- a path under `.intelligence/` — package territory, dropped by the next lifecycle
  alignment;
- a path a double-quoted YAML scalar cannot carry verbatim.

The repository root fails the other way round. `.` *is* a directory, so nothing is
skipped: every top-level `*.md` beside it — `README.md`, `CHANGELOG.md`, whatever the
repository keeps at its root — is read as an artifact of that section.

The insert and remove primitives already existed for package wiring
(`sources_add_entry_first`, `sources_remove_entry`), but they were shaped for their single
caller: presence was a substring search over the whole file, which is exact enough for
`.intelligence/packages/@scope/name/<section>` and wrong for an arbitrary path.

Order is the reason all of this matters. Adapters copy sources in order and the last write
wins, so an entry's position decides which artifact survives.

## Decision

1. `source add|remove|list` joins the public surface as the editor of the project's own
   `sources:` entries, one file in `cli/commands/`. `.intelligence/` stays with `package`:
   `add` refuses a store path, `remove` names `package remove` instead.
2. `add` appends by default. The end of a section is the project's own territory, where a
   directory the project added wins over every installed package.
3. `--first`, `--last`, `--before <entry>` and `--after <entry>` place an entry
   explicitly. The anchored forms are how content that should behave like a package — a
   pack developed in the repository that ships it — lands after the store entries and
   ahead of the project's own.
4. Adding an entry a section already holds is a no-op; adding it *with* a position moves
   it. Every mutation prints the resulting order, because the order is the decision.
5. The four silent failures above, and the repository root, are refused before the entry
   is written. A directory that does not exist yet is a warning, not a refusal: the
   manifest records intent, and the engine deliberately skips a missing source.
   Spellings of one directory are reduced to one before anything is stored, compared or
   judged, so `./x/`, `x/.` and `x/./y` are that directory and `.`, `./` and `sub/..`
   are the root.
6. One definition covers both directions. `source_entry_problem` classifies an entry, and
   `status --check` reports through it what `source add` refuses — so a manifest edited by
   hand before this command existed is judged identically.
7. Presence is exact and scoped to its section, read through the engine's own list parser.
   The CLI must see exactly what the engine will render, never a second interpretation of
   the same lines.

## Consequences

- The `sources:` block has an owner for every entry: `package` for the store, `source` for
  the project. Nothing in the manifest is left to a hand edit with no gate behind it.
- One directory may now feed two sections (`shared/prompts` under both `rules:` and
  `agents:`), and a bare `- docs/api` entry no longer blocks adding `docs`.
- A manifest edit that cannot be placed refuses and leaves the file untouched, instead of
  landing the entry somewhere else or aborting mid-command with a staged `.cli.tmp` left
  behind.
- `status --check` now fails a manifest that was already broken. That is the point: the
  entry it flags was rendering nothing.

## Rejected

- **`local add|remove` as the name.** The command manages exactly the `sources:` block, so
  the manifest already names it; and "local" describes neither a monorepo's per-component
  directories nor a pack that ships from this repository.
- **Inserting before the project's own entries by default.** It is right for exactly one
  case — a pack dogfooded in its own repository, which must override the installed package
  without overriding the project — and wrong for the other case the command exists for.
  `examples/dotnet-api-with-react-frontend` fixes the monorepo order as
  `intelligence/rules` then `backend/intelligence/rules`: component sources come *after*
  the root and deliberately override it, which this default would reverse. Nothing
  distinguishes the two: both paths sit outside `.intelligence/`, and a package is an
  ordinary directory with no manifest of its own to detect. The dogfooding case is one
  `--before` away; the monorepo case would have needed `--after` on every call.
- **Requiring a position on every add.** It buys the same precision `--before` already
  gives, and charges it to the most common call.
- **Extending `package add` to local directories.** `package` owns name resolution, the
  lock and the store; a directory in the repository has none of them, and reusing the verb
  would put an unversioned path in the block that exists for versioned intent.
- **Repairing a path instead of refusing it** — converting backslashes, resolving `..`,
  stripping the store prefix. A source entry decides which artifact wins, so an entry the
  user did not type is the wrong kind of help; the error names the corrected spelling and
  lets them retype it.
- **Refusing a directory that does not exist.** The manifest records intent, a
  package-only project authors nothing of its own, and the engine already skips a missing
  source by design. A warning says so without blocking the wiring.
