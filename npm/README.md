# @ainova-systems/intelligence

**npm for AI agent intelligence.** One CLI that builds, versions and distributes the rules, agents and skills your AI coding tools run on — rendered natively for Claude Code, Cursor, GitHub Copilot, OpenAI Codex, Pi, OpenCode and `AGENTS.md`.

```bash
npm install -g @ainova-systems/intelligence

cd your-project
intelligence init
intelligence package add @ainova-systems/core
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

Teammates need one command after cloning; it restores the locked package store before rendering:

```bash
intelligence sync
```

## Commands

| Command | What it does |
|---|---|
| `intelligence init [--preview\|--apply]` | Create, convert, restore or align a project |
| `intelligence sync [adapter]` | Restore locked content if needed, then render enabled adapters |
| `intelligence update [@scope/name] [--preview\|--apply]` | Plan or apply project and ranged-package updates |
| `intelligence package add\|remove\|list\|search` | Manage versioned Intelligence Packages |
| `intelligence adapter list\|create\|enable\|disable\|remove` | Manage render adapters |
| `intelligence status [--check]` | Inspect project state and consistency |
| `intelligence registry list\|add\|remove` | Manage trusted registry repositories |

Any git repo with `rules/`, `agents/` or `skills/` at its root is already an Intelligence Package: install it from an explicit source — `intelligence package add github:your-org/your-repo` — with versions from its `x.y.z` git tags. Names (`@scope/name`) resolve only through registries this project explicitly trusts; a monorepo of packages needs one line in such an index.

Requires `git` (and on Windows the bash it ships with — Git for Windows). Engine and docs: [ainova-systems/intelligence](https://github.com/ainova-systems/intelligence).
