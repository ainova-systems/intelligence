#!/bin/bash
# intelligence status — project state at a glance.
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

detect_project
case "$IP_MODE" in
    v2)
        echo "Project:  $IP_ROOT (CLI setup)"
        echo "Manifest: intelligence.yaml (sync_version $(read_engine_stamp "$IP_ROOT/intelligence.yaml"))"
        if [ -f "$IP_ROOT/intelligence.lock" ]; then
            echo "Lockfile: intelligence.lock"
        else
            echo "Lockfile: none (no packages added yet)"
        fi
        sync_locked="$(qmap_field "$IP_ROOT/intelligence.lock" "packages" "$SYNC_PKG_NAME" "resolved")"
        if [ -n "$sync_locked" ]; then
            echo "Content:  $SYNC_PKG_NAME at $sync_locked"
        else
            echo "Content:  no $SYNC_PKG_NAME (bare setup)"
        fi
        echo "Engine:   $(bundled_engine_version) (bundled with the CLI)"
        ;;
    legacy)
        echo "Project:  $IP_ROOT (vendored v1 setup)"
        echo "Umbrella: $IP_UMBRELLA"
        echo "Engine:   $(tr -d ' \t\r\n' < "$IP_MODULE_DIR/scripts/VERSION") (vendored at $IP_MODULE_DIR)"
        echo "Stamp:    $(read_engine_stamp "$IP_UMBRELLA/config.yaml")"
        echo ""
        echo "Convert to the CLI setup: intelligence migrate"
        ;;
    *)
        echo "No intelligence project here. Start one: intelligence init"
        ;;
esac
