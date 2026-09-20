#!/bin/bash
# Internal adapter target-state operation.
#
# Change only the manifest. Syncing and deleting generated output are separate
# explicit actions: a generic target command cannot infer a custom adapter's
# ownership safely.
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

action="${1:-}"
name="${2:-}"
[ $# -le 2 ] || die "internal target state: expected <enable|disable> <name>"
case "$action" in enable|disable) ;; *) die "internal target state: expected <enable|disable> <name>" ;; esac
[ -n "$name" ] || die "internal target state: missing adapter name"
assert_valid_target_name "$name"

require_cli_project
manifest="$IP_ROOT/intelligence.yaml"
content_dir="$(manifest_intelligence_dir "$manifest")"

if [ "$action" = "enable" ]; then
    project_adapter="$IP_ROOT/$content_dir/adapters/$name.sh"
    bundled_adapter="$IS_ENGINE_DIR/adapters/$name.sh"
    if [ ! -f "$project_adapter" ] && [ ! -f "$bundled_adapter" ]; then
        die "adapter '$name' not found — create it first: intelligence adapter create $name"
    fi

    output="$(get_target_output "$manifest" "$name")"
    [ -n "$output" ] || output="$(default_target_output "$name")"
    validate_adapter_contract_for "$IP_ROOT" "$content_dir" "$name" "$output" \
        || die "adapter '$name' has an invalid ownership contract"
    records="$(adapter_records_for "$IP_ROOT" "$content_dir" "$name" "$output")" \
        || die "adapter '$name' has an invalid ownership contract"
    while IFS= read -r required; do
        [ -n "$required" ] || continue
        if [ "$(is_target_enabled "$manifest" "$required")" != "1" ]; then
            die "target '$name' requires target '$required' — enable it first"
        fi
    done < <(awk -F '\t' '$1 == "requires" { print $2 }' <<< "$records")

    # Two adapters claiming one owned path prune each other's output, and both
    # syncs still report success. Refuse here, while the manifest is the only
    # thing that would have to change.
    adapter_claims_reset
    while IFS= read -r enabled_target; do
        [ -n "$enabled_target" ] || continue
        [ "$enabled_target" = "$name" ] && continue
        [ "$(is_target_enabled "$manifest" "$enabled_target")" = "1" ] || continue
        enabled_output="$(get_target_output "$manifest" "$enabled_target")"
        [ -n "$enabled_output" ] || enabled_output="$(default_target_output "$enabled_target")"
        enabled_records="$(adapter_records_for "$IP_ROOT" "$content_dir" "$enabled_target" "$enabled_output" 2>/dev/null)" \
            || continue
        adapter_claims_add_records "$enabled_target" "$enabled_records" || true
    done < <(target_names "$manifest")
    adapter_claims_add_records "$name" "$records" \
        || die "$IS_ADAPTER_CLAIM_CONFLICT"

    target_set_enabled "$manifest" "$name" true "$output"
    ensure_target_gitignore "$IP_ROOT" "$manifest" "$name"
    ensure_manifest_publisher_ignores "$IP_ROOT" "$manifest"
    echo "enabled: $name (output: $output)"
    exit 0
fi

target_exists "$manifest" "$name" || die "target '$name' is not in the manifest"
while IFS= read -r dependent; do
    [ -n "$dependent" ] || continue
    [ "$dependent" = "$name" ] && continue
    [ "$(is_target_enabled "$manifest" "$dependent")" = "1" ] || continue
    dependent_output="$(get_target_output "$manifest" "$dependent")"
    [ -n "$dependent_output" ] || dependent_output="$(default_target_output "$dependent")"
    dependent_records="$(adapter_records_for "$IP_ROOT" "$content_dir" "$dependent" "$dependent_output")" \
        || die "adapter '$dependent' has an invalid ownership contract"
    if awk -F '\t' -v required="$name" \
        '$1 == "requires" && $2 == required { found=1 } END { exit(found ? 0 : 1) }' \
        <<< "$dependent_records"; then
        die "target '$name' is required by enabled target '$dependent' — disable '$dependent' first"
    fi
done < <(target_names "$manifest")
output="$(get_target_output "$manifest" "$name")"
[ -n "$output" ] || output="$(default_target_output "$name")"
target_set_enabled "$manifest" "$name" false "$output"
echo "disabled: $name"
echo "  generated output was kept; remove only paths owned by this adapter"
