# Intelligence

**Build, version and distribute AI coding intelligence from one project source.**

Intelligence keeps rules, agents and skills in tool-neutral Markdown, installs shared content as versioned packages, and renders each enabled AI tool's native files. One CLI owns the manifest, lockfile, package store and sync engine.

> v2 is currently a release candidate. Use the `next` npm tag until a stable release is announced.

## Quick start

Requirements: Node.js 18+, Git, Bash and awk. On Windows, use Git Bash or WSL.

```bash
npm install -g @ainova-systems/intelligence@next

cd your-project
intelligence init --targets claude,codex
```

`init` is the universal project entry point:

- with no Intelligence setup, it creates `intelligence.yaml`, the lockfile and the initial package store;
- in an archived v1 project, it previews the migration and asks before applying it;
- in a v2 project, it aligns the schema and engine-content package with the installed CLI.

Use `intelligence init --preview` to inspect without writing and `intelligence init --apply` for explicit non-interactive application.

After the first successful sync, ask your agent to run
`/intelligence-learn-from-repository`. It inspects the repository and proposes
the smallest useful set of project-owned rules, agents and skills. Analysis is
read-only; each proposed change requires approval.

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

Then render every enabled adapter:

```bash
intelligence sync
```

After a fresh clone, the same command restores a missing `.intelligence/` package store strictly from the committed lockfile before rendering.

## What it solves

- Author shared context once instead of maintaining separate copies for Claude Code, Cursor, GitHub Copilot, Codex, Pi and OpenCode.
- Preserve native rule scoping, agent formats and skill bundles for each tool.
- Install reusable intelligence from trusted registries or explicit Git sources.
- Commit reproducible package state while keeping fetched content out of Git.
- Keep executable engine code outside consuming projects.

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

The project owns `intelligence/`. The CLI owns `.intelligence/`. The engine ships with the CLI and is never copied into a v2 project.

The authoring rule, engine agents, meta-skills and their shared references are installed as `@ainova-systems/sync`. `init` exact-pins this package to the bundled engine version and can seed it from the npm bundle without network access. Use `init --bare` to opt out.

## Public CLI

| Command | Purpose |
|---|---|
| `init [--preview\|--apply]` | Create, convert, restore or align the current project. Supports `--targets`, `--dir`, `--bare`, `--no-sync` and conversion `--force`. |
| `sync [adapter]` | Restore missing locked content, align v2 when safe, then render all enabled adapters or one named enabled adapter. |
| `update [@scope/name] [--preview\|--apply]` | Show the CLI/project/package update plan; ask before applying by default. |
| `package add\|remove\|list\|search` | Manage and inspect versioned Intelligence Packages. |
| `adapter list\|create\|enable\|disable\|remove` | Discover built-ins and manage project-owned adapters and their manifest state. |
| `status [--check]` | Show project state; `--check` performs deep manifest, lock, store and engine consistency checks. |
| `registry list\|add\|remove` | Manage the ordered trust list used for package-name resolution. |

Run `intelligence help` for exact arguments. See [the CLI reference](docs/cli.md) for lifecycle behavior and safety contracts.

### Automatic v2 alignment

The first project-aware mutating command run with a newer CLI automatically aligns an existing v2 manifest and its engine-content package before doing its own work. This keeps normal local workflows on one current schema without a separate maintenance command.

CI never performs an implicit tracked alignment. If committed project state is behind the installed CLI, the command fails and asks you to run `intelligence init --apply` locally, review the diff and commit it.

`update` is deliberately plan-first:

```bash
intelligence update --preview  # read-only
intelligence update            # show plan, then ask in an interactive terminal
intelligence update --apply    # apply without asking
```

It reports the installed CLI against its npm channel, project schema/content alignment and movable package ranges. Updating the globally installed npm package remains an explicit npm operation shown in the plan.

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
intelligence package add @acme/backend
```

Or use an explicit source without a registry:

```bash
intelligence package add github:acme/backend-intelligence
intelligence package add 'git+https://git.example.com/team/prompts.git@main#package'
```

Both forms produce the same compact manifest shape: the package entry keeps
only the requested `version` or `ref`. The resolved repository URL, optional
subdirectory, tag/ref and commit SHA belong only to `intelligence.lock`.

Registries are the only resolver for package names. There is no built-in catalog and no `@org/name` to GitHub guessing. The first trusted registry that declares a name wins.

Stable `x.y.z` Git tags, optionally prefixed with `v`, provide package versions. Semver ranges select the highest matching stable tag; GitHub Releases are not consulted. A `ref:` pin is the escape hatch for a branch or commit and does not move during `update`.

`intelligence.lock` records the requested version, source URL, source path, resolved tag/ref and commit SHA. `sync` restores missing locked packages without consulting registries or re-resolving ranges. Re-run `package add` explicitly when you intend to change a package's source.

If a manifest declares packages but its lockfile is missing, lifecycle commands
fail before changing anything. Restore the committed `intelligence.lock`; the
CLI does not reconstruct a partial lock from whichever packages happen to be
available locally.

## How rules are routed

Always-on rules are inlined once into `AGENTS.md`, which Cursor, Copilot, Codex, Pi and OpenCode consume as project context. Their adapters do not duplicate those rules into tool-specific channels.

Path-scoped rules stay in native channels where supported:

| Tool | Scoped-rule output |
|---|---|
| Claude Code | `.claude/rules/*.md` (all rules; Claude does not consume `AGENTS.md`) |
| Cursor | `.cursor/rules/*.mdc` with `globs:` |
| GitHub Copilot | `.github/instructions/*.instructions.md` with `applyTo:` |
| Pi | generated on-demand rule files and extension |
| Codex / OpenCode | no generated scoped-rule channel |

Agents are transformed to each tool's native frontmatter or file format. Skills follow the [Agent Skills standard](https://agentskills.io) and are copied as complete bundles, including their `references/`, `scripts/` and `assets/` directories.

## Custom adapters

Built-ins live with the installed engine. Project adapters live in the configured content directory, survive CLI updates and may override a built-in by name.

```bash
intelligence adapter create mytool
# implement sync_to_mytool() in intelligence/adapters/mytool.sh
intelligence adapter enable mytool
intelligence sync mytool
```

`adapter disable` keeps generated output for explicit cleanup. `adapter remove` removes only a disabled project adapter source and also keeps generated output. See [Writing an Adapter](packages/sync/references/adapters.md) for the implementation contract.

## Moving an archived v1 project to v2

The archived v1 product remains at [`ainova-systems/intelligence-sync`](https://github.com/ainova-systems/intelligence-sync). Existing v1 projects keep using their vendored engine until conversion.

```bash
intelligence init --preview
intelligence init --apply
```

Conversion requires the final v1 schema (`0.10.0`). An older project must first bring itself to that schema with its archived engine. `init --preview` writes nothing; application stages and verifies the v2 project before removing old state.

The conversion preserves project-owned sources and replaces the old shared
module content with the sync package bundled in the installed CLI. When it
finishes, run `/intelligence-learn-from-repository` to review what was preserved
and propose any missing repository-specific context.

## Repository layout

```text
cli/                 # public command groups and internal lifecycle mechanics
engine/              # executable sync engine bundled with npm
packages/sync/       # engine-owned content installed into projects
npm/                 # Node launcher and distribution build
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
