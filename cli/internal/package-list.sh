#!/bin/bash
# Internal package list operation.
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

require_cli_project
manifest="$IP_ROOT/intelligence.yaml"
lock="$IP_ROOT/intelligence.lock"
lock_valid=1
if ! check_project_lock "$IP_ROOT"; then lock_valid=0; fi

count=0
while IFS= read -r name; do
    [ -n "$name" ] || continue
    count=$((count + 1))
    range="$(qmap_field "$manifest" "packages" "$name" "version")"
    ref="$(qmap_field "$manifest" "packages" "$name" "ref")"
    resolved="" sha=""
    if [ "$lock_valid" -eq 1 ]; then
        resolved="$(qmap_field "$lock" "packages" "$name" "resolved")"
        sha="$(qmap_field "$lock" "packages" "$name" "sha")"
    fi
    if [ "$lock_valid" -eq 0 ]; then
        state="invalid lock — locked state unchecked"
    elif [ ! -f "$lock" ]; then
        state="lock missing — restore committed intelligence.lock"
    elif [ -d "$IP_ROOT/.intelligence/packages/$name" ]; then
        state="installed"
    else
        state="store missing — run 'intelligence sync'"
    fi
    printf '%s  %s  locked:%s  %s\n' \
        "$name" \
        "${ref:+ref:$ref}${ref:-${range:-*}}" \
        "$(pin_label "$ref" "$resolved" "$sha")" \
        "$state"
done < <(qmap_keys "$manifest" "packages")

if [ "$count" -eq 0 ]; then
    if [ "$lock_valid" -eq 1 ]; then
        echo "No packages. Add one: intelligence package add @ainova-systems/core"
    fi
fi
[ "$lock_valid" -eq 1 ] || exit 1
