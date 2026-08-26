# Writing an Intelligence Adapter

An adapter transforms tool-neutral rules, agents and skills into one tool's native files. The sync engine discovers adapters by filename and calls one shell function for each enabled target.

## Built-in and project adapters

| Location | Owner | Upgrade behavior |
|---|---|---|
| Installed CLI's `engine/adapters/` | Intelligence | Replaced when the CLI is upgraded |
| `<content-dir>/adapters/` | Project | Never changed by CLI upgrades |

The default content directory is `intelligence/`; `project.intelligence_dir` in `intelligence.yaml` may choose another. A project adapter with the same name as a built-in overrides it, and sync reports the override.

Contribute broadly useful integrations as built-ins. Keep organization-specific or experimental formats in the project.

## Create and enable an adapter

Choose a lowercase shell-safe name matching `[a-z][a-z0-9_]*`, then scaffold from the template bundled with the installed engine:

```bash
intelligence adapter create mytool
```

This creates `<content-dir>/adapters/mytool.sh` and refuses to overwrite an existing file. Implement the generated functions, then enable its target:

```bash
intelligence adapter enable mytool
```

`adapter enable` adds or updates this manifest entry when the adapter exists, then runs a full sync so shared outputs such as `AGENTS.md` remain current:

```yaml
targets:
  mytool: { enabled: true, output: ".mytool" }
```

Change `output` in `intelligence.yaml` if the tool expects another location. The engine validates the resolved path before calling the adapter.

To stop syncing a target:

```bash
intelligence adapter disable mytool
```

Disabling changes only target state. Generated output is deliberately kept because a generic command cannot know which paths a custom adapter owns. Remove only documented owned paths after reviewing them. A disabled project adapter can be deleted with `intelligence adapter remove mytool`; removal prompts by default, accepts `--apply` for explicit non-interactive use, and also keeps generated output. Built-in adapter source cannot be removed. Use `intelligence adapter list` to inspect source, state and output.

## Required function

The file name and function name form the adapter's identity:

```bash
# <content-dir>/adapters/mytool.sh
sync_to_mytool() {
    local repo_root="$1"
    local config_file="$2"
    local output_dir="$3"

    # transform sources into output_dir
}
```

The engine calls:

```text
sync_to_<name> <repo-root> <absolute-intelligence.yaml> <absolute-output-path>
```

The engine has already loaded `engine/lib/common.sh` before it sources the adapter, so project adapters use its functions directly.

## Source model

`sources.rules`, `sources.agents` and `sources.skills` contain repo-relative directory paths. Packages have already been resolved, fetched and pinned by the CLI, so package content appears as an ordinary path under `.intelligence/packages/`. Adapters never perform network access or parse `packages:`.

Iterate a source section in manifest order:

```bash
while IFS= read -r src; do
    [ -n "$src" ] || continue
    dir="$(resolve_source_dir "$repo_root" "$src")"
    [ -d "$dir" ] || continue

    for file in "$dir"/*.md; do
        [ -f "$file" ] || continue
        # transform file
    done
done < <(read_yaml_list "$config_file" "rules")
```

Later sources intentionally overwrite same-named artifacts from earlier sources. Package sources are wired before project sources, so project content can override a package artifact by name.

## Shared functions

Use the engine library instead of copying parsers or file-handling logic.

| Function | Purpose |
|---|---|
| `resolve_source_dir(repo_root, source)` | Resolve a manifest source to its local directory. |
| `read_yaml_list(config, section)` | Stream entries from `sources.<section>`. |
| `get_frontmatter_value(key, file)` | Read a scalar from the first frontmatter block. |
| `has_frontmatter(file)` / `has_paths(file)` | Inspect source shape. |
| `strip_frontmatter(file)` | Emit the body without its first frontmatter block. |
| `get_model(config, tool, tier)` | Resolve a `heavy`, `standard` or `light` model, including manifest overrides. |
| `get_model_default(tool, tier)` | Read the built-in model default. |
| `copy_skill_bundle(src, dest)` | Copy `SKILL.md` and all resources safely, normalize Markdown and quote free-text frontmatter. |
| `sync_open_skill_dirs(root, config, dest)` | Own and populate a shared Agent Skills directory such as `.agents/skills/`. |
| `finalize_output_file(file)` | Expand layout tokens and normalize line endings; required for every emitted text file. |
| `get_target_field(config, target, field)` | Read another field from the target configuration. |
| `repo_rel_link(root, path)` | Produce a stable repo-relative link for a committed output. |

`lint_frontmatter` is run across all inputs by the engine before adapters execute. It warns about common YAML hazards; adapters should not duplicate that pass.

## Rules, skills and agents

### Rules

Rules without `paths:` are always-on. Rules with `paths:` are scoped.

Intelligence routes always-on rules once through `AGENTS.md` for tools that consume it. An adapter for such a tool should not copy those rules again. If the tool has a native scoped-rule channel, transform `paths:` to the tool's equivalent.

| Built-in | Always-on rules | Scoped rules |
|---|---|---|
| `agents` | Inline in `AGENTS.md` | List with links |
| `claude` | Copy | Copy with `paths:` preserved |
| `cursor` | Omit; reads `AGENTS.md` | `.mdc` with `globs:` |
| `copilot` | Omit; reads `AGENTS.md` | `.instructions.md` with `applyTo:` |
| `codex` | Omit; reads `AGENTS.md` | No native channel |
| `pi` | Omit; reads `AGENTS.md` | Generated on-demand files and extension |
| `opencode` | Omit; reads `AGENTS.md` | No native channel |

If a new adapter relies on `AGENTS.md` for always-on rules, its target must require `agents`. Add that invariant to `engine/sync.sh` when contributing the adapter upstream.

### Skills

Skills follow the [Agent Skills standard](https://agentskills.io). Copy each skill directory as a complete bundle—not only `SKILL.md`—because its body may reference `references/`, `scripts/` or `assets/` beside it.

```bash
copy_skill_bundle "$source_skill_dir" "$output_dir/skills/$skill_name"
```

Do not use plain `cp` for skill bundles. `copy_skill_bundle` preserves non-Markdown assets, avoids materializing symlink targets, normalizes Markdown, expands layout tokens and quotes `description` and `argument-hint` where strict YAML readers require strings.

Codex, Pi and OpenCode share `.agents/skills/`. Any adapter writing that open-standard directory must call `sync_open_skill_dirs`; it is the single lifecycle owner for immediate skill subdirectories.

### Agents

Source agents use tool-neutral fields:

```yaml
---
name: backend-developer
description: "Implements backend features"
tier: heavy
access: full
---
```

Map `tier` through `get_model`, not a hardcoded model name. Transform `access: full|readonly` into the target tool's native permission model. Preserve the body as the agent's instructions.

Built-ins currently emit Claude and Cursor Markdown, Copilot `.agent.md`, Codex TOML, Pi prompt templates and OpenCode Markdown subagents. Read the closest built-in adapter before implementing a new transformation.

## Layout tokens

Content shipped in `@ainova-systems/sync` cannot assume the project's content-directory name or package-store location. It uses these tokens:

| Token | v2 expansion |
|---|---|
| `<content-dir>` | Project content directory, usually `intelligence` |
| `<module>` | Installed sync package, usually `.intelligence/packages/@ainova-systems/sync` |
| `<manifest>` | `intelligence.yaml` |
| `<sync-cmd>` | `intelligence sync` |

Call `finalize_output_file` on every text file after transformation. It expands the tokens literally and converts CRLF to LF. A generated file containing an unexpanded token is an adapter bug.

`copy_skill_bundle` already finalizes Markdown within a skill; do not run a second custom token pass.

## Cleanup and safety contract

Adapters regenerate output, so cleanup is part of their public contract.

1. Delete only paths the adapter owns. Preserve sibling settings, commands, extensions, workflows and hand-authored files.
2. Make ownership obvious in `sync_to_<name>()`; the same list is what a user removes after disabling or uninstalling the adapter.
3. Use marker-based cleanup when generated and hand-authored files share a directory. The OpenCode adapter is the reference implementation.
4. Use `sync_open_skill_dirs` for `.agents/skills/`; multiple adapters share it.
5. Write only beneath the supplied `output_dir`, except for an explicitly shared standard path handled by a shared helper.
6. Make repeated syncs idempotent.

Before an adapter runs, the engine canonicalizes and validates its configured output. It refuses the repository root, paths outside the repository, symlink escapes, the project content directory, `.intelligence/` and configured source paths. This guard does not make broad cleanup safe: an adapter must still avoid deleting unrelated files within a valid tool directory.

## Minimal example

This example copies rules without frontmatter. A real adapter must decide how the target represents scoping and should also implement agents and skills.

```bash
#!/bin/bash

sync_mytool_rules() {
    local repo_root="$1" config_file="$2" output_dir="$3"
    mkdir -p "$output_dir/rules"

    while IFS= read -r src; do
        [ -n "$src" ] || continue
        local dir
        dir="$(resolve_source_dir "$repo_root" "$src")"
        [ -d "$dir" ] || continue

        for file in "$dir"/*.md; do
            [ -f "$file" ] || continue
            strip_frontmatter "$file" > "$output_dir/rules/$(basename "$file")"
            finalize_output_file "$output_dir/rules/$(basename "$file")"
        done
    done < <(read_yaml_list "$config_file" "rules")
}

sync_to_mytool() {
    local repo_root="$1" config_file="$2" output_dir="$3"

    rm -rf "$output_dir/rules"
    sync_mytool_rules "$repo_root" "$config_file" "$output_dir"
}
```

## Testing

Use a disposable Git repository with a v2 manifest and representative always-on/scoped rules, agents, skills and bundled skill resources.

```bash
intelligence sync mytool
```

Verify:

- native file names, frontmatter and model/permission mappings;
- scoped and always-on routing without duplicated context;
- skill resources are present;
- no literal layout tokens remain;
- hand-authored siblings under the tool root survive;
- output paths cannot overlap sources or escape the repository;
- a second sync produces no Git diff.

For a built-in adapter, add the same assertions to the repository's smoke or lifecycle tests and run all five CLI suites before submitting the change.

## Built-in outputs

| Adapter | Primary output |
|---|---|
| `agents` | `AGENTS.md` |
| `claude` | `.claude/rules`, `.claude/agents`, `.claude/skills` |
| `cursor` | `.cursor/rules`, `.cursor/agents`, `.cursor/skills` |
| `copilot` | `.github/instructions`, `.github/agents`, `.github/skills` |
| `codex` | `.codex/agents`, `.agents/skills` |
| `pi` | `.pi/intelligence-sync`, `.pi/extensions`, `.pi/prompts`, `.agents/skills` |
| `opencode` | `.opencode/agents`, marker-owned `.opencode/commands`, `.agents/skills` |
