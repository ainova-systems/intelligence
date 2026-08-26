#!/bin/bash
# intelligence target enable|disable <name>
#
# Change only the manifest. Syncing and deleting generated output are separate
# explicit actions: a generic target command cannot infer a custom adapter's
# ownership safely.
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

action="${1:-}"
name="${2:-}"
[ $# -le 2 ] || die "usage: intelligence target <enable|disable> <name>"
case "$action" in enable|disable) ;; *) die "usage: intelligence target <enable|disable> <name>" ;; esac
[ -n "$name" ] || die "usage: intelligence target <enable|disable> <name>"
assert_valid_target_name "$name"

require_v2
manifest="$IP_ROOT/intelligence.yaml"
content_dir="$(manifest_intelligence_dir "$manifest")"

if [ "$action" = "enable" ]; then
    project_adapter="$IP_ROOT/$content_dir/adapters/$name.sh"
    bundled_adapter="$IS_ENGINE_DIR/adapters/$name.sh"
    if [ ! -f "$project_adapter" ] && [ ! -f "$bundled_adapter" ]; then
        die "adapter '$name' not found — create it first: intelligence adapter new $name"
    fi

    # These adapters intentionally omit always-on rules because their tools
    # read AGENTS.md. Do not create a manifest that full sync must refuse.
    case "$name" in
        cursor|copilot|codex|pi|opencode)
            if [ "$(is_target_enabled "$manifest" "agents")" != "1" ]; then
                die "target '$name' requires target 'agents' — enable it first"
            fi
            ;;
    esac

    output="$(get_target_output "$manifest" "$name")"
    if [ -z "$output" ]; then
        if [ "$name" = "agents" ]; then output="AGENTS.md"; else output=".$name"; fi
    fi
    target_set_enabled "$manifest" "$name" true "$output"
    echo "enabled: $name (output: $output)"
    echo "  run: intelligence sync $name"
    exit 0
fi

target_exists "$manifest" "$name" || die "target '$name' is not in the manifest"
if [ "$name" = "agents" ]; then
    for dependent in cursor copilot codex pi opencode; do
        if [ "$(is_target_enabled "$manifest" "$dependent")" = "1" ]; then
            die "target 'agents' is required by enabled target '$dependent' — disable '$dependent' first"
        fi
    done
fi
output="$(get_target_output "$manifest" "$name")"
[ -n "$output" ] || { if [ "$name" = "agents" ]; then output="AGENTS.md"; else output=".$name"; fi; }
target_set_enabled "$manifest" "$name" false "$output"
echo "disabled: $name"
echo "  generated output was kept; remove only paths owned by this adapter"
