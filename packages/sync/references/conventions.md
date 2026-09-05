# Intelligence Authoring Conventions

Intelligence stores project-owned AI rules, agents and skills as tool-neutral Markdown. The CLI installs shared packages, and the sync engine renders each enabled target's native files.

## Choose the right artifact

| Type | Intent | Loading | Content |
|---|---|---|---|
| **Rule** | The model respects a constraint or convention | Automatic: always-on or path-scoped | Required patterns, invariants, architecture and examples |
| **Skill** | The model performs a procedure | Explicit invocation | Ordered steps, decisions and verification |
| **Agent** | The model adopts a role or expertise boundary | Explicit selection or skill binding | Expertise, boundaries and build/verify behavior |

Use these tests:

- “The model should consider this during every task in scope” → rule.
- “The model should execute these steps” → skill.
- “The model should reason as this specialist” → agent.

Do not bury conventions in agents, workflows in rules or reusable expertise in skills. Each misplaced concern either fails to load when needed or consumes context when it is not needed.

## Intelligence project structure

```text
project/
├── intelligence.yaml       # root manifest and schema_version contract
├── intelligence.lock       # resolved packages; commit it
├── intelligence/           # project-owned content; name is configurable
│   ├── rules/
│   │   ├── context.md
│   │   └── backend.md
│   ├── agents/
│   │   └── backend-developer.md
│   ├── skills/
│   │   └── backend-add-endpoint/
│   │       └── SKILL.md
│   └── adapters/           # optional project adapters
│       └── mytool.sh
├── .intelligence/          # CLI-managed package store; gitignored
│   └── packages/
│       └── @scope/name/
├── AGENTS.md               # generated canonical context; normally committed
└── .claude/ .cursor/ ...   # generated tool-native output
```

The content directory defaults to `intelligence/`. A project may set `project.intelligence_dir` in `intelligence.yaml`; never infer or hardcode the default when the manifest is available.

Project-authored rules, agents, skills and adapters live in the content directory. Installed package content lives under `.intelligence/packages/` and is replaced by CLI lifecycle/package operations; edit it only in its source repository. The executable engine remains with the installed CLI, outside the project.

The `intelligence-` name prefix is reserved for artifacts shipped by `@ainova-systems/sync`. Project artifacts use their project or domain prefix.

## Manifest, packages and sources

The engine consumes ordinary local source paths:

```yaml
project:
  name: payments
  intelligence_dir: "intelligence"  # optional; this is the default

schema_version: "0.11.1"

sources:
  rules:
    - ".intelligence/packages/@ainova-systems/sync/rules"
    - "intelligence/rules"
  agents:
    - ".intelligence/packages/@ainova-systems/sync/agents"
    - "intelligence/agents"
  skills:
    - ".intelligence/packages/@ainova-systems/sync/skills"
    - "intelligence/skills"
```

Missing project-owned source directories are skipped, so a package-only project need not create empty `rules/`, `agents/` or `skills/` directories. Source order matters: later files with the same artifact name overwrite earlier ones. Package sources are wired before project sources so the project can override a package artifact deliberately.

The CLI owns package and registry blocks:

```yaml
packages:
  "@acme/backend":
    version: "^1.2.0"

registries:
  - "https://github.com/acme/intelligence-registry.git"
```

Do not put Git URLs or remote tokens directly in `sources:`. Use:

```bash
intelligence package add @acme/backend
intelligence package add github:acme/backend-intelligence
intelligence package add 'git+https://git.example.com/acme/backend.git@main#package'
```

Registries are an ordered trust list and the only resolver for a package name. There is no built-in catalog and no `@org/name` → GitHub guessing. An explicit `github:` or `git+` spec bypasses registry lookup. In every case the manifest stores only requested `version` or `ref`; resolved URL/path and SHA live in the lock.

Stable Git tags provide package versions. Semver ranges select the highest matching stable tag; a `ref:` pin names a branch or commit and does not move during `intelligence update`. One package name has one version per project.

Commit `intelligence.lock`. It records requested versions, source URLs and paths, resolved refs and commit SHAs. After cloning, `intelligence sync` restores a missing store strictly from that lock before rendering; manifest/lock or SHA drift is refused. Re-run `package add` when deliberately changing a source.

`@ainova-systems/sync` is ordinary package content exact-pinned to the bundled engine version. `intelligence init` installs it unless `--bare` is used. Lifecycle preflight keeps that pin and `schema_version` aligned with the installed CLI; package-range updates never move it independently.

## Layout tokens

Package-owned artifacts cannot assume the project's content-directory name or their installed package path. They use tokens expanded by every adapter through `finalize_output_file`:

| Token | Expansion |
|---|---|
| `<content-dir>` | Repo-relative content directory, usually `intelligence` |
| `<module>` | Installed sync package, usually `.intelligence/packages/@ainova-systems/sync` |
| `<manifest>` | `intelligence.yaml` |
| `<sync-cmd>` | `intelligence sync` |

Expansion applies to frontmatter and bodies. Thus `paths: ["<content-dir>/**"]` reaches every native scoped-rule format with the project's real directory name.

Project-authored artifacts normally use their known project paths directly. Tokens are useful only when the same artifact must work under different content-directory or package-store locations.

## Naming

Rule filenames, agent names and skill names share a domain prefix such as `backend-`, `frontend-`, `devops-`, `core-`, `tests-`, a project codename or a monorepo component. Pick the domain from repository structure and reuse it.

- Skills: `<domain>-<verb>-<noun>`, for example `backend-add-endpoint`.
- Agents: `<domain>-<role>`, for example `backend-code-reviewer`.
- Rules: `<domain>.md`, for example `backend.md`.

Common skill verbs:

| Verb | Meaning |
|---|---|
| `add-` | Add one member to an existing set |
| `create-` | Create a new container or top-level artifact |
| `update-` | Revise existing state selectively |
| `run-` | Execute an operation |
| `review-` | Perform read-only analysis |
| `test-` | Verify behavior |
| `remove-` | Remove an artifact safely |

The verb describes the outcome, not whether the skill implements the work or delegates to another command or skill.

## Agent conventions

```yaml
---
name: backend-developer
description: "Implements backend features"
tier: heavy
access: full
skills:
  - backend-add-endpoint
---

# Backend developer

Agent instructions in Markdown.
```

An agent stays thin: **Expertise** → **Boundaries** → **Build & Verify**. Its role, limits and proof of completion belong here; reusable constraints belong in rules and reusable procedures belong in skills.

Do not instruct an agent to read rules or restate their content. Claude loads its generated rules for its subagents, while Cursor, Copilot, Codex, Pi and OpenCode receive always-on rules through `AGENTS.md`. Duplicating a rule in an agent spends context twice and creates a copy that drifts.

### Tier mappings

| Tier | Claude | Cursor | Copilot / Codex | OpenCode | Typical use |
|---|---|---|---|---|---|
| `heavy` | `opus` | `inherit` | `gpt-5.6-sol` | `anthropic/claude-opus-4-8` | implementation, complex reasoning, migration |
| `standard` | `sonnet` | `inherit` | `gpt-5.6-terra` | `anthropic/claude-sonnet-5` | review, validation, analysis |
| `light` | `haiku` | `fast` | `gpt-5.6-luna` | `anthropic/claude-haiku-4-5-20251001` | lookups and simple formatting |

The vocabulary is tool-neutral. Adapters resolve it through `get_model()`. Override a default under `models.<tool>.<tier>` in `intelligence.yaml` only when the project needs a pin; sync reports drift when that override differs from the current default.

### Access mappings

`access: full` inherits ordinary tool permissions. `access: readonly` is transformed into the target's native restriction: for example Claude receives read/search/bash tools with writes disallowed, Cursor receives `readonly: true`, and Codex receives a read-only sandbox.

Use only `full` or `readonly` in source agents. Tool-specific permission syntax belongs in adapters.

## Rule conventions

```yaml
---
paths:
  - "src/backend/**"
  - "config/**"
description: "Backend conventions"
---

# Backend conventions

Rule content in Markdown.
```

`paths:` is optional:

- With `paths:`, the rule is scoped to matching repository files.
- Without `paths:`, the rule is always-on project context.

### Routing

| Source rule | Claude | Cursor | Copilot | Codex / Pi / OpenCode / `AGENTS.md` |
|---|---|---|---|---|
| Scoped | copied with `paths:` | `.mdc` with `globs:` | `.instructions.md` with `applyTo:` | listed in `AGENTS.md`; Pi also gets on-demand files and an extension |
| Always-on | copied | omitted | omitted | inlined once into `AGENTS.md` |

Cursor, Copilot, Codex, Pi and OpenCode consume `AGENTS.md`, so always-on rules are not duplicated in their tool-specific channels. Claude does not consume `AGENTS.md`, so it receives the full rule set. OpenCode and Codex have no generated path-scoped rule channel; OpenCode users may configure `instructions:` globs themselves.

Keep always-on rules small. Put narrow framework or component guidance behind `paths:` so unrelated tasks do not pay its context cost.

## Skill conventions

Skills follow the [Agent Skills standard](https://agentskills.io). Required fields are `name` and `description`.

```yaml
---
name: backend-add-endpoint
description: "Add a backend endpoint"
argument-hint: "<route-name>"
---

# Add a backend endpoint

1. Inspect the existing route pattern.
2. Implement the endpoint.
3. Run focused tests.
4. Report the changed route and verification.
```

Standard optional fields (`license`, `compatibility`, `metadata`, `allowed-tools`) and tool extensions pass through unchanged. A tool ignores fields it does not understand.

These limits reject a skill instead of degrading it:

| Field | Limit | Failure mode |
|---|---|---|
| `name` | 64 characters | Rejected at load |
| `description` | 1024 characters | Rejected at load |
| `argument-hint` | Must be a string | An unquoted `[value]` is parsed as a YAML sequence |

Sync quotes free-text `description` and `argument-hint` values in generated copies. `lint_frontmatter` warns when a name or description exceeds its hard limit, but the author must shorten it.

### Description budget

Descriptions share the tool's available-artifact context budget.

| Case | Format | Target |
|---|---|---|
| Unique skill | Plain verb–noun phrase | 4–8 words |
| Similar sibling skills | Verb–noun plus a distinguishing trigger | 10–20 words, roughly 250 characters or less |

The 1024-character limit is a rejection wall, not a writing target. Curate duplicate and orphaned artifacts before compressing every description into ambiguity.

### Skill body and resources

A skill that performs work carries the decisions and verification needed for that work. A skill that dispatches to deterministic CLI behavior stays thin: it chooses the command, interprets status and adds only judgment that the program cannot provide.

Keep on-demand detail beside the skill:

```text
skill-name/
├── SKILL.md
├── references/    # detailed material loaded only when needed
├── scripts/       # deterministic or repetitive helpers
└── assets/        # templates and output resources
```

The engine copies the complete skill directory. Promote a helper outside the skill only when multiple skills share it.

Size limits are backstops, not quotas:

| Artifact | Hard cap | Response |
|---|---|---|
| `SKILL.md` body | 1000 lines | Move detail to `references/` |
| Reference file | 500 lines | Add a contents list past 300; split if still oversized |
| Rule | 500 lines | Split by scope or move examples behind a skill reference |
| Agent | 200 lines | Move procedures and constraints into skills/rules |

## Writing discipline

- Use imperative form: “Read the manifest,” not “You should read the manifest.”
- Explain why a decision rule exists so the model can apply it to adjacent cases.
- Reserve absolute language for genuine safety, security and output-format invariants.
- Lead with the positive behavior; keep anti-patterns after the actionable guidance.
- Remove instructions that repeat tool defaults, repository facts already discoverable from files, or another artifact.
- Turn repeated deterministic work into a script or CLI command and let the skill interpret it.

Every line enters a finite context budget. Prefer subtraction, consolidation and precise scope over exhaustive prose.

## Generated output and version control

| Target | Rules | Skills | Agents |
|---|---|---|---|
| `agents` | Always-on inlined; scoped listed in `AGENTS.md` | Listed | Listed |
| Claude | `.claude/rules/` | `.claude/skills/` | `.claude/agents/` |
| Cursor | scoped `.cursor/rules/*.mdc` | `.cursor/skills/` | `.cursor/agents/` |
| Copilot | scoped `.github/instructions/*.instructions.md` | `.github/skills/` | `.github/agents/` |
| Codex | `AGENTS.md` only | `.agents/skills/` | `.codex/agents/*.toml` |
| Pi | `AGENTS.md` plus scoped `.pi/intelligence-sync/rules/` | `.agents/skills/` | `.pi/prompts/intelligence-agent-*.md` |
| OpenCode | `AGENTS.md` only | `.agents/skills/` plus slash commands | `.opencode/agents/*.md` |

`AGENTS.md` is regenerated by the `agents` adapter. Its optional static header is `targets.agents.header` in `intelligence.yaml`; generated rule, agent and skill sections follow it. Commit `AGENTS.md` when it is the project's shared canonical context.

By default, commit the manifest, lock, project-owned content, `AGENTS.md`, and shared `.github/` output. Ignore the restorable package store and tool output owned by enabled adapters. `intelligence init` and `intelligence adapter enable` add these patterns without ignoring shared tool roots or settings:

```gitignore
# CLI-managed package store
.intelligence/

# Local root instructions migrate into project rules; local preferences stay ignored
CLAUDE.md
.cursorrules

# Generated Claude and Cursor content; shared settings remain trackable
.claude/*
!.claude/
!.claude/settings.json
.cursor/*
!.cursor/
!.cursor/settings.json

# Generated open-standard and Codex content
.agents/skills/
.codex/agents/

# Generated Pi content
.pi/intelligence-sync/
.pi/extensions/intelligence-sync-rules.ts
.pi/prompts/intelligence-agent-*.md

# Generated OpenCode agents. Commands share a directory with hand-authored
# files, so they remain tracked unless the project chooses exact file ignores.
.opencode/agents/
```

Copilot output lives under `.github/` and is committed with other repository-level GitHub configuration. Do not ignore `.github/` wholesale. `AGENTS.md` is also committed so every clone has the shared tool-neutral entry point before sync.

Git tracking and release packaging are separate policies. When a project
already has `.vscodeignore`, `.npmignore`, or `.dockerignore`, the CLI appends a
small idempotent block excluding the package store, `intelligence.yaml`,
`intelligence.lock`, the complete project content directory, and enabled
adapter output. Existing entries remain untouched and absent secondary ignore
files are not created.

An ignore rule does not untrack a file already in Git. After init or adapter
enable, the CLI reports each affected tracked path that remains in the
worktree with an exact `git rm --cached -- '<path>'` command; this preserves
the local file while removing it from the index. Legacy root entry points
quarantined into the initial backup are ordinary worktree deletions to review
and stage, not candidates for `git rm --cached`.

Before release, inspect the packager's actual file list. An npm `files`
allowlist can force inclusion despite `.npmignore`, and a Dockerfile-specific
`<name>.Dockerfile.dockerignore` takes precedence over the root
`.dockerignore`. Use the relevant pack/list command as the final proof rather
than inferring contents from Git status.

`AGENTS.md` is the only shared root instruction entry point. During onboarding,
move useful repository guidance from legacy root files such as `.cursorrules`
and instruction-bearing `CLAUDE.md` out of their quarantined backup copies and
into project-owned rules, then verify the generated tool output. Do not restore
the original root monolith. Create a new root tool-specific file only when it
contains genuinely local configuration that an adapter cannot represent; keep
that exception gitignored rather than maintaining a second committed source.

Before the first render, `intelligence init` preserves existing AI prompt paths
under `<content-dir>/_backup/`. Its `manifest.tsv` labels the snapshot
`initial-onboarding`, lists exact original paths, and marks legacy entry points.
Those legacy paths are quarantined only for the transactional first render; a
failed render restores them, while a successful render leaves them inactive for
repository learning. The backup remains until the user approves removal.

## Project-owned adapters

Create a project adapter with:

```bash
intelligence adapter create mytool
# implement <content-dir>/adapters/mytool.sh
intelligence adapter enable mytool
```

Project adapters survive CLI upgrades and may override a built-in by name. Each adapter declares a versioned ownership contract beside its sync function; backup, rollback, dependencies and Git policy all consume it. `intelligence adapter enable mytool` runs a full transactional sync so shared context stays current. `intelligence adapter disable mytool` keeps generated output for explicit cleanup; a disabled project adapter can then be deleted with `intelligence adapter remove mytool`. See `adapters.md` for the interface and safety contract.

## Schema and command boundaries

The permanent applied-schema key is the top-level scalar `schema_version` in `intelligence.yaml`. It is not a dotfile and not the CLI package version. Do not rename, move or reshape this key: every engine must be able to decide compatibility before parsing the rest of the manifest.

The public lifecycle is deliberately compact:

- `intelligence init [--preview|--apply]` is universal: it creates a new setup, aligns an existing Intelligence project, or plans/applies conversion of an eligible legacy Intelligence Sync project.
- `intelligence sync [adapter] [--compact]` first aligns an existing Intelligence project with the installed CLI, restores a missing store strictly from `intelligence.lock`, then renders. Compact mode shows context sizes, actionable warnings and final status on success, and all diagnostics on failure. In CI it refuses an alignment that would change tracked files and points to a local `intelligence init --apply` plus review/commit.
- `intelligence update [@scope/name] [--preview|--apply]` is the only update surface. It prints the CLI/project/package plan; default mode prompts, `--preview` never writes, and `--apply` does not prompt. It never moves `ref:` pins.
- `intelligence package add|remove|list|search` owns package inventory.
- `intelligence adapter list|create|enable|disable|remove` owns adapter inventory and target state.
- `intelligence status [--check]` reports state; `--check` runs deep consistency checks.

Implement Intelligence schema changes as idempotent structural checks. Stage and verify replacement state before deleting or replacing prior state. A stale engine refuses a manifest whose `schema_version` is a newer major; a newer minor or patch within the same major warns once and proceeds without restamping the project. Normal project entry points close a behind-project gap through lifecycle preflight.

Breaking changelog entries use a `### Breaking` checklist of verifiable post-conditions. The update skill reads every release across the version gap, chooses the package/CLI/project command sequence and verifies those conditions after the deterministic command completes.

### Engine status contract

The engine emits one machine-readable line, `IS_STATUS=<code> [IS_DETAIL=...]`, and exits with a stable code:

| `IS_STATUS` | Exit | Meaning |
|---|---:|---|
| `ok` | 0 | Sync or operation completed |
| `migrated` | 0 | Initialization converted an older layout |
| `error` | 1 | Generic failure |
| `config-missing` | 2 | Required manifest is absent |
| `ambiguous` | 3 | Conflicting state requiring agent/human judgment; reserved |
| `ahead-of-engine` | 4 | Manifest schema is a newer major than the engine (a newer minor or patch warns and continues) |
| `aborted-incomplete` | 5 | Staged replacement was incomplete; prior state remains |
| `needs-update` | 6 | Project schema is behind the engine; rerun through a public lifecycle command |

Callers capture the real code with `command || rc=$?`. Do not use `if ! command; then rc=$?`; inside that branch `$?` is the status of the negation.

## Project entry points

| Path | Role | Git status |
|---|---|---|
| `intelligence.yaml` | Manifest and schema contract | Tracked |
| `intelligence.lock` | Resolved package state | Tracked |
| `<content-dir>/{rules,agents,skills,adapters}/` | Project source of truth | Tracked |
| `.intelligence/` | Restorable package store | Ignored |
| `AGENTS.md` | Generated canonical project context | Normally tracked |
| Tool output directories | Generated native content | Built-in adapter-owned paths ignored; shared settings tracked |
