#!/bin/bash
# Internal package remove operation.
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

name="${1:-}"
[ -n "$name" ] || die "usage: intelligence package remove <@scope/name>"
shift || true
no_sync=0 force=0
for a in "$@"; do
    case "$a" in
        --no-sync) no_sync=1 ;;
        --force) force=1 ;;
        *) die "unknown option '$a'" ;;
    esac
done

require_cli_project

# Removing the engine-content package guts the outputs (meta-skills, the
# authoring rule, both engine agents disappear) while everything still
# reports ok — legal, but never by accident.
if [ "$name" = "$SYNC_PKG_NAME" ] && [ "$force" -eq 0 ]; then
    echo "ERROR: $SYNC_PKG_NAME is the engine's own content — removing it drops every" >&2
    echo "  intelligence-* meta-skill, the authoring rule and the engine agents from" >&2
    echo "  the outputs. The sync engine itself keeps working (it ships with the CLI)." >&2
    echo "  If that is what you want: intelligence package remove $SYNC_PKG_NAME --force" >&2
    exit 1
fi
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
