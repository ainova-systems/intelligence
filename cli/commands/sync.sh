#!/bin/bash
# intelligence sync [target] [--compact] - render intelligence to enabled tools.
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

compact=0
target=""
while [ $# -gt 0 ]; do
    case "$1" in
        --compact) compact=1 ;;
        -*) die "unknown option '$1'" ;;
        *)
            [ -z "$target" ] || die "usage: intelligence sync [adapter] [--compact]"
            target="$1"
            ;;
    esac
    shift
done

run_sync() {
    detect_project || return $?
    case "$IP_MODE" in
        cli)
            # `sync` is the normal fresh-clone command. A newer globally installed
            # CLI aligns the current Intelligence project first (except in CI, where a
            # tracked migration must be reviewed and committed locally), and a
            # missing ignored store is restored strictly from the committed lock.
            ensure_project_current "$IP_ROOT" || return $?
            restore_project_store_if_missing "$IP_ROOT" || return $?
            export_engine_env "$IP_ROOT" || return $?
            if [ -n "$target" ]; then
                bash "$IS_ENGINE_DIR/sync.sh" "$target" || return $?
            else
                bash "$IS_ENGINE_DIR/sync.sh" || return $?
            fi
            ;;
        legacy)
            [ "$compact" -eq 0 ] || die "--compact is unavailable for a legacy Intelligence Sync project - run 'intelligence init' to convert it first"
            # A vendored project syncs with its own engine: its pin is the
            # contract, and a newer bundled engine must not generate against an
            # older schema.
            echo "NOTE: legacy Intelligence Sync project - delegating to $IP_MODULE_DIR/scripts/sync.sh. 'intelligence init' converts it into an Intelligence project." >&2
            if [ -n "$target" ]; then
                bash "$IP_MODULE_DIR/scripts/sync.sh" "$target" || return $?
            else
                bash "$IP_MODULE_DIR/scripts/sync.sh" || return $?
            fi
            ;;
        *)
            die "no intelligence project found here - run 'intelligence init'"
            ;;
    esac
}

if [ "$compact" -eq 0 ]; then
    run_sync
    exit $?
fi

# Compact mode is intentionally quiet only on success. Buffering the complete
# combined stream means a failure still returns every diagnostic emitted by
# lifecycle preflight, locked restore or the engine, together with its real rc.
compact_output="$(mktemp -t intelligence-sync-XXXXXX)"
trap 'rm -f "$compact_output"' EXIT
rc=0
(run_sync) > "$compact_output" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
    cat "$compact_output" >&2
    exit "$rc"
fi

status_line="$(grep '^IS_STATUS=ok\($\| \)' "$compact_output" | tail -1 || true)"
done_line="$(grep '^=== Done:' "$compact_output" | tail -1 || true)"
if [ -z "$status_line" ] || [ -z "$done_line" ]; then
    cat "$compact_output" >&2
    echo "ERROR: sync succeeded without its final status contract" >&2
    exit 1
fi
echo "$status_line"
echo "$done_line"
