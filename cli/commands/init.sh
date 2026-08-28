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
onboarding_tx_active=0 onboarding_tx_root="" onboarding_tx_content=""

onboarding_transaction_exit() {
    local rc=$?
    trap - EXIT
    if [ "$onboarding_tx_active" -eq 1 ]; then
        restore_onboarding_legacy_sources "$onboarding_tx_root" "$onboarding_tx_content" || true
    fi
    exit "$rc"
}

onboarding_transaction_begin() {
    local tx_root="$1" tx_content="$2"
    onboarding_quarantine_is_pending "$tx_root" "$tx_content" || return 0
    onboarding_tx_root="$tx_root"
    onboarding_tx_content="$tx_content"
    onboarding_tx_active=1
    trap onboarding_transaction_exit EXIT
    quarantine_onboarding_legacy_sources "$tx_root" "$tx_content"
}

onboarding_transaction_rollback() {
    trap - EXIT
    if [ "$onboarding_tx_active" -eq 1 ]; then
        restore_onboarding_legacy_sources "$onboarding_tx_root" "$onboarding_tx_content"
    fi
    onboarding_tx_active=0
}

onboarding_transaction_commit() {
    local tx_root="$1" tx_content="$2"
    complete_onboarding_quarantine "$tx_root" "$tx_content"
    onboarding_tx_active=0
    trap - EXIT
}

print_new_project_onboarding() {
    local heading="Intelligence ready"
    [ "$no_sync" -eq 0 ] || heading="Next steps"

    echo ""
    echo "=== $heading ==="
    if [ -n "${ONBOARDING_BACKUP_REL:-}" ]; then
        echo "  Existing AI instructions preserved:"
        echo "    $ONBOARDING_BACKUP_REL ($ONBOARDING_BACKUP_COUNT path(s))"
        echo "    Legacy root entry points were quarantined before the successful render."
        if [ "$bare" -eq 0 ]; then
            echo "    The learn skill will migrate them before proposing backup removal."
        else
            echo "    Review and migrate them before removing this backup."
        fi
    fi
    if [ "$no_sync" -eq 1 ]; then
        echo "  Run first:"
        echo "    intelligence sync"
    fi
    if [ "$bare" -eq 0 ]; then
        echo "  Recommended starter package:"
        echo "    intelligence package add @ainova-systems/core"
        echo "    Install it before learning so package/project duplicates can be detected."
        echo "  Finalize repository onboarding:"
        echo "    Ask your agent to run /intelligence-learn-from-repository"
        echo "    It recognizes the initial backup, recovers setup if needed, then proposes repository-specific migration after approval."
    fi
    echo "  Review adapters:"
    echo "    intelligence adapter list"
    echo "    intelligence adapter enable codex"
    echo "    intelligence adapter disable cursor"
    echo "  Version control:"
    echo "    Generated adapter output is gitignored by CLI-owned path."
    echo "    Commit intelligence.yaml, intelligence.lock, intelligence/, AGENTS.md, and .github/."
    echo "    Existing .vscodeignore, .npmignore, and .dockerignore files receive packaging exclusions."
    echo "    Shared tool settings remain trackable; review the exact ownership policy:"
    echo "    https://github.com/ainova-systems/intelligence/blob/main/packages/sync/references/conventions.md#generated-output-and-version-control"
    report_tracked_managed_ignores "$root" "$manifest"
    echo "  Write your own:"
    echo "    create $content_dir/rules/context.md, then intelligence sync"
    echo "  Docs: https://github.com/ainova-systems/intelligence#readme"
}

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
    cli)
        [ "$targets_set" -eq 0 ] || die "--targets applies only when creating a new project"
        [ "$dir_set" -eq 0 ] || die "--dir applies only when creating a new project"
        [ "$bare_set" -eq 0 ] || die "--bare applies only when creating a new project"
        [ "$force" -eq 0 ] || die "--force applies only when converting a legacy Intelligence Sync project"
        if [ "$preview" -eq 1 ]; then
            check_version_compat "$IP_ROOT/intelligence.yaml"
            echo "project: Intelligence CLI at $IP_ROOT"
            if project_needs_upgrade "$IP_ROOT"; then
                echo "  would align project lifecycle with engine $(bundled_engine_version)"
            else
                echo "  schema/content already match engine $(bundled_engine_version)"
            fi
            if project_has_packages "$IP_ROOT" && [ ! -f "$IP_ROOT/intelligence.lock" ]; then
                die "manifest declares packages but intelligence.lock is absent — restore the committed lock before applying"
            fi
            if project_store_missing "$IP_ROOT"; then
                echo "  would restore .intelligence/ from intelligence.lock"
            else
                echo "  package store already present"
            fi
            if [ "$no_sync" -eq 1 ]; then
                echo "  would stop before intelligence sync"
            else
                echo "  would run intelligence sync"
            fi
            exit 0
        fi
        if [ "$apply" -eq 1 ]; then
            ensure_project_current "$IP_ROOT" --explicit
        else
            ensure_project_current "$IP_ROOT"
        fi
        restore_project_store_if_missing "$IP_ROOT"
        ensure_manifest_gitignore "$IP_ROOT" "$IP_ROOT/intelligence.yaml"
        ensure_manifest_publisher_ignores "$IP_ROOT" "$IP_ROOT/intelligence.yaml"
        [ "$no_sync" -eq 1 ] && exit 0
        content_dir="$(manifest_intelligence_dir "$IP_ROOT/intelligence.yaml")"
        onboarding_transaction_begin "$IP_ROOT" "$content_dir"
        cd "$IP_ROOT"
        sync_rc=0
        bash "$CLI_DIR/commands/sync.sh" || sync_rc=$?
        if [ "$sync_rc" -ne 0 ]; then
            onboarding_transaction_rollback
            recovery_backup=""
            if [ -f "$IP_ROOT/$content_dir/_backup/manifest.tsv" ]; then
                recovery_backup="; initial backup: $content_dir/_backup/manifest.tsv"
            fi
            echo "" >&2
            echo "=== Intelligence setup needs recovery ===" >&2
            echo "  No partial adapter update was kept; sync restored its pre-run outputs." >&2
            echo "  Ask your agent to read:" >&2
            echo "    $SYNC_PKG_STORE/skills/intelligence-learn-from-repository/SKILL.md" >&2
            echo "  and finalize this Intelligence setup$recovery_backup." >&2
        fi
        [ "$sync_rc" -ne 0 ] || onboarding_transaction_commit "$IP_ROOT" "$content_dir"
        [ "$sync_rc" -ne 0 ] || report_tracked_managed_ignores "$IP_ROOT" "$IP_ROOT/intelligence.yaml"
        exit "$sync_rc"
        ;;
    legacy)
        [ "$targets_set" -eq 0 ] || die "--targets applies only when creating a new project"
        [ "$dir_set" -eq 0 ] || die "--dir applies only when creating a new project"
        [ "$bare_set" -eq 0 ] || die "--bare applies only when creating a new project"
        [ "$no_sync" -eq 0 ] || die "--no-sync cannot skip transactional conversion verification"
        conversion_args=()
        [ "$force" -eq 1 ] && conversion_args+=(--force)
        if [ "$preview" -eq 1 ]; then
            exec bash "$CLI_DIR/internal/convert-legacy.sh" --dry-run ${conversion_args[@]+"${conversion_args[@]}"}
        fi
        if [ "$apply" -eq 1 ]; then
            exec bash "$CLI_DIR/internal/convert-legacy.sh" ${conversion_args[@]+"${conversion_args[@]}"}
        fi
        bash "$CLI_DIR/internal/convert-legacy.sh" --dry-run ${conversion_args[@]+"${conversion_args[@]}"}
        [ -t 0 ] || die "legacy project conversion requires confirmation — rerun 'intelligence init --apply'"
        printf 'Apply this conversion? [Y/n] '
        read -r answer
        case "$answer" in
            ""|y|Y|yes|YES) exec bash "$CLI_DIR/internal/convert-legacy.sh" ${conversion_args[@]+"${conversion_args[@]}"} ;;
            *) echo "conversion cancelled"; exit 0 ;;
        esac
        ;;
esac

[ "$force" -eq 0 ] || die "--force applies only when converting a legacy Intelligence Sync project"
root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
root="$(cd "$root" && pwd)"
assert_safe_content_dir "$root" "$content_dir"

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
    if [ -d "$root/.cursor" ] || [ -f "$root/.cursorrules" ]; then targets="$targets cursor"; fi
    if [ -d "$root/.codex" ] || [ -d "$root/.agents" ]; then targets="$targets codex"; fi
    [ -d "$root/.pi" ] && targets="$targets pi"
    [ -d "$root/.opencode" ] && targets="$targets opencode"
    if [ -f "$root/.github/copilot-instructions.md" ] \
        || [ -d "$root/.github/instructions" ] \
        || [ -d "$root/.github/agents" ] \
        || [ -d "$root/.github/skills" ]; then
        targets="$targets copilot"
    fi
    if [ "$targets" = "agents" ]; then
        echo "  NOTE: no tool markers found (.claude/, CLAUDE.md, .cursor/, …) — only AGENTS.md is enabled." >&2
        echo "        Name your tools explicitly: intelligence init --targets claude,cursor  (or edit targets: later)" >&2
    fi
fi

onboarding_count="$(onboarding_source_count "$root" "$content_dir" "$targets")"
onboarding_has_agents=0
[ -f "$root/AGENTS.md" ] && onboarding_has_agents=1
if [ "$preview" -eq 0 ] && [ "$onboarding_count" -gt 0 ] \
    && [ -e "$root/$content_dir/_backup" ]; then
    die "onboarding backup already exists at $content_dir/_backup - review or move it before rerunning init"
fi

if [ "$preview" -eq 1 ]; then
    echo "project: no Intelligence setup found"
    echo "  would create intelligence.yaml and intelligence.lock"
    if [ "$bare" -eq 1 ]; then
        echo "  would omit the bundled sync-content package (--bare)"
    else
        echo "  would install the bundled sync-content package"
    fi
    if [ "$no_sync" -eq 1 ]; then
        echo "  would enable adapters:$targets and stop before sync"
    else
        echo "  would enable adapters:$targets, then sync"
    fi
    if [ "$onboarding_count" -gt 0 ]; then
        echo "  would preserve $onboarding_count existing AI instruction path(s) in $content_dir/_backup before sync"
    fi
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
        if [ "$t" = "agents" ] && [ "$onboarding_has_agents" -eq 1 ]; then
            echo "  agents:"
            echo "    enabled: true"
            echo "    output: \"AGENTS.md\""
            echo "    header: |"
            echo "      > Intelligence onboarding is pending. Before repository work, read"
            echo "      > \`$content_dir/_backup/AGENTS.md\`, which preserves the original project instructions."
            if [ "$bare" -eq 0 ]; then
                echo "      > Run /intelligence-learn-from-repository to migrate and verify them before removing the backup."
            else
                echo "      > Review and migrate that backup before removing it."
            fi
        else
            echo "  $t: { enabled: true, output: \"$(default_target_output "$t")\" }"
        fi
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
ensure_base_gitignore "$root"
for target in $targets; do
    ensure_target_gitignore "$root" "$manifest" "$target"
done

# The engine's own content (meta-skills, authoring rule, engine agents) is an
# ordinary package: auto-selected, opted out with --bare, removable later with
# 'intelligence package remove @ainova-systems/sync --force'.
if [ "$bare" -eq 0 ]; then
    sync_pkg_entry "$manifest"
    sync_pkg_install "$root"
fi

preserve_onboarding_sources "$root" "$content_dir" "$targets"
ensure_manifest_publisher_ignores "$root" "$manifest"

echo "initialized: intelligence.yaml (targets:$(printf ' %s' $targets))"
[ "$bare" -eq 1 ] && echo "  bare setup: no packages — engine meta-skills not installed"
if [ "$no_sync" -eq 0 ]; then
    onboarding_transaction_begin "$root" "$content_dir"
    cd "$root"
    sync_rc=0
    echo ""
    echo "=== Sync started ==="
    echo "  Rendering enabled adapters in compact mode..."
    bash "$CLI_DIR/commands/sync.sh" --compact || sync_rc=$?
    if [ "$sync_rc" -ne 0 ]; then
        onboarding_transaction_rollback
        echo "" >&2
        echo "=== Intelligence setup needs recovery ===" >&2
        echo "  No partial adapter update was kept; sync restored its pre-run outputs." >&2
        if [ "$bare" -eq 0 ]; then
            echo "  Ask your agent to read:" >&2
            echo "    $SYNC_PKG_STORE/skills/intelligence-learn-from-repository/SKILL.md" >&2
            echo "  and finalize the initial Intelligence setup. The snapshot is $content_dir/_backup/manifest.tsv." >&2
        else
            echo "  Fix the reported error, then rerun: intelligence init" >&2
        fi
        exit "$sync_rc"
    fi
    onboarding_transaction_commit "$root" "$content_dir"
    echo "=== Sync completed ==="
fi

print_new_project_onboarding
