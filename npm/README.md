# @ainova-systems/intelligence

**npm for AI agent intelligence.** One CLI that builds, versions and distributes the rules, agents and skills your AI coding tools run on — rendered natively for Claude Code, Cursor, GitHub Copilot, OpenAI Codex, Pi, OpenCode and `AGENTS.md`.

```bash
npm install -g @ainova-systems/intelligence

cd your-project
intelligence init
intelligence add @ainova-systems/core
intelligence sync
```

That's the whole setup. Your project gets:

```
intelligence.yaml      # manifest — what the project consumes, where it goes
intelligence.lock      # resolved versions (commit it)
intelligence/          # your own rules / agents / skills
.intelligence/         # installed packages + engine content (gitignored)
.claude/ .cursor/ …    # generated per-tool output
AGENTS.md
```

Teammates need one command after cloning:

```bash
intelligence install
```

## Commands

| Command | What it does |
|---|---|
| `intelligence init` | Detect your tools, write the manifest, first sync |
| `intelligence add <pkg>` | `@scope/name[@range]`, `github:org/repo[#path]`, or `git+<url>[@ref][#path]` |
| `intelligence install [--frozen]` | Restore `.intelligence/` exactly from the lockfile |
| `intelligence update [pkg]` | Re-resolve version ranges, rewrite the lock |
| `intelligence sync [target]` | Render intelligence to every enabled tool |
| `intelligence list` / `doctor` / `status` | Inspect and verify |
| `intelligence registry add <repo-url>` | Trust a registry (a git repo with an `index.yaml`) |
| `intelligence migrate` | Convert a vendored intelligence-sync setup to the CLI |

Any git repo with `rules/`, `agents/` or `skills/` at its root is already an Intelligence Package: install it from an explicit source — `intelligence add github:your-org/your-repo` — with versions from its `x.y.z` git tags. Names (`@scope/name`) resolve only through registries this project explicitly trusts; a monorepo of packages needs one line in such an index.

Requires `git` (and on Windows the bash it ships with — Git for Windows). Engine and docs: [ainova-systems/intelligence-sync](https://github.com/ainova-systems/intelligence-sync).
