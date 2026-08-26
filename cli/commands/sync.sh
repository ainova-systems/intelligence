#!/bin/bash
# intelligence sync [target] — render intelligence to every enabled tool.
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

detect_project
case "$IP_MODE" in
    v2)
        # `sync` is the normal fresh-clone command. A newer globally installed
        # CLI upgrades the current v2 project first (except in CI, where a
        # tracked migration must be reviewed and committed locally), and a
        # missing ignored store is restored strictly from the committed lock.
        ensure_project_current "$IP_ROOT"
        restore_project_store_if_missing "$IP_ROOT"
        export_engine_env "$IP_ROOT"
        exec bash "$IS_ENGINE_DIR/sync.sh" "$@"
        ;;
    legacy)
        # A vendored project syncs with ITS engine — its pin is the contract,
        # and a newer bundled engine must not generate against an older schema.
        echo "NOTE: vendored (v1) setup — delegating to its own engine. 'intelligence init' converts it to the CLI setup." >&2
        exec bash "$IP_MODULE_DIR/scripts/sync.sh" "$@"
        ;;
    *)
        die "no intelligence project found here — run 'intelligence init'"
        ;;
esac
