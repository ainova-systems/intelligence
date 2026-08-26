#!/bin/bash
# intelligence init [--targets a,b,c] [--dir name] [--bare] [--no-sync]
#                   [--preview | --apply] [--force]
#
# Set up a project: root manifest, content skeleton, .gitignore, staged
# engine content, first sync. Targets are detected from IDE markers unless
# named explicitly. Only `agents` is unconditional: AGENTS.md is the
# tool-neutral carrier of always-on rules; tool targets come from markers or
# --targets.
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

targets_arg="" no_sync=0 content_dir="intelligence" bare=0
targets_set=0 dir_set=0 bare_set=0 preview=0 apply=0 force=0
while [ $# -gt 0 ]; do
    case "$1" in
        --targets) shift; targets_arg="${1:-}"; targets_set=1 ;;
        --dir) shift; content_dir="${1:-}"; dir_set=1 ;;
        --no-sync) no_sync=1 ;;
        --bare) bare=1; bare_set=1 ;;
        --preview) preview=1 ;;
        --apply) apply=1 ;;
        --force) force=1 ;;
        *) die "unknown option '$1'" ;;
    esac
    shift || true
done
[ "$preview" -eq 0 ] || [ "$apply" -eq 0 ] || die "choose either --preview or --apply"
[ "$targets_set" -eq 0 ] || [ -n "$targets_arg" ] || die "--targets needs a comma-separated adapter list"
[ -n "$content_dir" ] || die "--dir needs a directory name"
case "$content_dir" in
    /*|*..*|.intelligence|.intelligence/*) die "--dir must be a plain directory inside the repo, and not the package store" ;;
esac

detect_project
case "$IP_MODE" in
    v2)
        [ "$targets_set" -eq 0 ] || die "--targets applies only when creating a new project"
        [ "$dir_set" -eq 0 ] || die "--dir applies only when creating a new project"
        [ "$bare_set" -eq 0 ] || die "--bare applies only when creating a new project"
        [ "$force" -eq 0 ] || die "--force applies only when converting an archived v1 project"
        if [ "$preview" -eq 1 ]; then
            check_version_compat "$IP_ROOT/intelligence.yaml"
            echo "project: v2 at $IP_ROOT"
            if project_needs_upgrade "$IP_ROOT"; then
                echo "  would align project lifecycle with engine $(bundled_engine_version)"
            else
                echo "  schema/content already match engine $(bundled_engine_version)"
            fi
            if project_store_missing "$IP_ROOT"; then
                echo "  would restore .intelligence/ from intelligence.lock"
            else
                echo "  package store already present"
            fi
            echo "  would run intelligence sync"
            exit 0
        fi
        ensure_project_current "$IP_ROOT"
        restore_project_store_if_missing "$IP_ROOT"
        [ "$no_sync" -eq 1 ] && exit 0
        cd "$IP_ROOT"
        exec bash "$CLI_DIR/commands/sync.sh"
        ;;
    legacy)
        [ "$targets_set" -eq 0 ] || die "--targets applies only when creating a new project"
        [ "$dir_set" -eq 0 ] || die "--dir applies only when creating a new project"
        [ "$bare_set" -eq 0 ] || die "--bare applies only when creating a new project"
        [ "$no_sync" -eq 0 ] || die "--no-sync cannot skip transactional conversion verification"
        migrate_args=()
        [ "$force" -eq 1 ] && migrate_args+=(--force)
        if [ "$preview" -eq 1 ]; then
            exec bash "$CLI_DIR/internal/migrate-v1.sh" --dry-run ${migrate_args[@]+"${migrate_args[@]}"}
        fi
        if [ "$apply" -eq 1 ]; then
            exec bash "$CLI_DIR/internal/migrate-v1.sh" ${migrate_args[@]+"${migrate_args[@]}"}
        fi
        bash "$CLI_DIR/internal/migrate-v1.sh" --dry-run ${migrate_args[@]+"${migrate_args[@]}"}
        [ -t 0 ] || die "v1 migration requires confirmation — rerun 'intelligence init --apply'"
        printf 'Apply this migration? [Y/n] '
        read -r answer
        case "$answer" in
            ""|y|Y|yes|YES) exec bash "$CLI_DIR/internal/migrate-v1.sh" ${migrate_args[@]+"${migrate_args[@]}"} ;;
            *) echo "migration cancelled"; exit 0 ;;
        esac
        ;;
esac

[ "$force" -eq 0 ] || die "--force applies only when converting an archived v1 project"
root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
root="$(cd "$root" && pwd)"

# Never invent a tool the project shows no trace of: every per-tool target is
# DETECTED from repo markers or named explicitly via --targets. Only `agents`
# (AGENTS.md, the tool-neutral standard every AGENTS-reading tool shares, and
# the invariant-required carrier once any of them is on) is unconditional.
targets="agents"
if [ -n "$targets_arg" ]; then
    for target in $(printf '%s' "$targets_arg" | tr ',' ' '); do
        assert_valid_target_name "$target"
        if [ ! -f "$IS_ENGINE_DIR/adapters/$target.sh" ] \
            && [ ! -f "$root/$content_dir/adapters/$target.sh" ]; then
            die "adapter '$target' not found — create it after init with: intelligence adapter create $target"
        fi
        case " $targets " in *" $target "*) ;; *) targets="$targets $target" ;; esac
    done
else
    if [ -d "$root/.claude" ] || [ -f "$root/CLAUDE.md" ]; then targets="$targets claude"; fi
    [ -d "$root/.cursor" ] && targets="$targets cursor"
    [ -d "$root/.codex" ] && targets="$targets codex"
    [ -d "$root/.pi" ] && targets="$targets pi"
    [ -d "$root/.opencode" ] && targets="$targets opencode"
    [ -d "$root/.github" ] && [ -d "$root/.github/instructions" ] && targets="$targets copilot"
    if [ "$targets" = "agents" ]; then
        echo "  NOTE: no tool markers found (.claude/, CLAUDE.md, .cursor/, …) — only AGENTS.md is enabled." >&2
        echo "        Name your tools explicitly: intelligence init --targets claude,cursor  (or edit targets: later)" >&2
    fi
fi

if [ "$preview" -eq 1 ]; then
    echo "project: no Intelligence setup found"
    echo "  would create intelligence.yaml and intelligence.lock"
    echo "  would install the bundled sync-content package"
    echo "  would enable adapters:$targets, then sync"
    exit 0
fi

manifest="$root/intelligence.yaml"
{
    echo "# Intelligence manifest — what this project's AI tooling knows and where it goes."
    echo "# Managed by the intelligence CLI. Reference: https://github.com/ainova-systems/intelligence"
    echo "project:"
    echo "  name: \"$(basename "$root")\""
    [ "$content_dir" = "intelligence" ] || echo "  intelligence_dir: \"$content_dir\""
    echo ""
    echo "# Schema version of this manifest. The CLI keeps it in step with its engine."
    echo "schema_version: \"$(bundled_engine_version)\""
    echo ""
    echo "# Where content comes from. Nothing here has to exist: a directory that is"
    echo "# absent is skipped, so a project consuming only packages authors nothing of"
    echo "# its own. To write your own, create the directory and sync — no config edit:"
    echo "#   $content_dir/rules/context.md      an always-on rule; describe the project,"
    echo "#                                      its stack, and the constraints to respect"
    echo "#   $content_dir/agents/<name>.md      a persona (frontmatter: name, description,"
    echo "#                                      tier: heavy|standard|light, access: full|readonly)"
    echo "#   $content_dir/skills/<name>/SKILL.md  a procedure invoked as /<name>"
    echo "# '.intelligence/' is CLI-managed (packages + engine content) — never edit it."
    echo "sources:"
    echo "  rules:"
    echo "    - \"$content_dir/rules\""
    echo "  agents:"
    echo "    - \"$content_dir/agents\""
    echo "  skills:"
    echo "    - \"$content_dir/skills\""
    echo ""
    echo "# Generated output, one entry per tool. Add or drop tools freely."
    echo "targets:"
    for t in $targets; do
        echo "  $t: { enabled: true, output: \"$(default_target_output "$t")\" }"
    done
    echo ""
    echo "# Packages are managed with 'intelligence package add|search|list':"
    echo "#   intelligence package add @ainova-systems/core       from the registry"
    echo "#   intelligence package add github:org/repo            any repo with rules|agents|skills"
    echo "# packages:"
    echo "#   \"@ainova-systems/core\":"
    echo "#     version: \"^0.3.0\""
    echo ""
    echo "# Registries are this project's TRUST LIST — the ONLY way a package name"
    echo "# resolves (there is no built-in catalog and no name->github guessing;"
    echo "# registry-less installs are always explicit: github:org/repo, git+<url>)."
    echo "# Git repos holding an index.yaml, consulted in order; first to declare a"
    echo "# name wins; sources are then pinned by url+sha in intelligence.lock."
    echo "# Managed with 'intelligence registry add|remove'. Delete a line to"
    echo "# distrust that catalog — including the default seeded below."
    if [ "$bare" -eq 1 ] || [ -z "$DEFAULT_REGISTRY_URL" ]; then
        echo "# registries:"
        echo "#   - \"https://github.com/acme/intelligence-registry.git\""
    else
        echo "registries:"
        echo "  - \"$DEFAULT_REGISTRY_URL\""
    fi
} > "$manifest"

# The package store is restorable state, never committed — the npm model.
if [ ! -f "$root/.gitignore" ] || ! grep -q '^\.intelligence/' "$root/.gitignore"; then
    {
        [ -f "$root/.gitignore" ] && [ -n "$(tail -c 1 "$root/.gitignore" 2>/dev/null)" ] && echo ""
        echo "# intelligence CLI package store (restored automatically by 'intelligence sync')"
        echo ".intelligence/"
    } >> "$root/.gitignore"
fi

# The engine's own content (meta-skills, authoring rule, engine agents) is an
# ordinary package: auto-selected, opted out with --bare, removable later with
# 'intelligence package remove @ainova-systems/sync --force'.
if [ "$bare" -eq 0 ]; then
    sync_pkg_entry "$manifest"
    sync_pkg_install "$root"
fi

echo "initialized: intelligence.yaml (targets:$(printf ' %s' $targets))"
[ "$bare" -eq 1 ] && echo "  bare setup: no packages — engine meta-skills not installed"
echo "  add packages:  intelligence package add @ainova-systems/core   (browse: intelligence package search)"
echo "  write your own: create $content_dir/rules/context.md, then intelligence sync"
echo "  docs: https://github.com/ainova-systems/intelligence#readme"

if [ "$no_sync" -eq 0 ]; then
    cd "$root"
    exec bash "$CLI_DIR/commands/sync.sh"
fi
