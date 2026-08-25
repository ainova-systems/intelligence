# Changelog

All notable changes to intelligence-sync are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html) — with one deliberate departure: **there is no `[Unreleased]` section.** Every change ships as a release. A version bump lands in one commit with `scripts/VERSION`, the `sync_version` stamp in `INIT.md`, and every `examples/*/config.yaml` (CI fails otherwise), and the tag and GitHub release follow immediately — so "merged but not released" is a state this project does not have. Write the new `## [X.Y.Z] — <date>` section directly.

**Upgrading** — paste this to your AI agent:

```
Update intelligence-sync: fetch the latest engine from https://github.com/ainova-systems/intelligence-sync and run its update flow to migrate this project to the newest version. Leave my rules, agents, and project skills untouched. If it fails, read the CHANGELOG "### Breaking" entries between my version and the latest, base your fix plan on them, make sure you are running the latest scripts, and retry; ask me only if it still fails.
```

## [0.11.0] — 2026-08-24

The product interface is now a CLI. `npm i -g @ainova-systems/intelligence` installs one `intelligence` command that owns the whole lifecycle — init, add, install, update, sync, doctor, migrate — with versioned **Intelligence Packages**, a lockfile, and registry-based name resolution. The vendored flow this project shipped with keeps working unchanged; it now prints a one-line recommendation to migrate.

### Added

- **The `intelligence` CLI (`cli/`), published to npm as `@ainova-systems/intelligence`.** A project on the CLI setup holds a root `intelligence.yaml` manifest, its own content under `intelligence/`, a committed `intelligence.lock`, and a gitignored `.intelligence/` store the CLI restores — no engine code in the project at all (the engine ships inside the npm package; a ~50-line Node shim finds bash — Git Bash on Windows — and execs the dispatcher). Commands: `init` (target detection, minimal manifest, first sync), `add` / `remove` / `install [--frozen]` / `update` / `list`, `upgrade`, `sync`, `doctor`, `status`, `registry`, `migrate`. Each command is its own file, so a later per-command port to Node stays mechanical.
- **Intelligence Packages: name → repo resolution plus semver over git tags.** A package name (`@ainova-systems/core`) is the single identifier everywhere — manifest key, store dir (`.intelligence/packages/@scope/name/`, npm's layout), lock key. Resolution order: a project `registries:` scope binding (a git repo holding `index.yaml` — private registries need nothing but a repo), the bundled `registry/index.yaml` (monorepos: `@ainova-systems/core` → `intelligence-dev-packs` `packs/core`), then the convention `@org/name` → `github.com/org/name` — any repo with `rules/` / `agents/` / `skills/` at its root is already a package. Ranges (`^`, `~`, exact, `latest`) match stable `x.y.z` tags via `git ls-remote` and a POSIX-awk comparator; `ref:` stays the branch/SHA escape hatch; direct `github:org/repo[#path]` and `git+<url>[@ref][#path]` specs bypass registries entirely. `intelligence.lock` records name, range, url, path, resolved tag and commit sha, so `install` on a fresh clone reproduces the store without consulting any index, and `install --frozen` fails on any divergence (CI mode).
- **CLI mode in the engine (`IS_CLI=1`) — the same engine, driven from outside the repo.** The manifest location, layout tokens, the protected-directories list and the sync command name arrive via an env contract (`CONFIG_FILE`, `IS_UMBRELLA_REL`, `IS_MODULE_REL`, `IS_PROTECTED_DIRS`, `IS_SYNC_CMD`); the manifest-at-root degradations are restored explicitly (`validate_output_path` protects the content dir and the store, `warn_unsynced` filters on the declared content dir and skips `.intelligence/`). With every variable unset the engine is bit-for-bit the vendored one — proven by the new `legacy-golden` CI job, which syncs the smoke examples with the `main` engine and this one and byte-diffs every output.
- **`<sync-cmd>` layout token.** Engine-shipped content says `<sync-cmd>` where it used to hardcode `bash <module>/scripts/sync.sh`; vendored setups expand to exactly the old string, the CLI to `intelligence sync`. Same for the AGENTS.md header.
- **`intelligence migrate` — vendored (v1) → CLI (v2), transactional.** Stage (manifest transformed comment-preservingly, `packs:` becoming `packages:` entries with their pins, mirrored packs copied — not re-fetched — into the store, sha carried over from `.pack` stamps), verify (every staged source exists, per-adapter enabled/output equality against the old config), then commit in an order where the vendored engine, `config.yaml` and mirrors are deleted only after a real sync of the new state reports `IS_STATUS=ok` (`config.yaml` is kept at `.intelligence/backup/`). `--dry-run` stages and verifies without touching the project. A schema gap is closed by the engine's own migration chain first.
- **npm packaging and pipeline.** `npm/build.sh` assembles the package from the repo (cli + engine + default registry index); the `release-npm` workflow publishes prereleases (`X.Y.Z-rc.N`, dist-tag `next`) from any ref and stable versions only from the matching `vX.Y.Z` tag — the prerelease suffix exists solely in the npm version, never in the engine `VERSION` or `sync_version`. CI gains `cli-shellcheck`, hermetic `cli-e2e` (ubuntu + macos), `npm-pack-smoke` (ubuntu + macos + windows, global install into a spaced prefix through the Node shim), and `legacy-golden`; CI now also runs on `feature/**` pushes.
- **`examples/cli-project/`** — a v2 manifest example, included in the stamp-lockstep check.
- **`intelligence search [term]`** — the catalogue view `list` deliberately is not: `list` answers "what does this project depend on", `search` answers "what could it". Walks every trusted registry and then the bundled index (the same order `add` resolves in, so a shadowed name appears once, from the source that would win), showing each package's description and its state here — `available`, `declared (run install)`, or `installed <tag>`. The public index also ships as a standalone repo, [ainova-systems/intelligence-registry](https://github.com/ainova-systems/intelligence-registry), readable ahead of the copy a CLI release carries.
- **Registries are a trust LIST — and the ONLY resolver.** `registries:` holds registry-repo URLs in trust order (`intelligence registry add <url>` — no scope labels to invent); the first registry to *declare* a name serves it. The CLI core ships **no built-in catalog and no `@org/name` → github convention**: a name nobody explicitly trusted is refused with suggestions instead of resolving to a guessed URL, and registry-less installs are always explicit sources (`github:org/repo`, `git+<url>`). Vendor defaults exist only as manifest lines `init` seeds — the default registry URL and the engine-content package — visible, reviewable, deletable; the distribution's own identity (engine package name/url/path, default registry) is data in `cli/engine-package.yaml`, so a fork or enterprise mirror edits one file and no code. The name stays the trust anchor — a registry never renames a package — and source integrity is its own mechanism: the lock pins url+sha and `doctor` flags a name whose current resolution url no longer matches the lock. The retired flat-map form (`"@scope": url`) keeps being read as plain list entries.
- **The engine's own content is the `@ainova-systems/sync` package.** Package by UX — auto-added by `init` (opt out with `--bare`), visible in `list`/`search`, an ordinary manifest+lock entry, removable with `remove --force` — and bundle by mechanics: pinned exactly to the engine version and materialized from the npm bundle without network whenever the pin matches, so init, fresh-clone `install` and `migrate` stay offline. `intelligence update` skips it; `intelligence upgrade` moves the pin together with the schema stamp, and its inaugural v2 migration converts pre-package manifests (`.intelligence/engine/*` sources) automatically. `sync` fails closed — with the exact remedial command — when store-backed sources are missing or pre-package, instead of silently dropping rule sets.
- **`<manifest>` layout token and mode-aware meta-skills.** Engine content names the project config as `<manifest>` (vendored expansion exactly `config.yaml`; `intelligence.yaml` under the CLI), the authoring skills create content dirs on demand and edit the manifest only when a path is genuinely new, `intelligence-sync` runs `<sync-cmd>` wherever it lands, and `intelligence-update` self-redirects to `intelligence upgrade` on a CLI project — so every meta-skill now ships in both modes with no exclusion list.
- **`intelligence init` writes a minimal, self-documenting manifest** — no directories, no placeholder files; comments in the manifest explain where content goes, packages and registries included; `--dir` names a non-default content dir, `--bare` opts out of the engine-content package. Targets are never invented: `agents` is always on, every per-tool target comes from a repo marker or `--targets` — a marker-less repo gets AGENTS.md only, with a hint.
- **Test suites: 162 cases across five hermetic scripts** (`cli/tests/`, all in CI on ubuntu + macos). Two are table-driven unit suites over the pure layers — `unit-semver.sh` (comparison, npm caret/tilde semantics including the 0.x rules, prerelease exclusion, tag listing and annotated-tag peeling against a `file://` fixture) and `unit-manifest.sh` (the quoted-key editors' comment preservation and idempotence, plus a lockfile round-trip whose empty `path` column must not shift the row). The third, `e2e-negative.sh`, asserts the refusals: bad specs, unsatisfiable ranges, untagged registry packages, `install --frozen` against a moved tag, `doctor` exiting 1 on a fresh clone, both `migrate` refusals — and the **rollback**, driving a migration whose post-commit sync fails and verifying the vendored project comes back untouched.

### Fixed

- **`~x.y.z` version ranges matched nothing.** `semver_match` stripped the tilde with `${range#~}` — an *unquoted* `~` in a strip pattern is a tilde expansion, so it became `$HOME`, never matched, and left the range string intact for a `x.y.z` check it could not pass. Every tilde range therefore resolved to "no tag satisfies", while caret and exact ranges worked, making it look like a packaging problem rather than a parser one. The pattern is quoted now (both operators, for symmetry), and the tilde cases in `unit-semver.sh` are hard assertions — this class of bug is exactly what a table-driven unit suite is for.
- **`intelligence registry add` accepted a URL that is not a registry.** A registry is a git repo with `index.yaml` at its root; recording anything else only failed at the first `add`. The command now fails closed — it fetches the index immediately, lists the packages it offers, and refuses a URL without one (with the format documented in the error; `--force` records it anyway for a registry that does not exist yet).
- **`intelligence add` died silently on a nonexistent conventional repo.** A name no registry declares falls through to `github.com/org/name`; when that repo did not exist, `git ls-remote` failed inside a `pipefail` command substitution and the command exited with no message. The source is now probed up front, and the error explains how the name resolved and suggests near-miss names from every trusted registry ("Did you mean: `intelligence add @ainova-systems/spec`").
- **A CLI-owned block appended to the manifest glued itself to the previous section**; `packages:`/`registries:` created at the end of a file now get a separating blank line.
- **Review hardening (11 findings, all verified).** Package names reject empty and dot segments (`@scope/`, `@a/..` — both became `rm -rf` paths over other packages); `install` fetches into staging and commits to the store only after the integrity verdict, so content that violates the lock can no longer be left where a second `--frozen` run would sync it; `--frozen` now verifies the full manifest↔lock agreement (package sets both ways, version/ref/url/path fields) before restoring anything; `update` unwires a package's previous source entries before fetching, so a version that drops a section dir cannot brick the next sync, refetches when a registry re-points url/path under the same tag, and reports a pinned `update <name>` as skipped instead of "not in the manifest"; re-`add` replaces a package entry whole, never leaving stale `ref:`/`url:` from the previous spec; package sources are inserted BEFORE project sources so a project file overrides a same-named package artifact, as documented; CLI-mode `<module>` points at the installed sync package (not the retired staged path); `migrate --dry-run` applies the engine migration chain to a staged copy of the umbrella, so pre-0.10 configs preview correctly; and migrate's rollback restores `.gitignore` to its pre-transaction state.

### Changed

- **`sync.sh` and `update.sh` recommend the CLI on vendored runs** — one stderr line (`IS_SUPPRESS_CLI_NOTE=1` silences it); stdout and the `IS_STATUS` contract are untouched, and the vendored flow keeps working indefinitely. The `intelligence-update` and `intelligence-sync` meta-skills are not staged into CLI projects (replaced by `intelligence update`/`sync`); vendored projects keep receiving both.

No schema change for vendored projects — the stamp advances to 0.11.0 on update.

## [0.10.1] — 2026-07-29

### Fixed

- **A mirrored pack landed CRLF on Windows, so the tree was dirty after every sync.** `fetch_remote_source` cloned the pack under the host's git configuration, and `core.autocrlf=true` — the Git for Windows default — rewrites every text file to CRLF on checkout unless the *remote* repo declares `.gitattributes` of its own. `materialize_pack` then copies those bytes verbatim into the declared `mirror:`, so a project whose own `.gitattributes` normalizes to LF saw its entire vendored pack reported as modified after each run: no content diff, only line endings, and back again the moment it was reverted. A pack cannot be relied on to declare its line endings, so the engine no longer relies on the host either — the clone, and the SHA-checkout path beside it, now pin `core.autocrlf=false` and `core.eol=lf` next to the `core.symlinks=false` that was already there, and materialize exactly the bytes the pack has stored. `update.sh` pins the same two on its own upstream clone: that checkout is copied straight into `intelligence/sync/scripts/`, so a CRLF one would install CRLF shell scripts. Covered in CI by setting `core.autocrlf=true` globally and asserting the mirror comes out LF.

## [0.10.0] — 2026-07-28

A remote source is now declared once as a **pack** and referenced by name, so its url and its pin live in exactly one place.

### Breaking

- **`external: { dir: … }` is replaced by `packs:`; `migrate_to_0_10_0` rewrites the config.** 0.9.0 put the mirror location in one global block while the identity of each pack — url and ref — stayed duplicated inside every `sources.*` entry that used it. A pack spanning rules, agents and skills therefore carried its `url@ref` three times, and nothing detected the drift when only two of them were bumped: rules pinned at one commit and skills at another is a config that looks fine and reads wrong. `packs:` inverts it. Each pack is declared once (`url`, optional `ref`, optional `mirror`) and referenced as `@<pack>[/<subpath>]`, so the pin has a single home and the mirror is a per-pack path rather than one global directory. The migration is automatic and comment-preserving: every inline `git+` spec becomes a declared pack plus an `@name` reference, `external.dir` becomes each pack's `mirror:` so vendored content keeps landing where it already is, and the `external:` block is dropped. **Post-condition: no `external:` key in `config.yaml`, and a `packs:` block declaring every remote previously reached inline.** Idempotent — a config with no `external:` key and no `git+` token is left untouched.

### Added

- **`packs:` — declared remote sources, referenced by name.** `packs.<name>.{url,ref,mirror}` sits at three levels, exactly like `targets:`, so it is read by the existing `get_nested_yaml_value` and adds no parser. `mirror:` is both the location and the switch: present, the pack is materialized there and committed; absent, it stays transient in the run cache, which is 0.9.0's default behaviour and needs no flag to express. Because the mirror is *declared*, the whole derive-a-name machinery 0.9.0 needed is gone — no basename extraction, no charset sanitizing, no `pack-<key>` fallback, no collision suffix — and a pack name is now purely a reference handle that never becomes a path component. **An undeclared `@pack` reference fails the run** (exit 1, naming the pack and listing the declared ones), deliberately unlike a missing local path, which only warns: the config claims to know that name, so a typo must not silently drop a whole rule set. That check runs up front, in `validate_pack_refs`, because `resolve_source_dir` is always called inside `$( )` — an error raised there would exit the substitution subshell, not the sync. Inline `git+<url>[@<ref>][#<subpath>]` specs keep working as *anonymous* packs: no name, no mirror, always transient. CI job `packs` covers declaration, mirroring, idempotency, the refresh diff, the never-clear guard, the unsafe-mirror refusal, the undeclared-pack failure and the transient path, against a `file://` pack repo.

### Fixed

- **`get_nested_yaml_value` cut values at the last colon, not the first.** The value strip was a greedy `.*:[[:space:]]*`, which on `url: https://host/repo.git` matched through `https:` and yielded `//host/repo.git`. It is now anchored with `[^:]*:`, and an unquoted value additionally drops a trailing ` # comment` per YAML while a `#` inside quotes stays content. This was latent in 0.9.0 — nothing read a URL through this helper — but it also silently truncated any `models.<ide>.<tier>` value containing a colon.
- **A pack could lose every subpath but the last when the run cache was unset.** `materialize_pack` recorded its "already cleared this run" claim only when `IS_REMOTE_CACHE` was exported, yet cleared the directory unconditionally. Since `resolve_source_dir` runs in a command substitution — a fresh subshell each call — a caller that had not exported the cache re-cleared the mirror on every entry, so a pack referenced for rules, agents and skills kept only the last. The claim now uses the same cache-root fallback the clone does.
- **Empty-array expansion under `set -u`.** The new migration iterates with `${#arr[@]}` bounds rather than `"${!arr[@]}"`, which bash 3.2 — the macOS default, and a supported target — treats as unbound when the array is empty.

## [0.9.0] — 2026-07-28

Remote packs can now be materialized into a tracked directory, so an upstream bump is reviewable instead of invisible.

### Added

- **`external: { dir: … }` — remote packs materialized into the repo and committed.** A `git+` source has so far existed only inside the run cache: it was cloned, consumed, and deleted, so the only evidence an upstream pack had changed was a shifted diff in the *generated* output, interleaved with the project's own rules and skills. There was no way to review what a pin bump actually brought in. With an `external:` block each pack is additionally copied into `<dir>/<repo-name>/`, alongside a `.pack` stamp recording `url`, `ref` and resolved SHA — commit that directory and bumping `@v1.2.0` to `@v1.3.0` reads as an ordinary `git diff`, deleted skills included. Only the subpaths the sources actually reference are copied, so a pack's `README`, CI config and tests stay out of the repo, and `.git` is never copied — a nested repository would be recorded as a gitlink, whose contents git does not track, which is the exact state the feature exists to avoid. One directory per `repo@ref`: the first source entry to touch a pack in a run clears it, so content from a previous ref or a since-deleted source entry does not linger. The clear is guarded by the stamp — a directory whose `.pack` does not name the same repo is never deleted, and the pack takes a suffixed name instead, so neither a project-owned folder nor a second pack with a colliding repo basename can be destroyed. Omit the block and behaviour is unchanged: packs stay transient. Two consequences fall out for free — pack files now have committed paths, so `AGENTS.md` and the Pi adapter link to them like any local source instead of naming them bare, and a pinned pack that is already committed keeps working when its remote is unreachable. New CI job `external-packs` covers materialization, idempotency, the refresh diff, the never-clear guard and the unsafe-`dir` refusal against a `file://` pack repo. No schema change — the stamp advances to 0.9.0 on update.

### Changed

- **`external.dir` is validated like an adapter output, minus the umbrella restriction.** `materialize_pack` does an `rm -rf` under that path, so `resolve_external_dir` refuses a value that resolves to the repo root, escapes the repository, or sits inside a configured `sources.*` directory — exit 1 before anything is written. Unlike `targets.*.output` it is deliberately *allowed* inside the intelligence umbrella, since `<umbrella>/external` is the recommended location. Symmetrically, `validate_output_path` now refuses an adapter output aimed at the external dir, and `warn_unsynced` no longer flags materialized packs as unsynced source directories.
- **`get_yaml_field` is the single two-level config reader.** `get_project_name` was a bespoke parser for `project.name`; it and the new `external.dir` lookup now share one helper, alongside the existing three-level readers (`get_nested_yaml_value`, `get_target_field`). No new parsing logic entered the codebase.

## [0.8.1] — 2026-07-26

### Changed

- **`add-` and `create-` are told apart by what already exists, not by how a skill is built inside.** The old contract defined them by implementation facts — `add-` "creates exactly one artifact", `create-` "orchestrates several `add-` skills" — and both mispredict a real registry. A downstream project's `cms-add-block` writes a doc type, an element type, several uSync configs and a Razor partial, and is still plainly the right name; its `asana-create-work` orchestrates no `add-` skill at all, because none exists, and carried a written exemption note explaining the name "despite the naming contract". A definition whose only instance needs an apology is measuring the wrong thing. A call-graph definition also makes a name depend on today's factoring: splitting a skill's internals into three `add-` calls would have demanded a rename, though nothing changed for the caller. The verbs now split on the host — **`add-` puts one new member into a set that is already there** (a field on an existing type, a record among records, a component in the inventory the project keeps), and **`create-` brings the container itself into existence**, where nothing hosted it before — and neither says anything about the inside of a skill. The `Atomic` / `Orchestrator` / `Meta-orchestrator` tier vocabulary goes with it: how much a skill body carries turns on whether that skill dispatches to others, which was always the real question and never a function of its verb. Applied in `intelligence-authoring`, both copies of `docs/CONVENTIONS.md`, `INIT.md`, and the `intelligence-add-skill`, `intelligence-extract-skill` and `intelligence-learn-from-context` skills. No schema change — the stamp advances to 0.8.1 on update.

## [0.8.0] — 2026-07-21

The engine now ships two personas: `intelligence-architect` owns what the layer contains, and the new `intelligence-operator` runs the machinery that ships it.

### Added

- **`intelligence-operator` — a standard-tier agent for the engine's mechanical flows.** Sync, update and adapter install/removal are deterministic, fail-closed procedures: `sync.sh` refuses across an un-applied schema, `update.sh` stages and verifies a sentinel before it commits, and every skill branches on the `IS_STATUS` contract — so their failure mode is a loud refusal and a retry, not a plausible wrong answer, and they do not need the heavy model the judgement work runs on. The four flow skills (`intelligence-sync`, `intelligence-update`, `intelligence-install-adapter`, `intelligence-uninstall-adapter`) now declare `agent: intelligence-operator`, following the `agent: intelligence-architect` precedent `intelligence-review-skills` set in 0.7.2. `intelligence-sync` — the one flow with no human step mid-run — additionally sets `context: fork`, so a direct `/intelligence-sync` executes in the operator's own context where the tool supports forking (verified in Claude Code; tools without forking fall back to the `agent:` binding or the session model). The update and adapter flows stay binding-only on purpose: each can need the user mid-flow (an `ambiguous` update state, adapter research, the `AGENTS.md` removal confirmation), and a forked skill reaches the human only by relaying its final message. No schema change — the agent reaches the IDEs through the `sources` entries 0.7.0 added; the stamp advances to 0.8.0 on update.

### Changed

- **Full-access agents no longer emit a `tools:` list in `.claude/agents/`.** A closed list restricts the agent to exactly the named tools and silently drops every MCP server — confirmed empirically in Copilot (VS Code) reading `.claude/agents/`: `tools: ["*"]` did not enable MCP, omitting the field did, letting the agent inherit every session tool, MCP servers included (Claude Code behaves the same). `readonly` agents keep their explicit allowlist and `disallowedTools`. The trade-off: omission also inherits every built-in, which can push a Copilot request over its 128-tool cap and trigger virtual-tools grouping that intermittently hides MCP — the durable fix is an explicit allowlist naming the project's MCP servers, which needs per-project input and is tracked rather than encoded. The Access Mappings table in `docs/CONVENTIONS.md` reflects the new output.

## [0.7.4] — 2026-07-15

### Fixed

- **Engine-shipped `description` fields no longer carry an em dash.** The `intelligence-architect` agent and the `intelligence-authoring` rule described themselves with an em dash, and the `intelligence-add-agent` frontmatter template modelled one - so every consumer that inlines a description into a registry (`AGENTS.md`, the agent and skill pickers) inherited it, which is wrong for a project whose house voice forbids the character. A `description` is compact metadata reproduced verbatim across every tool, so these are plain hyphens now; the em-dash voice in prose bodies is unchanged. No schema change - the stamp advances to 0.7.4 on update.

## [0.7.3] — 2026-07-15

### Fixed

- **`migrate_to_0_3_1` no longer deletes a project's own `<umbrella>/scripts/`.** The 0.3.1 migration detected the pre-0.3.1 flat engine by the bare presence of `<umbrella>/scripts/` and then `rm -rf`'d it — but a modular project may legitimately keep its own tooling there (build/design scripts, tests, fixtures), and the migration relocated the real engine into `sync/` while deleting the project's code as "legacy". Because `run_migrations` walks the whole chain on every `update.sh`, this fired on each update, not once. The flat engine is now identified by its entry script `scripts/sync.sh` — the same sentinel the migration's own postcondition already verifies — so a `<umbrella>/scripts/` without it is left untouched, and the destructive cleanup is guarded by the same sentinel. A genuine pre-0.3.1 layout (which always ships `scripts/sync.sh`) still migrates exactly as before; a modular project that owns `<umbrella>/scripts/` is now a correct no-op. No schema change — the stamp advances to 0.7.3 on update; re-run sync afterwards.

## [0.7.2] — 2026-07-14

0.7.0 shipped the engine's authoring discipline but left out its thesis. This release puts it back: **subtraction is the job** — every line is loaded into someone's context out of a shared, finite budget, so the default answer to "should this be a rule?" is no. The audit skill is rebuilt around the same idea, and stops assuming a layout it has no right to assume.

### Changed

- **`intelligence-authoring` now leads with subtraction.** A registry is not free: an always-on rule is loaded into *every* session forever, a line you add is a line something else loses, and the loss is invisible. The rule now opens with that, ranks the three ways to shorten — **make the rule unnecessary** (a gate the model cannot skip beats a rule listing which command to run for which change: a list is a menu, and a menu gets ordered from), delete what the code already says, cut the words but keep the reason — and states plainly that a new artifact is the most expensive answer available and the one that feels cheapest to write. Also added: *explain the why, but only a why you can back* (an invented reason is worse than none — it sounds like evidence); the invariant against unverified claims about tooling now **cites the documentation it is derived from**, so it obeys itself; size is reframed as a **backstop, not a goal** (hard caps only — a "comfortable" target is a number to pad toward).
- **Where a helper lives is decided by reuse, not repetition.** Content stays **inside the skill's own folder by default** (`references/`, `scripts/`, `assets/` — sync copies the whole bundle, so a helper travels with its skill to every tool). It is promoted beside the source groups only when a *second* skill needs it; a helper one skill runs a hundred times still belongs to that skill.
- **`intelligence-architect` is thinner.** The "what this agent decides" list duplicated the rule, so it is gone; the agent now states what it optimises for (subtraction) and carries one boundary — *a claim you cannot verify is one you do not get to write* — plus its verification. An agent that repeats its own rule is the defect the rule warns about.

### Fixed

- **`intelligence-review-skills` audited a layout it had guessed.** It enumerated `intelligence/rules/`, `intelligence/agents/`, `intelligence/skills/` as literal paths and loaded `docs/CONVENTIONS.md` from a literal path — so in any project that renamed the umbrella, split its sources into several groups (a shared pack plus a project group), nested them, or pulled a `git+` remote pack, the audit read directories that do not exist. It now resolves the layout by role and **enumerates from `config.yaml` `sources`**, whatever they are.
- **The audit would have proposed edits to engine-owned artifacts.** Since 0.7.0 the module's `rules/` and `agents/` are listed in `sources`, so a sweep over the sources now includes `intelligence-authoring` and `intelligence-architect` — and `update.sh` replaces those wholesale, so any local "fix" is deleted at the next update. The skill now skips everything under `<module>/` and reports a genuine gap there as a **proposal to upstream** instead of patching it locally.

### Added

- **Generic checks in `intelligence-review-skills`**, each with a portable detection command (no `\b`, no `-P` — the same command works in Git Bash on Windows, on macOS with BSD grep, and on Linux): a markdown **link from one rule to another** (dead in at least one channel, since always-on rules are inlined into `AGENTS.md` while the scoped channels carry only scoped rules); **machine facts in a rule** (a shell, a home directory, a drive letter — those belong in a personal, gitignored `CLAUDE.md`, because a rule is read by everyone including whoever is on another platform); a **literal path baked into a skill** (a skill is *executed*, so it breaks when the layout moves — with the skill's own bundle explicitly exempt); a **skill with no verification** at the end; the **reserved `intelligence-` prefix** on a project artifact (the updater prunes what matches it); **misplaced content** (a checklist in an agent, a workflow in a rule) as a `MOVE`, not a rewrite; and an **unbacked reason**, which is surfaced to its owner and never rewritten. The skill now asks subtraction first: before proposing a split or a patch, ask whether the artifact should exist at all.
- `intelligence-review-skills` declares `agent: intelligence-architect` — the engine ships the persona that runs its own audit.
- **Two `description` numbers, no longer conflated:** ~250 characters is the house budget that keeps the shared registry affordable; **1024 is a wall** — the tools reject a longer description outright and the artifact vanishes from the picker (sync warns at the wall since 0.7.1).

## [0.7.1] — 2026-07-12

### Fixed

- **Skills with an unquoted `argument-hint` failed to load in Claude Code, Cursor and Copilot.** Frontmatter quoting ran only for the Agent Skills open-standard directory (`.agents/skills/`), so `.claude/skills/`, `.cursor/skills/` and `.github/skills/` received the source frontmatter verbatim. An unquoted hint such as `argument-hint: [pr-number]` is a YAML **flow sequence**, not a string — Claude Code rejects the whole skill (*"argument-hint must be a string"*) and it silently disappears from the picker. The quoting pass now lives inside `copy_skill_bundle`, the single copy path every adapter uses, so all targets get it; the redundant second pass in `sync_open_skill_dirs` is gone. Quoting stays idempotent — already-quoted values pass through untouched. Re-run sync to fix affected skills.
- **A symlinked `SKILL.md` is no longer materialized into the outputs.** Every text pass in the engine (LF normalization, token expansion, frontmatter quoting) reads a file and writes it back — run one through a symlink and the link's *target*, a host file outside the repo, gets copied into the generated skill. `cp -R` preserves symlinks precisely so that cannot happen, and `find -type f` already skipped them; the new quoting pass used `[ -f ]`, which follows links. It now leaves a symlinked `SKILL.md` exactly as copied and warns that it is emitted unprocessed. CI asserts a `SKILL.md -> /host/file` symlink never leaks its content into `.claude/`, `.agents/` or `AGENTS.md`.
- **An over-long `description` silently produced a skill that no tool would load.** Both Claude Code and the Agent Skills standard cap it at 1024 characters (*"Skill description must be at most 1024 characters"*) and reject the file outright, with no signal anywhere in the sync output. `lint_frontmatter` now warns at sync time, naming the file, line and actual length, for `description` (>1024) and `name` (>64). It stays a warning, not an error — the engine reports the problem, the author fixes the source.

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
