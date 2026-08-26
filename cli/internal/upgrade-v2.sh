#!/bin/bash
# Internal: bring the project to this CLI's engine: apply v2
# schema migrations, align the engine-content package to the bundled version,
# restamp schema_version, sync.
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

no_sync=0
while [ $# -gt 0 ]; do
    case "$1" in
        --no-sync) no_sync=1 ;;
        *) die "internal upgrade: unknown option '$1'" ;;
    esac
    shift
done

require_v2
manifest="$IP_ROOT/intelligence.yaml"

stamp="$(read_schema_version "$manifest")"
legacy_stamp="$(top_scalar "$manifest" "sync_version")"
eng="$(bundled_engine_version)"
if [ -n "$stamp" ] && _ver_gt "$stamp" "$eng"; then
    die "manifest schema $stamp is newer than this CLI's engine $eng — update the global CLI first"
fi
if [ -n "$legacy_stamp" ] && _ver_gt "$legacy_stamp" "$eng"; then
    die "manifest schema $legacy_stamp is newer than this CLI's engine $eng — update the global CLI first"
fi

# --- v2 schema migrations -------------------------------------------------
# The engine's own chain owns vendored layouts; this one owns the manifest.
# Same discipline: ascending, append-only, each migration self-detects and
# no-ops when already applied.

# v2 migration 0: the original RC manifest called the permanent schema key
# `sync_version`. Rename it without changing its value; the final stamp below
# then aligns it with this engine. The archived v1 reader remains separate.
if [ -n "$legacy_stamp" ]; then
    tmp="$manifest.schema-key.tmp"
    awk '$0 !~ /^sync_version:[[:space:]]*/' "$manifest" > "$tmp" && mv "$tmp" "$manifest"
    echo "  migrating: sync_version -> schema_version"
fi

# v2 migration 1: staged engine content -> the @ainova-systems/sync package.
# Pre-package manifests listed `.intelligence/engine/{rules,agents,skills}`
# as sources fed by a CLI-staged copy; that copy is now an ordinary package
# entry seeded from the bundle. Post-condition: no `.intelligence/engine`
# source entries, the package present in manifest+lock+store, stale dir gone.
migrated=0
for section in rules agents skills; do
    while IFS= read -r src; do
        case "$src" in
            .intelligence/engine/*)
                sources_remove_entry "$manifest" "$section" "$src"
                migrated=1
                ;;
        esac
    done < <(read_yaml_list "$manifest" "$section")
done
if [ "$migrated" -eq 1 ]; then
    echo "  migrating: staged engine content -> $SYNC_PKG_NAME package"
    rm -rf "$IP_ROOT/.intelligence/engine"
    sync_pkg_entry "$manifest"
    sync_pkg_install "$IP_ROOT"
fi

# --- steady state ---------------------------------------------------------
# Align the engine-content package with the bundled engine. Only a manifest
# that HAS the entry is touched — a --bare project opted out, and upgrade
# respects that.
have_pkg=0
while IFS= read -r name; do
    [ "$name" = "$SYNC_PKG_NAME" ] && have_pkg=1
done < <(qmap_keys "$manifest" "packages")
if [ "$have_pkg" -eq 1 ] && [ "$migrated" -eq 0 ]; then
    pinned="$(qmap_field "$manifest" "packages" "$SYNC_PKG_NAME" "version")"
    if [ "$pinned" != "$eng" ]; then
        echo "  $SYNC_PKG_NAME: $pinned -> $eng"
    fi
    sync_pkg_entry "$manifest"
    sync_pkg_install "$IP_ROOT"
fi
if [ "$have_pkg" -eq 0 ] && [ "$migrated" -eq 0 ]; then
    echo "  NOTE: $SYNC_PKG_NAME is not in this manifest (bare setup) — engine meta-skills stay uninstalled; 'intelligence package add $SYNC_PKG_NAME' opts back in." >&2
fi

stamp_schema_version "$manifest" "$eng"
echo "  schema_version -> $eng"

if [ "$no_sync" -eq 0 ]; then
    exec bash "$CLI_DIR/commands/sync.sh"
fi
