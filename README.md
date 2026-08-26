# Intelligence

**Build, version and distribute AI coding intelligence from one project source.**

Intelligence keeps rules, agents and skills in tool-neutral Markdown, installs shared content as versioned packages, and renders each enabled AI tool's native files. One CLI owns the manifest, package lock, local package store and sync engine.

> v2 is currently a release candidate. Use the `next` npm tag until a stable release is announced.

## Quick start

Requirements: Node.js 18+, Git, Bash and awk. On Windows, use Git Bash or WSL.

```bash
npm install -g @ainova-systems/intelligence@next

cd your-project
intelligence init --targets claude,codex
```

`init` creates a root `intelligence.yaml`, an `intelligence.lock`, adds the engine-content package `@ainova-systems/sync`, detects tool markers unless targets are named explicitly, and runs the first sync. It does not invent tool directories that the project did not request.

Create project-owned content only when you need it:

```text
intelligence/
├── rules/
│   └── context.md
├── agents/
│   └── backend-developer.md
└── skills/
    └── backend-add-endpoint/
        └── SKILL.md
```

Then render every enabled target:

```bash
intelligence sync
```

After cloning an existing project, restore its package store from the committed lockfile:

```bash
intelligence install --frozen
```

## What it solves

- Author shared context once instead of maintaining separate copies for Claude Code, Cursor, GitHub Copilot, Codex, Pi and OpenCode.
- Preserve native scoping and agent formats for each tool.
- Install reusable rules, agents and skills from trusted registries or explicit Git sources.
- Commit a reproducible lockfile while keeping fetched package content out of Git.
- Keep the executable engine outside consuming projects.

## Project layout

```text
your-project/
├── intelligence.yaml       # manifest; commit it
├── intelligence.lock       # resolved package state; commit it
├── intelligence/           # project-owned rules, agents, skills, adapters
├── .intelligence/          # CLI-managed package store; gitignored
├── AGENTS.md               # generated canonical context; normally committed
└── .claude/ .cursor/ ...   # generated tool-native output
```

The project owns `intelligence/`. The CLI owns `.intelligence/`. The sync engine is installed with the CLI and never copied into the project.

The engine's own authoring rule, agents, meta-skills and documentation are ordinary package content in `@ainova-systems/sync`. `init` exact-pins that package to the bundled engine version and can materialize it from the npm bundle without network access. Use `init --bare` to opt out.

## Commands

| Command | Purpose |
|---|---|
| `init [--targets a,b] [--dir d] [--bare] [--no-sync]` | Create a v2 project. Tool markers are detected unless targets are explicit. |
| `add <spec> [--name @s/n] [--no-sync]` | Resolve, fetch, install and lock a package. |
| `remove <name> [--force]` | Remove a package from the manifest, lock and store. |
| `install [--frozen] [--force]` | Restore the store from the lock; `--frozen` refuses drift. |
| `update [name]` | Re-resolve package version ranges and rewrite the lock. |
| `upgrade` | Align the project schema and `@ainova-systems/sync` package with this CLI's engine. |
| `sync [target]` | Render all enabled targets, or one named adapter. |
| `list`, `search [term]`, `status`, `doctor` | Inspect packages and project health. |
| `registry <list\|add\|remove>` | Manage the ordered trust list used for package-name resolution. |
| `adapter new <name>` | Scaffold a project-owned adapter from the bundled template. |
| `target enable\|disable <name>` | Enable or disable a manifest target. |
| `migrate [--dry-run] [--force]` | Transactionally convert a final-schema v1 project to v2. |

Run `intelligence help` for the installed CLI's exact interface. The complete package, manifest and migration contracts are in [docs/CLI.md](docs/CLI.md).

## Packages and trust

An Intelligence Package is a Git repository, or a subdirectory of one, with any of these top-level directories:

```text
rules/
agents/
skills/
```

Add by a globally unique name declared by a trusted registry:

```bash
intelligence registry add https://github.com/acme/intelligence-registry.git
intelligence add @acme/backend
```

Or use an explicit source without a registry:

```bash
intelligence add github:acme/backend-intelligence
intelligence add 'git+https://git.example.com/team/prompts.git@main#package'
```

Registries are the only resolver for package names. There is no built-in catalog and no `@org/name` to GitHub guessing. The first trusted registry that declares a name wins.

Stable `x.y.z` Git tags, optionally prefixed with `v`, provide package versions. Semver ranges select the highest matching stable tag. A `ref:` pin is the escape hatch for a branch or commit and does not move during `update`.

`intelligence.lock` records the requested version, source URL, source path, resolved tag and commit SHA. `install` restores from this resolved truth without consulting registries; `install --frozen` is intended for CI.

## How rules are routed

Always-on rules are inlined once into `AGENTS.md`, which Cursor, Copilot, Codex, Pi and OpenCode read as project context. Their adapters do not duplicate those rules into tool-specific channels.

Path-scoped rules stay in native scoped channels where supported:

| Tool | Scoped-rule output |
|---|---|
| Claude Code | `.claude/rules/*.md` (all rules; Claude does not consume `AGENTS.md`) |
| Cursor | `.cursor/rules/*.mdc` with `globs:` |
| GitHub Copilot | `.github/instructions/*.instructions.md` with `applyTo:` |
| Pi | generated on-demand rule files and extension |
| Codex / OpenCode | no generated scoped-rule channel |

Agents are transformed to each tool's native frontmatter or file format. Skills follow the [Agent Skills standard](https://agentskills.io) and are copied as complete bundles, including their `references/`, `scripts/` and `assets/` directories.

## Custom adapters

Built-in adapters live with the installed engine. Project-specific adapters live in `intelligence/adapters/`, survive CLI upgrades, and can override a built-in by name.

```bash
intelligence adapter new mytool
# implement sync_to_mytool() in intelligence/adapters/mytool.sh
intelligence target enable mytool
intelligence sync mytool
```

See [Writing an Adapter](packages/sync/docs/ADAPTERS.md) for the contract, safe cleanup rules and test workflow.

## Migrating from v1

The archived vendored v1 product remains at [`ainova-systems/intelligence-sync`](https://github.com/ainova-systems/intelligence-sync). Existing v1 projects continue using their own `update.sh` and engine.

`intelligence migrate --dry-run` accepts a project already at the final v1 schema (`0.10.0`), stages and verifies the conversion, and writes nothing. If the project is older, first run the `update.sh` already vendored in that project, then migrate. A real migration requires a clean working tree unless `--force` is supplied and commits destructive changes only after the staged v2 project syncs successfully.

## Repository layout

```text
cli/                 # command dispatcher, commands and package manager
engine/              # executable sync engine bundled with npm
packages/sync/       # engine-owned content installed into projects
npm/                 # Node launcher and package build
docs/                # product and CLI documentation
examples/            # v2 manifests used by smoke tests
decisions/           # architecture decisions for this repository
```

The executable engine and its content package are separate trees on purpose. See [decision 0001](decisions/0001-split-v1-archive-from-v2-product.md).

## Development

```bash
bash cli/tests/unit-semver.sh .
bash cli/tests/unit-manifest.sh .
bash cli/tests/e2e-packages.sh .
bash cli/tests/e2e-lifecycle.sh .
bash cli/tests/e2e-negative.sh .
bash npm/build.sh 0.0.0-dev
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution and validation guidance.

## License

MIT. See [LICENSE](LICENSE).
