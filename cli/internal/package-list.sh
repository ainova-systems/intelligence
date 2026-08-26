#!/bin/bash
# Internal package list operation.
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

require_v2
manifest="$IP_ROOT/intelligence.yaml"
lock="$IP_ROOT/intelligence.lock"

count=0
while IFS= read -r name; do
    [ -n "$name" ] || continue
    count=$((count + 1))
    range="$(qmap_field "$manifest" "packages" "$name" "version")"
    ref="$(qmap_field "$manifest" "packages" "$name" "ref")"
    resolved="$(qmap_field "$lock" "packages" "$name" "resolved")"
    state="missing — run 'intelligence sync' to restore the lock"
    [ -d "$IP_ROOT/.intelligence/packages/$name" ] && state="installed"
    printf '%s  %s  locked:%s  %s\n' \
        "$name" \
        "${ref:+ref:$ref}${ref:-${range:-*}}" \
        "${resolved:-<none>}" \
        "$state"
done < <(qmap_keys "$manifest" "packages")

if [ "$count" -eq 0 ]; then
    echo "No packages. Add one: intelligence package add @ainova-systems/core"
fi
