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
schema_key_count="$(awk '/^schema_version:[[:space:]]*/ { n++ } END { print n + 0 }' "$manifest")"
legacy_key_count="$(awk '/^sync_version:[[:space:]]*/ { n++ } END { print n + 0 }' "$manifest")"
eng="$(bundled_engine_version)"
[ "$schema_key_count" -le 1 ] || die "manifest has duplicate schema_version keys"
[ "$legacy_key_count" -le 1 ] || die "manifest has duplicate sync_version keys"
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
    if [ -n "$stamp" ]; then
        [ "$stamp" = "$legacy_stamp" ] || die "manifest has conflicting schema_version '$stamp' and sync_version '$legacy_stamp'"
        _qmap_stage "$manifest" '$0 !~ /^sync_version:[[:space:]]*/'
    else
        _qmap_stage "$manifest" '{ sub(/^sync_version:/, "schema_version:"); print }'
    fi
    echo "  migrating: sync_version -> schema_version"
fi

# v2 migration 1: package entries contain requested intent only. Early RCs
# also copied resolved url/path into the manifest. Preserve the existing lock
# as the trusted source and remove that duplicate representation. A direct
# unversioned package becomes an explicit HEAD pin so its manifest entry stays
# meaningful after the source fields are removed.
source_fields_migrated=0
while IFS= read -r name; do
    [ -n "$name" ] || continue
    m_url="$(qmap_field "$manifest" "packages" "$name" "url")"
    m_path="$(qmap_field "$manifest" "packages" "$name" "path")"
    [ -n "$m_url" ] || [ -n "$m_path" ] || continue
    m_ver="$(qmap_field "$manifest" "packages" "$name" "version")"
    m_ref="$(qmap_field "$manifest" "packages" "$name" "ref")"
    if [ -z "$m_ver" ] && [ -z "$m_ref" ]; then
        locked_ref="$(qmap_field "$IP_ROOT/intelligence.lock" "packages" "$name" "resolved")"
        qmap_set "$manifest" "packages" "$name" "ref" "${locked_ref:-HEAD}"
    fi
    qmap_delete_field "$manifest" "packages" "$name" "url"
    qmap_delete_field "$manifest" "packages" "$name" "path"
    source_fields_migrated=1
done < <(qmap_keys "$manifest" "packages")
if [ "$source_fields_migrated" -eq 1 ]; then
    echo "  migrating: package url/path -> intelligence.lock"
fi

# v2 migration 2: staged engine content -> the @ainova-systems/sync package.
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

# A previous RC could leave this managed directory even after its source
# entries were already removed. Its presence is itself an upgrade predicate,
# so always close that post-condition.
if [ -d "$IP_ROOT/.intelligence/engine" ]; then
    rm -rf "$IP_ROOT/.intelligence/engine"
    echo "  removed stale .intelligence/engine"
fi

stamp_schema_version "$manifest" "$eng"
echo "  schema_version -> $eng"

if [ "$no_sync" -eq 0 ]; then
    exec bash "$CLI_DIR/commands/sync.sh"
fi
