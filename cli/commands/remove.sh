#!/bin/bash
# intelligence remove <@scope/name> [--no-sync]
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

name="${1:-}"
[ -n "$name" ] || die "usage: intelligence remove <@scope/name>"
shift || true
no_sync=0
for a in "$@"; do
    case "$a" in
        --no-sync) no_sync=1 ;;
        *) die "unknown option '$a'" ;;
    esac
done

require_v2
assert_valid_pkg_name "$name"
manifest="$IP_ROOT/intelligence.yaml"
lock="$IP_ROOT/intelligence.lock"
rel=".intelligence/packages/$name"

known=0
while IFS= read -r k; do
    [ "$k" = "$name" ] && known=1
done < <(qmap_keys "$manifest" "packages")
[ "$known" -eq 1 ] || die "package '$name' is not in the manifest"

unwire_package_sources "$manifest" "$rel"
qmap_delete_key "$manifest" "packages" "$name"
lock_remove "$lock" "$name"
rm -rf "${IP_ROOT:?}/$rel"
# Drop the now-empty scope dir so the store stays tidy.
rmdir "$IP_ROOT/.intelligence/packages/${name%%/*}" 2>/dev/null || true
echo "- $name"

if [ "$no_sync" -eq 0 ]; then
    exec bash "$CLI_DIR/commands/sync.sh"
fi
