---
name: intelligence-install-adapter
description: "Enable IDE adapter for intelligence-sync"
argument-hint: <target-name>
agent: intelligence-operator
---

# Install Adapter

The project's config is `<manifest>`; the content dir is `<umbrella>/` (never assume the name or casing); the engine's own files live under `<module>/` — these paths are localized to this project at sync time.

## Steps

1. Check whether target `$ARGUMENTS` is already enabled in `<manifest>` — if yes, report and stop.

2. **Locate the adapter.** The sync discovers adapters in two places:
   - **Built-in**: `<module>/scripts/adapters/$ARGUMENTS.sh` — upstream-owned. Every engine update replaces that whole directory.
   - **Project-owned**: `<umbrella>/adapters/$ARGUMENTS.sh` — updates never touch it. A project adapter of the same name overrides the built-in.

   If neither exists, research the tool's prompt format (web search for its rules / agents / skills file layout), then copy `<module>/scripts/adapters/_template.sh` to **`<umbrella>/adapters/$ARGUMENTS.sh`** and implement `sync_to_$ARGUMENTS()`. Author it there, never inside the engine's `scripts/adapters/` — a file written there is deleted by the next engine update. Adapter contract: `<module>/docs/ADAPTERS.md`. An adapter that would serve every project is worth contributing upstream.

3. Update `<manifest>`:
   - Target exists with `enabled: false` → flip to `enabled: true`.
   - Target missing → add it under `targets:` with its `output:` path.
   - If the target reads always-on rules from `AGENTS.md` (`cursor`, `copilot`, `codex`, `pi`, `opencode`), `targets.agents` must be enabled too — sync fails closed otherwise.

4. Add the adapter's generated paths to `.gitignore` (the paths it writes, not the whole output root — a shared root like `.github/` or `.claude/` also holds tracked, hand-authored files).

5. Run `/intelligence-sync` to generate the output.

6. Report: adapter enabled, files generated, output location.
