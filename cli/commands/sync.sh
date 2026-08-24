#!/bin/bash
# intelligence sync [target] — render intelligence to every enabled tool.
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

detect_project
case "$IP_MODE" in
    v2)
        # Fail closed, never skip silently: a store-backed source that is not
        # on disk means the project is not installed (or predates the package
        # model) — syncing would quietly drop whole rule sets.
        missing="" stale=0
        for section in rules agents skills; do
            while IFS= read -r src; do
                [ -n "$src" ] || continue
                case "$src" in
                    .intelligence/engine/*) stale=1 ;;
                    .intelligence/*) [ -d "$IP_ROOT/$src" ] || missing="$missing $src" ;;
                esac
            done < <(read_yaml_list "$IP_ROOT/intelligence.yaml" "$section")
        done
        if [ "$stale" -eq 1 ]; then
            die "this manifest predates the engine-content package (.intelligence/engine sources) — run 'intelligence upgrade'"
        fi
        if [ -n "$missing" ]; then
            die "installed content missing on disk:$missing — run 'intelligence install'"
        fi
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
