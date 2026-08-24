#!/bin/bash
# intelligence sync [target] — render intelligence to every enabled tool.
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

detect_project
case "$IP_MODE" in
    v2)
        ensure_engine_staged "$IP_ROOT"
        export_engine_env "$IP_ROOT"
        exec bash "$IS_ENGINE_DIR/scripts/sync.sh" "$@"
        ;;
    legacy)
        # A vendored project syncs with ITS engine — its pin is the contract,
        # and a newer bundled engine must not generate against an older schema.
        echo "NOTE: vendored (v1) setup — delegating to its own engine. 'intelligence migrate' converts it to the CLI setup." >&2
        exec bash "$IP_MODULE_DIR/scripts/sync.sh" "$@"
        ;;
    *)
        die "no intelligence project found here — run 'intelligence init'"
        ;;
esac
