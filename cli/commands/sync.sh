#!/bin/bash
# intelligence sync [target] [--compact] [--force] [--check] - render intelligence
# to enabled tools, or report whether rendering would change anything.
set -euo pipefail

# Only sync_check may request a comparison from the engine.
unset IS_SYNC_CHECK IS_SYNC_CHECK_ROOT

# Print before library loading and lifecycle checks so a content verification
# never looks idle. Compact output remains a buffered machine-readable report,
# and a check prints only its verdict.
compact=0
check=0
for argument in "$@"; do
    case "$argument" in
        --compact) compact=1 ;;
        --check) check=1 ;;
    esac
done
[ "$compact" -ne 0 ] || [ "$check" -ne 0 ] || echo 'Checking project...'
# The CLI's package descriptor is read in the same pass as the project's
# manifest and lock, once this command holds the project lock.
# shellcheck disable=SC2034  # read by cli-common.sh while it loads
CLI_DEFER_SYNC_PKG=1
source "$CLI_DIR/lib/cli-common.sh"
force=0
target=""
while [ $# -gt 0 ]; do
    case "$1" in
        --compact) compact=1 ;;
        --force) force=1 ;;
        --check) check=1 ;;
        -*) die "unknown option '$1'" ;;
        *)
            [ -z "$target" ] || die "usage: intelligence sync [adapter] [--compact] [--force] [--check]"
            target="$1"
            ;;
    esac
    shift
done

# Set where a check concludes that sync is needed, so a failure that happens to
# end in the same status is never mistaken for that verdict.
IS_CHECK_OUT_OF_DATE=0

# hold_project — take the project lock, then read the package descriptor,
# manifest and lock once for the whole preflight.
hold_project() {
    project_lock_hold "$IP_ROOT"
    project_reads_preload "$IP_ROOT"
    load_sync_package_identity
}

run_sync() {
    detect_project || return $?
    case "$IP_MODE" in
        cli)
            # One writer per project at a time: the store restore and the
            # render below both rewrite shared state (sync-lock.sh).
            hold_project
            # `sync` is the normal fresh-clone command. A newer globally installed
            # CLI aligns the current Intelligence project first (except in CI, where a
            # tracked migration must be reviewed and committed locally), and a
            # missing ignored store is restored strictly from the committed lock.
            ensure_project_current "$IP_ROOT" || return $?
            restore_project_store_if_missing "$IP_ROOT" || return $?
            export_engine_env "$IP_ROOT" || return $?
            sync_with_cache "$target" "$force" || return $?
            ;;
        legacy)
            load_sync_package_identity
            [ "$force" -eq 0 ] || die "--force is unavailable for a legacy Intelligence Sync project - run 'intelligence init' to convert it first"
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
            load_sync_package_identity
            die "no intelligence project found here - run 'intelligence init'"
            ;;
    esac
}

# run_check — the same preflight as sync, except that tracked alignment is never
# applied (it is reported as needed, in CI or not) and everything but the
# verdict goes to stderr. Restoring the ignored package store from the lock is
# allowed: it is reproducible state, and the comparison needs it.
run_check() {
    local stamp
    detect_project || return $?
    case "$IP_MODE" in
        cli) ;;
        legacy)
            load_sync_package_identity
            die "--check is unavailable for a legacy Intelligence Sync project - run 'intelligence init' to convert it first"
            ;;
        *)
            load_sync_package_identity
            die "no intelligence project found here - run 'intelligence init'"
            ;;
    esac
    hold_project
    project_preflight "$IP_ROOT" || return $?
    if project_needs_upgrade "$IP_ROOT"; then
        read_schema_version_var "$IP_ROOT/intelligence.yaml"
        stamp="$IS_SCHEMA_VERSION"
        bundled_engine_version_var
        IS_CHECK_OUT_OF_DATE=1
        is_status out-of-date "the project needs alignment (stamp ${stamp:-unstamped}, engine $IS_BUNDLED_ENGINE_VERSION); run 'intelligence init --apply' locally, review and commit the diff"
        return "$IS_RC_OUT_OF_DATE"
    fi
    restore_project_store_if_missing "$IP_ROOT" keep-sources >&2 || return $?
    export_engine_env "$IP_ROOT" || return $?
    sync_check "$target" "$force" || return $?
}

if [ "$check" -eq 1 ]; then
    # --compact changes nothing here: the verdict is already one status line,
    # and a failure's diagnostics already reach stderr.
    rc=0
    run_check || rc=$?
    if [ "$rc" = "$IS_RC_OUT_OF_DATE" ] && [ "$IS_CHECK_OUT_OF_DATE" != 1 ]; then
        rc=1
    fi
    exit "$rc"
fi

if [ "$compact" -eq 0 ]; then
    run_sync
    exit $?
fi

# Compact mode keeps actionable one-line warnings on success. Buffering the
# complete combined stream means a failure still returns every diagnostic
# emitted by lifecycle preflight, locked restore or the engine, together with
# its real rc.
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
grep -E '^(WARNING:|CONTEXT:)' "$compact_output" || true
echo "$status_line"
echo "$done_line"
