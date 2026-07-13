# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

intelligence-sync is the sync **engine**: a zero-dependency bash + awk pipeline that transforms tool-agnostic markdown (`intelligence/rules/`, `agents/`, `skills/`) into the native format each AI coding tool reads (Claude Code, Cursor, GitHub Copilot, OpenAI Codex, `AGENTS.md`). This repo *is* the upstream that downstream projects copy and pull updates from — it also dogfoods itself (the `intelligence-*` meta-skills under `intelligence/sync/skills/` are authored here).

**Modular layout (0.3.1+), pure — no bridge, no duplication.** Everything upstream-owned lives in the one self-contained module `intelligence/sync/` (`scripts/`, `skills/intelligence-*`, `INIT.md`, vendored `docs/`, `scripts/VERSION`). The umbrella folder (`intelligence/`) holds only `config.yaml` + project content (`rules/ agents/ skills/<project>/`) and is **never hardcoded** — code derives it as "the dir holding config.yaml" (`detect_layout` in `lib/layout.sh`). Future modules (e.g. `domain/`) sit beside `sync/`, each updated independently. The repo has **no flat twin**: a pre-0.3.1 client's frozen `update.sh` fails *closed* against this layout (exit ≠ 0, changes nothing — verified back to v0.1.0, guard precedes any destructive op), so there is no data-loss path and no calendar cutover. Repo-root `docs/` is the doc source; `intelligence/sync/docs/` is its vendored copy (regenerated, kept identical by CI).

## Commands

```bash
# Run the full sync against this repo's config (intelligence/config.yaml — note:
# this upstream repo ships no config.yaml; sync runs in downstream projects)
bash intelligence/sync/scripts/sync.sh

# Sync / test a single adapter (the only practical "single test" — no unit harness)
bash intelligence/sync/scripts/sync.sh claude
REPO_ROOT=/path/to/test/project bash intelligence/sync/scripts/sync.sh cursor

# Lint shell (matches CI; template is intentionally excluded — `<name>` breaks the parser)
find intelligence/sync/scripts -name '*.sh' -not -path '*/adapters/_template.sh' \
  -print0 | xargs -0 shellcheck --severity=warning

# Self-update engine from upstream (clones to mktemp, diffs, prompts; --yes skips)
bash intelligence/sync/scripts/update.sh
```

There is no build step and no test framework. Correctness is verified by the CI **smoke job** (`.github/workflows/ci.yml`): it stages each `examples/*/config.yaml` as a throwaway project, runs sync, and greps the generated outputs. Reproduce a failure locally by replicating those steps against `examples/<name>/`.

## Architecture

`sync.sh` (entry point) → `lib/common.sh` (shared helpers) → `adapters/<name>.sh` (one per target tool). Flow:

1. Resolve `REPO_ROOT` (git toplevel, normalized via `cd && pwd` so Git Bash `D:/` vs `/d/` styles match) and `config.yaml`.
2. Enforce the **agents invariant**: if `cursor`/`copilot`/`codex` is enabled, `agents` must also be enabled — those tools get always-on rules *only* via `AGENTS.md` (skipped in their own channels to avoid duplication). Skipped when a single target is requested via `$1`.
3. `lint_frontmatter` every source file (warns on unquoted colons / leading tabs — strict YAML consumers like Codex CLI reject these).
4. For each enabled adapter: resolve output dir, run `validate_output_path` (refuses paths that resolve to repo root, the intelligence source tree, or any configured source — adapters `rm -rf` their output, so a misconfigured path would destroy work; `agents` is exempt as it writes a single file), then `source` the adapter and call `sync_to_<name>()`.
5. Post-sync: `warn_unsynced` (flags `rules/`/`agents/`/`skills/` dirs not in config) and `report_model_drift` (config `models:` override differs from current hardcoded default).

**The central design decision — rule routing, not flagging:** always-on rules (no `paths:`) are inlined *once* into `AGENTS.md`, which Cursor/Copilot/Codex read natively, so their adapters skip always-on rules entirely (no duplicated context burning the window). Path-scoped rules stay in per-IDE channels with native scoping (`.cursor/rules/*.mdc` `globs:`, `.github/instructions/*.instructions.md` `applyTo:`) so monorepo glob targeting works. Claude Code does not read `AGENTS.md`, so `claude.sh` receives the *full* rule set. Understanding this requires reading `agents.sh`, `claude.sh`, and the routing tables in `docs/CONVENTIONS.md` together.

**Adapter contract:** each adapter is one file defining `sync_to_<name>(repo_root, config_file, output_dir)`, discovered by filename (`_template.sh` excluded). The tool-agnostic source vocabulary — `tier: heavy|standard|light`, `access: full|readonly` — is mapped per-tool inside adapters via `lib/common.sh` helpers (`get_model`, `map_access_to_claude_tools`, etc.). Model defaults live in `get_model_default()`; bumping them is intentionally surfaced downstream via the drift report. See `docs/ADAPTERS.md`.

**Breaking-change update architecture + bash↔skill contract:** `lib/layout.sh` (`detect_layout` → `LS_*`, self-locating, name-agnostic) and `lib/migrations.sh` (`MIGRATIONS=()` ascending append-only registry + `run_migrations` dispatcher + `migrate_to_<v>` + `check_version_compat` + `is_status` + `read_engine_stamp`/`stamp_version`). The applied schema version is the **frozen contract key `sync_version` in `config.yaml`** (a permanent top-level scalar — never `scripts/VERSION`, never a dotfile; no migration may rename/move it). Correctness rests on **idempotent structural preconditions**: each `migrate_to_*` self-detects whether its change is applied and no-ops; the dispatcher runs the whole chain in order and does **not** gate on the stamp — a wrong/missing stamp can never skip a migration. Each migration is transactional/fail-closed (stage → verify sentinel → commit → only then delete prior state). Any unresolvable state emits `IS_STATUS=<code>` + stable exit (`IS_RC_*`: ok/migrated 0, error 1, config-missing 2, ambiguous 3 [skill-only], ahead-of-engine 4, aborted-incomplete 5, needs-update 6). The stamp's only role is the `ahead-of-engine` guard (stale engine refuses a project schema newer than `scripts/VERSION`). **`sync.sh` is a pure synchronizer — never migrates**; it fails closed (`needs-update`) when non-modular or stamp < engine. **`update.sh` is the sole migrator.** The **`intelligence-update` skill** (trigger: "Update intelligence-sync") is the brain: discovers the engine *by role* (a dir with `scripts/sync.sh`+`scripts/VERSION`, highest VERSION, never an old flat one), reads the CHANGELOG across the version gap (each breaking release has a **`### Breaking`** subsection with post-conditions), runs `update.sh`, branches on `IS_STATUS`, and verifies each breaking post-condition after. Contract documented in `docs/CONVENTIONS.md`; callers capture rc via `cmd || rc=$?` (never `if ! cmd; then exit $?`).

## Conventions for engine code

- **Zero dependencies beyond bash + awk.** `mktemp`/`find`/`cp` are POSIX-OK. No `jq`, no Python, no gawk extensions — awk must be **POSIX** (no 3-arg `match()`; see the inline-vs-block parsing in `get_target_field`).
- **Never duplicate parsing logic.** All frontmatter extraction, YAML reading, and model resolution go through `lib/common.sh`. Adding a parser elsewhere is the main thing to push back on.
- **Cross-platform awk hygiene.** Every awk program strips `\r` (`sub(/\r$/, "")`) because source files may be CRLF on Windows. Frontmatter parsers are scoped to the first `--- ... ---` block so body content (e.g. a code sample mentioning `paths:`) is never miscounted.
- `set -euo pipefail` in every script. Shell scripts are forced to LF via `.gitattributes` (`*.sh text eol=lf`) — critical for bash on all platforms; do not let an editor reintroduce CRLF.
- Comments explain *why*, not *what*; skip them where names already carry intent.
- `intelligence/sync/scripts/` and `intelligence/sync/INIT.md` are the only files `update.sh` overwrites downstream — treat them as the public engine API. Project content (`config.yaml`, `rules/`, `agents/`, `skills/`) is never touched by updates.

## Authoring artifacts (skills/rules/agents in `intelligence/`)

When editing the `intelligence-*` skills or any rule/agent, follow `docs/CONVENTIONS.md`: rule = constraint the LLM respects (auto-loaded), skill = procedure the LLM performs (explicit `/name`), agent = persona the LLM adopts. Names are `<domain>-<verb>-<noun>`; `description` fields share a global token budget (keep short — 4–8 words if unique, ≤250 chars with a distinguishing trigger if there are siblings). Update `CHANGELOG.md` for user-facing changes.

## Releasing

A version bump is **not released** until a git tag *and* a matching GitHub release exist — generating the tarball/release is the final, mandatory step, not optional polish. Releases are cut **directly on `main`** (house style — see `… released the fix as 0.5.0` in history; no release branch, no PR).

**Version numbers: default to patch.** The minor is not a changelog counter — it is reserved for a genuinely **new capability**, something a downstream project can now *do* that it could not before (a new adapter, a new engine feature like project-owned adapters or layout tokens, a new shipped artifact). Everything else is a **patch**, however large the diff: bug fixes, rewritten rule/skill/doc content, sharper prose, extra checks inside an existing skill, refactors. A minor bump for "we improved the text" is version inflation — ask "what can a user do now that they could not yesterday?", and if the answer is nothing, it is a patch.

- **patch** — fixes and content changes, no new capability.
- **minor** — a new capability, back-compatible.
- **breaking (minor or major)** — needs a `migrate_to_<v>` in `lib/migrations.sh` *and* a `### Breaking` subsection in `CHANGELOG.md` with verifiable post-conditions.

There is no `[Unreleased]` section in `CHANGELOG.md`: every change ships as a release, so nothing ever waits in one. Write the dated `## [X.Y.Z]` section directly.

The engine version lives in `intelligence/sync/scripts/VERSION` and is **lockstep** with the `sync_version` stamp: `sync.sh` fails closed (`needs-update`) when its `VERSION` is newer than a project's `sync_version`, and CI (`repo-purity` job) asserts every `examples/*/config.yaml` is stamped at exactly `VERSION`. So every release bumps, in one commit, **all** of: `scripts/VERSION`, the `sync_version:` example in `intelligence/sync/INIT.md`, and `sync_version:` in **every** `examples/*/config.yaml`. Mismatch = red CI.

Procedure (run from a clean `main`, working tree already holding the change):

```bash
# 1. Lockstep version bump (VERSION + INIT.md example + all examples/*/config.yaml)
#    and a NEW CHANGELOG.md [X.Y.Z] — <date> section written directly — there is no
#    [Unreleased] section: every change ships as a release, so nothing ever waits in
#    one. (Breaking releases add a ### Breaking subsection with verifiable
#    post-conditions.)
# 2. Verify lockstep locally (mirrors CI repo-purity):
V=$(tr -d ' \t\r\n' < intelligence/sync/scripts/VERSION)
for cf in examples/*/config.yaml; do
  [ "$(awk -F'\"' '/^sync_version:/{print $2;exit}' "$cf")" = "$V" ] || echo "DRIFT: $cf"
done
# 3. Commit + push to main, then tag and publish the GitHub release:
git commit -am "…released … as $V"        # one-sentence, past-tense message
git push origin main
git tag "v$V" && git push origin "v$V"     # tag convention is vX.Y.Z
gh release create "v$V" --title "v$V" --notes-file <notes>   # notes mirror v0.5.0:
#   one-paragraph description → ## Highlights (### Added/Changed/Fixed, condensed
#   from the CHANGELOG section) → Full changelog link → ## Install. Latest release
#   is what downstream `update.sh` pulls, so the release must point at the tagged commit.
```

## Commit messages

Capitalized, past tense, one sentence (e.g. `Added Codex adapter with AGENTS.md generation`) — matches existing history.

**Never add a `Co-Authored-By` trailer or any AI/tool attribution to commit messages or pull request bodies.**
