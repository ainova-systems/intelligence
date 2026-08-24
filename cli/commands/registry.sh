#!/bin/bash
# intelligence registry <list | add @scope <registry-repo-url> | remove @scope>
#
# A registry binding is rare, per-scope configuration (npm's @scope:registry
# analog): the URL of a git repo whose index.yaml maps names to sources.
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

sub="${1:-list}"
case "$sub" in
    list)
        detect_project
        if [ "$IP_MODE" = "v2" ] && [ -f "$IP_ROOT/intelligence.yaml" ]; then
            echo "Project bindings (intelligence.yaml):"
            found=0
            while IFS= read -r scope; do
                [ -n "$scope" ] || continue
                found=1
                echo "  $scope -> $(qmap_value "$IP_ROOT/intelligence.yaml" "registries" "$scope")"
            done < <(qmap_keys "$IP_ROOT/intelligence.yaml" "registries")
            [ "$found" -eq 0 ] && echo "  (none)"
        fi
        bundled="$(default_index_file)"
        if [ -n "$bundled" ]; then
            echo "Bundled index:"
            while IFS= read -r name; do
                [ -n "$name" ] || continue
                echo "  $name -> $(qmap_field "$bundled" "packages" "$name" "url")"
            done < <(qmap_keys "$bundled" "packages")
        fi
        echo "Fallback: @org/name -> https://github.com/org/name.git"
        ;;
    add)
        scope="${2:-}"; url="${3:-}"
        { [ -n "$scope" ] && [ -n "$url" ]; } || die "usage: intelligence registry add @scope <registry-repo-url>"
        case "$scope" in @*/*) die "bind a scope (@acme), not a package name" ;; @*) ;; *) die "scope must start with @" ;; esac
        require_v2
        qmap_set_value "$IP_ROOT/intelligence.yaml" "registries" "$scope" "$url"
        echo "$scope -> $url"
        ;;
    remove)
        scope="${2:-}"
        [ -n "$scope" ] || die "usage: intelligence registry remove @scope"
        require_v2
        qmap_delete_key "$IP_ROOT/intelligence.yaml" "registries" "$scope"
        echo "unbound $scope"
        ;;
    *)
        die "usage: intelligence registry <list | add @scope <url> | remove @scope>"
        ;;
esac
