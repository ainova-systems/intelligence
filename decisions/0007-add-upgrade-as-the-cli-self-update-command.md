# 0007 — Add `upgrade` as the CLI's self-update command

Date: 2026-09-07
Status: accepted

## Context

Decision 0002 made `update` the only update-planning surface and left replacing the global
executable to npm: the plan printed `npm install -g @ainova-systems/intelligence@<channel>` for
the user to run by hand. Every other lifecycle step is one Intelligence command with `--preview`
and `--apply`, so the CLI step was the only one a user or the update meta-skill had to assemble
from a printed string, and that string installed a moving dist-tag rather than the version the
plan had shown. It also assumed npm was the installer, although pnpm, yarn, bun, Volta and `npx`
all run the same launcher and `npm install -g` would leave a second copy beside theirs.

The word `upgrade` was removed in 0002 together with the legacy project-upgrade command, so the
name was free but retired.

## Decision

1. `upgrade` joins the public surface as the one command that replaces the installed CLI. It
   takes the `--preview` / `--apply` modes of `init` and `update` and no project arguments: it
   never reads or writes a project.
2. The channel follows the running version — `next` for a prerelease, `latest` otherwise — and
   the version installed is exactly the one the plan showed, never a dist-tag.
3. `upgrade` replaces the installation it runs from: it derives the npm prefix from its own
   location (`<prefix>/lib/node_modules/<pkg>` on POSIX, `<prefix>/node_modules/<pkg>` on
   Windows) and passes it to npm explicitly. A source checkout, an `npx` run, a checkout linked
   with `npm link`, another package manager's store or any other layout is refused with the
   command that upgrades that installation where it lives.
4. `update` keeps planning the CLI step and names `intelligence upgrade` instead of an npm
   command; the update meta-skill runs it after approval. Version-gate messages that told the
   user to reinstall the CLI point at `upgrade` too.
5. The npm launcher exports the installed package name beside its version, so `update` and
   `upgrade` address the package that is actually installed and nothing in `cli/` names it.
6. `upgrade` now means the executable and nothing else. Item 7 of 0002 is amended, not reversed:
   `install`, `migrate`, `outdated`, `target`, `doctor` and the bare package verbs stay unknown.

## Consequences

- One vocabulary: CLI, project and packages each move with an Intelligence command, and all
  three share the preview / ask / apply contract.
- `upgrade` and `update` stay separate on purpose. An npm write outside every project and a
  project write have different blast radii, and a running command cannot re-execute itself as
  the new version to finish the project half of one plan.
- The install runs in a fresh shell that holds no file inside the package, because npm rewrites
  the directory the command lives in and Windows refuses to delete an open file.
- The e2e assertion that `upgrade` is an unknown command becomes an assertion that help lists it.

## Rejected

- **`update --apply` installs the CLI as well.** The npm write needs no project and lands
  outside it; folding it into a project command would hide the larger write behind the smaller
  one and would still need a re-exec to apply the rest of the plan with the new engine.
- **A different name (`self-update`, `update --cli`).** A flag on `update` still needs the
  project-free code path and could not be previewed alone; `self-update` adds vocabulary for
  what comparable CLIs (`deno`, `bun`, `rustup`) call `upgrade`.
- **Installing through whichever package manager is detected.** Running pnpm, yarn or bun on
  the user's behalf multiplies untested write paths; naming the exact command is enough.
- **Asking npm for its global root and installing only when this tree is under it.** npm
  answers for the current configuration, not for the tree that is running, so a CLI installed
  under nvm or a custom prefix would be refused or replaced elsewhere; and npm redacts
  UUID-like path segments from everything it prints, so such a root can never match. The
  package's own location already says where it was installed, and passing that prefix costs no
  extra process.
- **Deriving a prefix for every layout.** Volta's package images look like an npm prefix
  (`…/packages/<pkg>/lib/node_modules/<pkg>`) but are not one; known non-npm stores are named
  before the layout rule applies, and an unrecognized layout is refused rather than guessed.
- **Restarting the new CLI to finish an `update` plan in one go.** Re-executing a freshly
  installed executable from the old one hides which version applied a tracked change; two
  explicit commands keep each write attributable.
