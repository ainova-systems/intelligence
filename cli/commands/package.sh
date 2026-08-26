#!/bin/bash
# intelligence package <add|remove|list|search> ...
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

action="${1:-}"
[ -n "$action" ] || die "usage: intelligence package <add|remove|list|search> [args]"
shift

case "$action" in
    add)
        require_v2
        ensure_project_current "$IP_ROOT"
        exec bash "$CLI_DIR/internal/package-add.sh" "$@"
        ;;
    remove)
        require_v2
        ensure_project_current "$IP_ROOT"
        exec bash "$CLI_DIR/internal/package-remove.sh" "$@"
        ;;
    list)
        exec bash "$CLI_DIR/internal/package-list.sh" "$@"
        ;;
    search)
        exec bash "$CLI_DIR/internal/package-search.sh" "$@"
        ;;
    *)
        die "usage: intelligence package <add|remove|list|search> [args]"
        ;;
esac
