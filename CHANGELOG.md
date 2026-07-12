# Changelog

All notable changes to intelligence-sync are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

**Upgrading** — paste this to your AI agent:

```
Update intelligence-sync: fetch the latest engine from https://github.com/ainova-systems/intelligence-sync and run its update flow to migrate this project to the newest version. Leave my rules, agents, and project skills untouched. If it fails, read the CHANGELOG "### Breaking" entries between my version and the latest, base your fix plan on them, make sure you are running the latest scripts, and retry; ask me only if it still fails.
```

## [Unreleased]

## [0.7.0] — 2026-07-12

The engine stops being only a pipeline and starts shipping its own **authoring discipline**: a rule the model respects while it works, and an agent that owns the layer's shape. Both are upstream-owned — they evolve with the engine instead of drifting inside each project.

### Breaking

- **`config.yaml` must list the module's `rules/` and `agents/` as sources.** The engine now ships artifacts of its own beside the meta-skills, and they only reach the IDEs if `sources` points at them. `migrate_to_0_7_0` adds both entries idempotently (nothing else in `config.yaml` is read or rewritten), exactly as `0.3.1` added the module's `skills/` entry. `sync.sh` fails closed (`IS_STATUS=needs-update`) until the update flow has run — it never migrates.

  Post-conditions to verify after updating:
  1. `sources.rules` contains `<umbrella>/<module>/rules` and `sources.agents` contains `<umbrella>/<module>/agents` — each exactly once.
  2. `<module>/rules/intelligence-authoring.md` and `<module>/agents/intelligence-architect.md` exist.
  3. `config.yaml` `sync_version` is `0.7.0`.
  4. After a sync, no generated file contains a literal `<umbrella>` or `<module>` token.

  Project content (`rules/`, `agents/`, `skills/`, `adapters/`) is untouched. Re-running is a safe no-op.

### Added

- **`intelligence-authoring` — an engine-shipped rule carrying the authoring discipline** (`<module>/rules/`). Path-scoped to the umbrella, so it loads exactly when someone edits the layer and costs nothing otherwise. It is the judgement that sits on top of `CONVENTIONS.md`'s mechanics: which artifact type a piece of knowledge belongs to (a checklist in an agent body is a procedure — it belongs in a skill), why always-on rules must earn their place, why an agent is thin and never restates the rules it already receives, why a skill without a verification step is not a skill, and the invariant that closes the loop on the defect that produced 0.6.0 — *never state behaviour of a tool you have not verified in its documentation or source*.
- **`intelligence-architect` — an engine-shipped agent that designs and prunes the layer** (`<module>/agents/`). Decides rule vs skill vs agent, always-on vs scoped, split vs fold, and what to delete. It carries boundaries and verification only; the rule reaches it on its own, so it does not repeat it.
- **Layout tokens `<umbrella>` and `<module>` in engine-shipped artifacts.** An artifact shipped by the engine cannot hardcode the umbrella's folder name — the project chooses it (`intelligence/`, `Intelligence/`, a codename) — but a scoped rule needs `paths:` to name it. Adapters now expand both tokens on the way out through a single helper (`finalize_output_file`, which replaces `normalize_file_to_lf` at every output site), in frontmatter and body alike: `paths: ["<umbrella>/**"]` arrives as Claude's `paths:`, Cursor's `globs:` and Copilot's `applyTo:` already carrying the real folder name. CI fails the build if any generated output still contains a literal token.
- **`update.sh` owns the module's `rules/` and `agents/`** the way it already owns `docs/` and the meta-skills: staged from the fresh upstream clone, shown in the diff before the confirmation prompt, then applied. Your own `<umbrella>/rules` and `<umbrella>/agents` are never touched.

### Changed

- **INIT no longer suggests skills from a catalogue.** §3.5 listed a menu of plausible skill names (`add-entity`, `add-endpoint`, `run-tests`, …), and an agent working from a menu produces a registry that describes software in general rather than the repository in front of it — every entry costing registry budget forever, whether or not anyone invokes it. A skill must now clear four bars — **repeated** (with the instance in the repo named as evidence), **multi-step and mechanical**, **verifiable** (it ends in a check that proves it worked; if there is nothing to verify, it is not a skill), and **stable** (a procedure that only routes around a current bug belongs in a rule that records known breakage, not in a skill that makes the workaround permanent) — and bootstrap now targets **0–3 skills**, with zero stated as a legitimate answer.
- `examples/go-api-with-opencode/config.yaml` never listed the module's `skills/` as a source, so the meta-skills were missing from that fixture. All six examples now register the module's `rules/`, `agents/` and `skills/`.

## [0.6.0] — 2026-07-12

### Added

- **Project-owned adapters — a custom adapter now survives an engine update.** `sync.sh` scans a second adapter directory, `<umbrella>/adapters/` (beside `config.yaml`), in addition to the built-in `<umbrella>/sync/scripts/adapters/`. Until now `/intelligence-install-adapter` told you to write a custom adapter inside the engine's `scripts/adapters/` — the exact tree `update.sh` replaces wholesale, so the next update deleted it without a diff to notice. Project adapters are project content: updates never touch them. A project adapter whose name matches a built-in overrides it (sync prints a `NOTE:` line naming the file) — an escape hatch for patching a built-in without forking the engine. Nothing changes for projects that have no `adapters/` directory.

### Changed

- **GPT defaults moved to the GPT-5.6 family** ([released July 9, 2026](https://github.blog/changelog/2026-07-09-openais-gpt-5-6-sol-terra-and-luna-are-now-available-in-github-copilot/)) for Copilot and Codex: `heavy` → `gpt-5.6-sol` (highest reasoning ceiling), `standard` → `gpt-5.6-terra` (balanced default), `light` → `gpt-5.6-luna` (fast, cost-efficient) — was `gpt-5.5` / `gpt-5.5-codex` / `gpt-5.5-mini`. The opencode `standard` default moves from `anthropic/claude-sonnet-4-6` to `anthropic/claude-sonnet-5`. Claude and Cursor are unaffected: they map tiers to aliases (`opus`/`sonnet`/`haiku`, `inherit`/`fast`) that resolve to the current model on their own. Projects pinning a model under `models:` in `config.yaml` keep their pin and get the usual drift report on the next sync.

### Fixed

- **`AGENTS.md` no longer tells every tool to run a sync command that does not exist.** The `agents` adapter hardcoded `bash intelligence/scripts/sync.sh` in the generated header and the "Source of truth" line — wrong twice over: it omits the module directory (`sync/`), and the umbrella folder is named by the project, so the lowercase literal is simply a different path on a case-sensitive filesystem (`Intelligence/` ≠ `intelligence/`). `AGENTS.md` is the canonical document Cursor, Copilot and Codex all read, so it was instructing every one of them to run a broken command. Both paths (and the inlined-rules comment) are now derived from `LS_UMBRELLA_DIR` / `LS_MODULE_DIR`, which `detect_layout` resolves before any adapter runs. Re-run sync to regenerate.
- **`targets.*.output` can no longer escape the repository, and `agents` is no longer exempt from the check.** `validate_output_path` compared the raw config string, so a `../` walked straight past every guard, and the `agents` adapter skipped validation entirely — a config line could point adapter cleanup (`rm -rf`) at a directory outside the repo, or aim the `agents` writer at an arbitrary file. Output paths are now lexically canonicalized (new `normalize_path` helper: `..`, `.` and `//` collapsed without touching the filesystem, since the path may not exist yet), required to resolve inside the repository, and validated for **every** adapter including `agents`. Symlinks are covered too: validation resolves the deepest *existing* component of the path — so a symlinked parent escapes detection even when the output itself does not exist yet (the first-sync case) — and refuses to write through a symlinked file target (including a dangling one), while a symlinked directory that stays inside the repo keeps working. Configured source directories are canonicalized before the overlap check too. Not exploitable with a sane config — but a tool people vendor into their repos should not have a config-file-to-arbitrary-write path.
- **A migration no longer deletes the legacy tree without verifying that every copy actually landed.** `migrate_to_0_3_1` ignored the exit status of each `cp`/`rsync` (permissions, full disk) and verified only two script sentinels before removing `INIT.md`, `docs/` and the meta-skills from the legacy location — and because `run_migrations` is invoked in an `||` context, `set -e` did not stop the unchecked failures either. Every copy is now checked, and the full postcondition is verified before anything is deleted: each artifact present at the source must exist in the module, non-empty (scripts, `INIT.md`, `docs/`, and a `SKILL.md` per relocated meta-skill). On any gap the migration aborts with `IS_STATUS=aborted-incomplete` and leaves the legacy tree intact, as the transactional contract always promised.
- **`/intelligence-uninstall-adapter` no longer deletes hand-authored files.** Step 2 said *"remove the generated output directory (e.g. `.cursor/`, `.codex/`)"*, but several adapters write into shared roots — Copilot's output is `.github/`, Claude's is `.claude/`, opencode's is `.opencode/`. Followed literally, it destroyed `.github/workflows/`, `.claude/settings.json`, `.opencode/opencode.json`. The skill now carries a per-target table of the paths each adapter actually owns (mirroring each adapter's own re-sync cleanup), never the output root, and notes that `.agents/skills/` is shared by Codex, Pi and opencode — removed only when none of them remains enabled.
- **`/intelligence-add-agent` no longer generates agents that duplicate their own rules.** Step 6 mandated a "Before Any Task" section referencing `Read intelligence/rules/<domain>.md before starting`. That path is layout-blind (lowercase, no module dir), and the instruction is redundant everywhere: custom subagents inherit the full memory hierarchy — including `.claude/rules/` — at startup ([Claude Code docs, *Subagents → What loads at startup*](https://code.claude.com/docs/en/sub-agents#what-loads-at-startup)), and the other tools get always-on rules inlined in `AGENTS.md`. An agent is thin: expertise, boundaries, verification. The rules arrive on their own. Same fix in `INIT.md` (§3.4 and the Reference section) and `docs/CONVENTIONS.md`.
- **`/intelligence-learn-from-context` can load its own conventions again.** Phase A step 1 — a *required* step — loaded `intelligence/skills/intelligence-add-rule/SKILL.md`, but the meta-skills live under `<umbrella>/sync/skills/`: the path omitted `sync/` entirely and hardcoded the umbrella's casing, so the step could not work on any platform. It now discovers the umbrella and module by role, the way `intelligence-update` does.

## [0.5.2] — 2026-07-09

### Fixed

- **Skill directories are now copied in full — bundled resources ship with `SKILL.md`.** Every adapter copied exactly one file per skill (`SKILL.md`) and silently dropped everything beside it, even though the [Agent Skills open standard](https://agentskills.io) allows support files (`references/`, `scripts/`, `assets/`) next to `SKILL.md` and `docs/CONVENTIONS.md` itself tells authors to move detail into `references/<topic>.md`. A synced skill whose body says `Read references/<topic>.md` was therefore broken at runtime in `.claude/skills/`, `.cursor/skills/`, `.github/skills/`, and `.agents/skills/` — the referenced file simply wasn't there. A new `copy_skill_bundle()` helper in `lib/common.sh` copies the whole skill directory and is now the single copy path for all adapters (`claude`, `cursor`, `copilot`, and `sync_open_skill_dirs` for Codex/Pi/opencode). Markdown files are LF-normalized as before; all other files (potentially binary assets) are copied byte-for-byte; symlinks are copied as symlinks, so a link inside a source skill still cannot leak host file content into outputs. `SKILL.md` keeps its extra strict-YAML frontmatter pass in the open-standard dir. Applies to local and remote (`git+`) skill sources alike; CI smoke and remote-sources jobs now assert a `references/` file lands in every enabled output. No schema migration — the stamp advances to `0.5.2` on update like any release; re-run sync afterwards to materialize previously-dropped resources.

## [0.5.1] — 2026-06-24

### Fixed

- **`AGENTS.md` ordering is now platform-independent.** The `agents` adapter listed skills, agents, and rules in bash glob order, which follows the locale's `LC_COLLATE`: Linux CI (`en_US.UTF-8`) ignores `-` in the primary weight and sorted `backend-add-commands` before `backend-add-command-subscriber`, while Git Bash (`C` locale) uses byte order and sorted them the other way. The same project therefore produced a different `AGENTS.md` depending on which machine ran `sync`, yielding spurious diffs. The three list-building loops in `agents.sh` now feed `find … -print | LC_ALL=C sort`, pinning output to byte order on every platform (this also makes the inline order of always-on rules inlined into `AGENTS.md` deterministic). No schema migration — the stamp advances to `0.5.1` on update like any release, but `config.yaml`, `rules/`, `agents/`, and `skills/` content is untouched. Re-run sync afterwards to regenerate `AGENTS.md` in the now-stable order.

## [0.5.0] — 2026-06-23

### Added

- **Remote git sources.** A `sources.{rules,agents,skills}` entry in `config.yaml` may now be a remote git spec — `git+<url>[@<ref>][#<subpath>]` — alongside local paths. `sync` shallow-clones it on the fly (fresh every run, into a run-scoped temp dir removed on exit) and feeds the resolved directory through the exact same pipeline as a local source, so a team can keep shared intelligence in one repo and pull it into many projects. All adapters and the lint pass route source entries through the new `resolve_source_dir()` helper in `lib/common.sh` — the single point that detects and materializes remote sources, so no adapter needs to know about git. `<url>` must carry an explicit scheme (`https`/`http`/`ssh`/`git`/`file`); the command-executing `ext::`/`fd::` transports are rejected, `..` traversal in `#subpath` is refused, remote repos are cloned with `core.symlinks=false`, and the resolved directory is verified to stay inside the clone — so untrusted remote content can't make the copy step read host files. `@<ref>` pins a tag/branch/SHA (recommended for supply-chain safety); `#<subpath>` selects a directory inside the clone. Within one sync the same `repo@ref` is cloned only once even when several entries reference different subpaths of it; each new sync re-pulls. Clone failures (offline, bad URL, missing subpath, missing credential — git runs with `GIT_TERMINAL_PROMPT=0` so it never hangs) warn on stderr and skip just that source; local sources still sync and the run still reports `IS_STATUS=ok`. Documented in `docs/CONVENTIONS.md` ("Remote sources (git)"); `examples/with-remote-skills/` shows the config. No migration — purely additive, existing local-only configs are unaffected.

### Changed

- First-time setup is now agent-driven. The `README.md` Quick Start is a single copy-paste prompt that hands the AI assistant the upstream URL and lets it clone the engine, copy `intelligence/` into the project, run `INIT.md`, and sync — no manual `git clone`/`cp` step. The old three-step manual flow (and the redundant raw-`INIT.md` URL variant) are removed; one path only.
- `INIT.md` is self-bootstrapping. A new top-of-file **Bootstrap** section installs the engine (clone upstream + copy `intelligence/`) when the file is read remotely and `intelligence/sync/scripts/sync.sh` isn't present yet, so pointing an agent at the raw `INIT.md` URL is a valid entry point. The Pre-check's missing-files branch now routes back to **Bootstrap** instead of telling the user to copy files by hand.

### Fixed

- **`AGENTS.md` no longer embeds remote-clone temp paths.** A remote `sources.*` git spec is materialized in a run-scoped clone cache outside the repo. The `agents` adapter built each link target with a `${path#"$repo_root"/}` strip that is a no-op for those out-of-repo paths, so the committed `AGENTS.md` got machine-specific, ephemeral `…/intelligence-sync-remotes-XXXX/…` links that changed on every run. A new `repo_rel_link()` helper in `lib/common.sh` returns empty for any file outside the repo root, so remote-pack agents/skills/rules are now listed by name (no link) while local items keep their repo-relative link. A post-generation guard fails the sync loudly if an absolute link target ever reaches `AGENTS.md`, so the leak can never be committed silently again. The `pi` adapter's `Source:` line got the same fix.

## [0.4.2] — 2026-06-05

### Added

- opencode adapter now also generates a slash command per source skill at `.opencode/commands/<name>.md`, mirroring Claude Code's skill-as-slash-command UX. Each command's `description` is copied from the source skill's `description` (YAML-escaped — embedded quotes/newlines are made strict-YAML-safe); the body delegates to opencode's `skill` tool and forwards `$ARGUMENTS` so any flag from the skill's `argument-hint` reaches the skill script unchanged. The 1:1 name binding (`/<skill-name>`) means no path/alias remapping. The skills themselves are still copied to `.agents/skills/` (Agent Skills open standard) — this is purely an additional surface so users can invoke skills from the slash menu without going through an agent.
- `OPENCODE_GEN_MARKER` (`<!-- Generated by intelligence-sync. Do not edit manually. -->`) embedded in every generated `.opencode/commands/*.md`. Cleanup is marker-based: re-sync only deletes files containing the marker, so any hand-authored command in `.opencode/commands/` survives. A user-authored file that shares a name with a synced skill is still overwritten — that 1:1 binding is the whole point of the wrap.
- `.gitignore` recommendation extended in `INIT.md` §3.6 and `docs/CONVENTIONS.md` to add `.opencode/commands/` next to `.opencode/agents/`. Existing projects on 0.4.1 should add the line manually when updating; the engine never writes `.gitignore` itself. Hand-authored commands can still be tracked by adding a `!.opencode/commands/<name>.md` un-ignore line, mirroring the Claude/Cursor exception pattern.
- `docs/ADAPTERS.md` Cleanup Contract item 1 and Built-in Adapters Reference table updated to reflect that `opencode.sh` now owns `.opencode/agents/` (wholesale clean) AND `.opencode/commands/` (marker-protected clean).
- `README.md` capability matrix (`What each adapter does`) updated: the opencode `skills` row now notes the generated `/<name>` command in `.opencode/commands/` alongside `.agents/skills/`. `INIT.md` bootstrap `sync_version` example bumped to `0.4.2` to track `scripts/VERSION`.

## [0.4.1] — 2026-06-02

### Added

- Pi adapter (`pi.sh`) — reuses `AGENTS.md` for always-on rules, copies skills into the shared Agent Skills open-standard location (`.agents/skills/`), generates `.pi/prompts/intelligence-agent-*.md` prompt templates from source agents, and emits a small Pi extension (`.pi/extensions/intelligence-sync-rules.ts`) plus `.pi/intelligence-sync/rules/*.md` for path-scoped rules. This keeps Pi support additive and non-conflicting with existing Cursor/Copilot/Codex routing.
- `sync_open_skill_dirs()` shared helper in `lib/common.sh` so Codex and Pi can write the same strict-YAML-safe skill copy without duplicating logic. The helper now owns the full lifecycle of its destination (clean per-skill subdirs + `mkdir -p` + populate), so adapters writing to a shared open-standard dir stay symmetric and future adapters cannot drift on cleanup semantics.
- `sync.sh` AGENTS.md invariant extended to Pi and opencode — enabling `targets.pi` or `targets.opencode` now also requires `targets.agents`, because both adapters receive always-on project rules via `AGENTS.md`. The invariant loop carries an explicit "add new adapters here" comment for future contributors.
- `docs/ADAPTERS.md` "Cleanup Contract" section codifying the three rules every adapter follows: clean only owned subpaths, use shared helpers for shared dirs, declare owned paths in `.gitignore`.
- Docs and INIT guidance for Pi as an optional adapter, including project-safe `.gitignore` patterns that ignore only adapter-owned `.pi/` outputs while preserving `.pi/settings.json` and hand-authored Pi resources.
- opencode adapter (`opencode.sh`) — reuses `AGENTS.md` for always-on rules (opencode reads it natively), copies skills into the shared Agent Skills open-standard location (`.agents/skills/`) via the existing `sync_open_skill_dirs()` helper, and emits opencode-native subagents under `.opencode/agents/<name>.md` with frontmatter (`description`, `mode: subagent`, `model`, `permission.edit`, `permission.bash`) derived from each source agent's `tier:` and `access:`. The adapter cleans only `.opencode/agents/` so user-managed `.opencode/opencode.json` and any other hand-authored config under `.opencode/` stay untouched. Path-scoped rules are not emitted (opencode has no first-class scoped-rule channel — users may opt in via `instructions:` globs in `opencode.json`).
- `opencode:heavy/standard/light` model arms in `get_model_default()` mapping to the latest pinned non-deprecated Anthropic Claude IDs (`anthropic/claude-opus-4-8` / `anthropic/claude-sonnet-4-6` / `anthropic/claude-haiku-4-5-20251001`). Dateless 4.6+ IDs are pinned snapshots per Anthropic's [Models overview](https://docs.anthropic.com/en/docs/about-claude/models/overview), not evergreen pointers.
- `strip_frontmatter()` shared helper in `lib/common.sh` so adapters that wrap source agent bodies (Pi, opencode) reuse one POSIX-awk parser instead of inlining identical blocks. Existing `pi_agent_body` is now a thin alias; opencode calls the shared helper directly. Reinforces the "all parsing in `common.sh`" convention.
- `examples/go-api-with-opencode/` — minimal opencode example alongside `go-api-with-pi-and-codex`.
- Docs and INIT guidance for opencode as an optional adapter, including project-safe `.gitignore` patterns that ignore only `.opencode/agents/` while preserving `.opencode/opencode.json`.

## [0.3.2] — 2026-05-22

### Fixed

- `copy_md_with_quoted_frontmatter` (strict-YAML adapters — Codex `.agents/skills/`) — when wrapping an **unquoted** `description` / `argument-hint` value in double quotes, literal inner `"` (and `\`) are now escaped (`\"`, `\\`). Previously a value such as `Use as a quick "what do we have" view` was wrapped verbatim into `description: "… "what do we have" …"`, which strict YAML parsers reject (`did not find expected key`) — Codex CLI silently skipped the skill at load. Claude's adapter was unaffected (it copies skills verbatim). `lint_frontmatter` now also flags literal double quotes inside unquoted free-text values, and the YAML-safety guidance (`INIT.md`, `intelligence-add-skill`, `intelligence-add-agent`) documents escaping / single-quoting such values.

## [0.3.1] — 2026-05-19

### Changed

- Engine, meta-skills, `INIT.md`, and docs moved into one self-contained module `<umbrella>/sync/`. Project content stays at the umbrella level.
- Versioned migration chain with a `sync_version` key in `config.yaml`; `sync.sh` only syncs, `update.sh` migrates. See `docs/CONVENTIONS.md`.

## [0.2.1] — 2026-05-14

### Fixed

- `intelligence-extract-skill` and `intelligence-review-skills` — quoted `argument-hint` values containing literal colons (`[target: skill|rule|agent]`, `[target: rules|skills|agents|all]`). Unquoted, strict YAML parsers (Codex CLI) interpreted the inner colon as a nested mapping and rejected the skill at load time. Brings both files in line with the project's own YAML-safety rule.

## [0.2.0] — 2026-05-13

### Added

- Three new pre-installed skills:
  - `/intelligence-extract-skill` — extract an observed session workflow into a reusable skill, rule, or agent.
  - `/intelligence-learn-from-context` — capture session lessons and apply them to `intelligence/` after approval; two-phase analyze → apply flow with negative-to-positive translation.
  - `/intelligence-review-skills` — audit `intelligence/` for duplicates, stale artifacts, size violations, and discipline issues; uses git history when available.
- `docs/CONVENTIONS.md`:
  - `Choosing artifact type` section — decision matrix and rule of thumb for rule vs skill vs agent, plus common mistakes to avoid.
  - `Authoring Discipline` section — description sizing (unique vs sibling cases, 250-char cap), size budgets per artifact type (SKILL.md target <500, cap 1000), writing principles (imperative form, positive defaults, explain why, lean prompts, ALL-CAPS only for true invariants).

### Changed

- Rule body template reordered to lead with positive defaults: `REQUIRED → Invariants → Architecture → Build & Test → Examples → Patterns to recognize and replace` (was `FORBIDDEN → REQUIRED → Architecture → Build & Test → Examples`). Anti-patterns now sit at the end as reference documentation rather than as LLM-facing instructions.
- `intelligence-add-rule`, `intelligence-add-skill`, `intelligence-add-agent` step instructions rewritten in positive framing ("Reuse the existing domain when one fits" instead of "Do not invent new domains").
- `intelligence/INIT.md` — Phase 3.3 component-rule template and Rule-body reference reordered to positive-first.
- `update.sh` — expanded default scope to pull meta-skills (`intelligence/skills/intelligence-*`) and `docs/` from upstream, alongside existing `scripts/` and `INIT.md`. Project content (`config.yaml`, `rules/`, `agents/`, non-meta skills) remains untouched. Local meta-skills no longer present upstream are removed on update.
- `intelligence-update` SKILL.md — updated to document the expanded scope.

## [0.1.1] — 2026-05-07

### Changed

- Shortened skill descriptions to fit Claude Code listing budget and prevent truncation.
- Enforced YAML quoting in Codex adapter.

## [0.1.0] — Initial release

First public release.

### Engine

- Single-source-of-truth design: author rules / agents / skills once under `intelligence/`; the sync engine routes content into each IDE's native format.
- Five built-in adapters: `agents` (AGENTS.md), `claude` (`.claude/`), `cursor` (`.cursor/`), `copilot` (`.github/`), `codex` (`.agents/skills/` + `.codex/agents/`).
- Pluggable adapter contract — drop a `<name>.sh` into `intelligence/scripts/adapters/` and it becomes available as a target.
- Zero runtime dependencies beyond `bash` and `awk`.

### Routing

- AGENTS.md is the canonical project doc — Cursor, Copilot, and Codex all read it natively. Always-on rules (no `paths:`) are inlined here once.
- Path-scoped rules stay in tool-specific channels (`.cursor/rules/*.mdc` with `globs:`, `.github/instructions/*.instructions.md` with `applyTo:`) so monorepo glob targeting still works.
- Claude Code receives the full rule set in `.claude/rules/` because it does not read AGENTS.md natively.
- No duplication between AGENTS.md and IDE rule directories.

### Helpers

- `lint_frontmatter` warns on unquoted YAML colons and leading tabs in frontmatter — runs automatically before adapters fire (catches issues that strict consumers like Codex CLI reject silently).
- `get_model` resolves model names from `config.yaml` `models:` overrides, falling back to bundled defaults. Sync prints a drift report when an override no longer matches the current default.
- `update.sh` self-update — clones upstream into a `mktemp -d` directory, shows a diff, and replaces only `intelligence/scripts/` and `intelligence/INIT.md`. Project content (`config.yaml`, `rules/`, `agents/`, `skills/`) is never touched.

### Pre-installed skills

- `/intelligence-sync` — run sync
- `/intelligence-update` — pull latest engine
- `/intelligence-install-adapter` — enable an IDE target
- `/intelligence-uninstall-adapter` — disable and clean up an IDE target
- `/intelligence-add-rule` — create a rule with conventions
- `/intelligence-add-agent` — create an agent with conventions
- `/intelligence-add-skill` — create a skill with conventions

### Examples

- `examples/go-api/` — single-component Go service.
- `examples/dotnet-api-with-react-frontend/` — multi-component project, shared intelligence at root + per-component sources.
- `examples/platform-with-submodules/` — monorepo with git submodules excluded from parent sync.

### Documentation

- `README.md` — problem / why / how positioning.
- `intelligence/INIT.md` — bootstrap prompt for AI assistants (4 phases: discovery, recommendation, generation, verification).
- `docs/CONVENTIONS.md` — frontmatter formats, naming, sync transformations.
- `docs/ADAPTERS.md` — adapter contract, library function reference, distribution via `update.sh`.
- `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, issue / PR templates.
