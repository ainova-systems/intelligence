# Contributing to Intelligence

Thank you for improving the Intelligence CLI, sync engine or package content.

## Before you change code

Read [decision 0001](decisions/0001-separate-legacy-intelligence-sync-from-intelligence.md) and [decision 0002](decisions/0002-consolidate-intelligence-cli-lifecycle.md). Keep Intelligence separate from legacy Intelligence Sync and preserve the compact public command model; do not reintroduce vendored engine layouts, `packs:`, mirrors, `update.sh` or the legacy migration chain.

Open issues against [`ainova-systems/intelligence`](https://github.com/ainova-systems/intelligence/issues). Include the operating system, shell, installed npm package version, `intelligence status`, the failing command and a minimal redacted `intelligence.yaml` when relevant.

## Submitting a change

1. Fork the repository and branch from `main`.
2. Keep the change within the relevant boundary: package and lifecycle mechanics in `cli/`, deterministic rendering in `engine/`, installed content in `packages/sync/`.
3. Add or update the narrowest automated test that proves the behavior.
4. Run the relevant checks below.
5. Update user-facing documentation and the compact changelog when behavior changes.
6. Open a pull request explaining the observable result and validation performed.

## Public CLI contract

Keep top-level product behavior inside the established surface: `init`, `sync`, `update`, `package`, `adapter`, `status` and `registry`. Package and adapter verbs are subcommands of their respective groups.

- `init` owns new-project setup, legacy-project conversion and project alignment.
- Project-aware mutations align Intelligence projects automatically; CI refuses an implicit tracked alignment and asks for a reviewed `intelligence init --apply` diff.
- `sync` restores a missing package store from the committed lock before rendering.
- Planned writes use `--preview` and `--apply` consistently.
- Deep consistency validation belongs to `status --check`.

Do not add a top-level command when one of these groups already owns the lifecycle state or resource.

## Validation

One gate runner owns the list, so local runs and CI cannot drift:

```bash
bash cli/tests/verify.sh        # the gates your diff can affect
bash cli/tests/verify.sh all    # shellcheck plus every CLI suite
```

Without an argument it reads the diff against `main`, runs the applicable gates cheapest first, and prints the ones it skipped. `lint`, `lint-cli`, `lint-engine` and `tests` select a scope explicitly; CI calls those same scopes. Adding a gate means editing `cli/tests/verify.sh`, never the workflow.

The lint gate needs `shellcheck` on `PATH` and refuses to report success without it. The unexpanded adapter template is intentionally excluded from its scope.

The end-to-end tests use local `file://` Git fixtures. Keep new tests hermetic and independent of public registries.

For distribution changes, verify the npm payload:

```bash
bash npm/build.sh 0.0.0-dev
(cd npm/dist && npm pack --dry-run)
```

Confirm that it contains `cli/`, `engine/` and `packages/sync/`, and that the bundled sync package contains content only—never `engine/sync.sh` or other executable engine files.

## Adding a built-in adapter

1. Copy `engine/adapters/_template.sh` to `engine/adapters/<name>.sh`.
2. Replace every `<name>` placeholder and implement `sync_to_<name>()`.
3. Use shared functions from `engine/lib/common.sh` for source iteration, frontmatter, model mapping, skill bundles and output finalization.
4. Clean only adapter-owned paths; never delete an entire tool root that may contain user files.
5. Add adapter coverage to the smoke or lifecycle suite and document the output in [the adapter guide](packages/sync/references/adapters.md).

The template is invalid shell until its placeholders are replaced because `<` is parsed as redirection.

## Testing a project-owned adapter

In a disposable Intelligence project:

```bash
intelligence adapter create mytool
# implement intelligence/adapters/mytool.sh
intelligence adapter enable mytool
intelligence sync mytool
```

Verify the generated paths, run a second sync to prove idempotence, and confirm unrelated hand-authored files under the same tool root survive.

## Code style and safety

- Use Bash with `set -euo pipefail` and LF line endings.
- Keep engine dependencies to Bash, awk and ordinary POSIX utilities; do not add jq, Python or GNU-only awk syntax.
- Reuse parsers in `engine/lib/common.sh` and `cli/lib/`; do not fork YAML or frontmatter parsing logic.
- Treat manifest, lock and registry values as untrusted before passing them to Git or filesystem operations.
- Stage and verify migrations or package-store replacements before committing them.
- Pass every emitted text file through `finalize_output_file`; copy complete skills with `copy_skill_bundle`.
- Explain constraints and intent in comments, not code that is already clear from its names.

## Versioned files

Every pull request merged into `main` belongs to one concrete changelog version.
Check whether the non-prerelease GitHub Release matching `engine/VERSION` is already
published. If it is, select the next SemVer version and create its changelog
section; otherwise add the change to the existing pending version. Changelog
headings contain only `[X.Y.Z]`—GitHub Release records the publication date, and
this repository does not use an `[Unreleased]` section.

When selecting a new version, keep these exact values aligned:

- `engine/VERSION`;
- `schema_version` in every `examples/*/intelligence.yaml`;
- the `@ainova-systems/sync` exact pin in every example.

Do not create tags or Releases as part of an ordinary contribution. A maintainer
tags the reviewed `main` commit whose concrete version is already prepared, then
publishes the matching GitHub Release. Non-prerelease GitHub Releases publish to
npm `latest` and advance `next` to the same stable version; GitHub prereleases
publish to `next`. The pipeline never writes back to `main`.

## Commit messages

Use one capitalized, past-tense sentence, for example: `Added adapter lifecycle coverage`.

Do not add `Co-Authored-By` trailers or AI/tool attribution.

## License

By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE).
