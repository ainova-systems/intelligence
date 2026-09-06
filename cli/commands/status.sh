#!/bin/bash
# intelligence status [--check] — project state or deep consistency checks.
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

case "${1:-}" in
    "") ;;
    --check) [ $# -eq 1 ] || die "usage: intelligence status [--check]"; exec bash "$CLI_DIR/internal/check.sh" ;;
    *) die "usage: intelligence status [--check]" ;;
esac

detect_project
case "$IP_MODE" in
    cli)
        lock_valid=1
        echo "Project:  $IP_ROOT (Intelligence project)"
        echo "Manifest: intelligence.yaml (schema_version $(read_schema_version "$IP_ROOT/intelligence.yaml"))"
        if ! check_project_lock "$IP_ROOT"; then
            lock_valid=0
            echo "Lockfile: INVALID (locked state unchecked)"
        elif [ -f "$IP_ROOT/intelligence.lock" ]; then
            echo "Lockfile: intelligence.lock"
        elif [ -n "$(qmap_keys "$IP_ROOT/intelligence.yaml" "packages")" ]; then
            echo "Lockfile: MISSING (manifest declares packages)"
        else
            echo "Lockfile: none (no packages added yet)"
        fi
        sync_locked=""
        if [ "$lock_valid" -eq 1 ]; then
            sync_locked="$(qmap_field "$IP_ROOT/intelligence.lock" "packages" "$SYNC_PKG_NAME" "resolved")"
        fi
        if [ "$lock_valid" -eq 0 ]; then
            echo "Content:  unchecked"
        elif [ -n "$sync_locked" ]; then
            echo "Content:  $SYNC_PKG_NAME at $sync_locked"
        else
            echo "Content:  no $SYNC_PKG_NAME (bare setup)"
        fi
        echo "Engine:   $(bundled_engine_version) (bundled with the CLI)"
        [ "$lock_valid" -eq 1 ] || exit 1
        ;;
    legacy)
        echo "Project:  $IP_ROOT (legacy Intelligence Sync)"
        echo "Umbrella: $IP_UMBRELLA"
        echo "Engine:   $(tr -d ' \t\r\n' < "$IP_MODULE_DIR/scripts/VERSION") (vendored at $IP_MODULE_DIR)"
        echo "Stamp:    $(top_scalar "$IP_UMBRELLA/config.yaml" "sync_version")"
        echo ""
        echo "Convert to Intelligence: intelligence init"
        ;;
    *)
        echo "No intelligence project here. Start one: intelligence init"
        ;;
esac
