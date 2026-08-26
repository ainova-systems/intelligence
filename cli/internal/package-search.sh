#!/bin/bash
# Internal package search operation: what the registries offer and what this project
# already has. The catalogue view `list` deliberately is not: `list` answers
# "what does this project depend on", `search` answers "what could it".
#
# Sources, in resolution order (a name found earlier wins, exactly as `add`
# resolves it): the manifest's trusted registries, in order.
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

term="${1:-}"

detect_project
manifest=""
[ "$IP_MODE" = "v2" ] && manifest="$IP_ROOT/intelligence.yaml"

# State of one package name in this project: installed / declared / available.
pkg_state() {
    local name="$1"
    [ -n "$manifest" ] || { printf 'available'; return 0; }
    local declared=0 k
    while IFS= read -r k; do
        [ "$k" = "$name" ] && declared=1
    done < <(qmap_keys "$manifest" "packages")
    if [ "$declared" -eq 0 ]; then
        printf 'available'
    elif [ -d "$IP_ROOT/.intelligence/packages/$name" ]; then
        printf 'installed %s' "$(qmap_field "$IP_ROOT/intelligence.lock" "packages" "$name" "resolved")"
    else
        printf 'declared (run sync)'
    fi
}

seen=" "
rows=0
# emit_index <index-file> <origin-label>
# Registries are consulted in trust order; the first to declare a name wins,
# so a name already seen is not repeated (that IS the resolution order).
emit_index() {
    local index="$1" origin="$2" name desc state
    [ -n "$index" ] && [ -f "$index" ] || return 0
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        case "$seen" in *" $name "*) continue ;; esac
        if [ -n "$term" ]; then
            desc="$(qmap_field "$index" "packages" "$name" "description")"
            case "$name$desc" in
                *"$term"*) ;;
                *) continue ;;
            esac
        fi
        seen="$seen$name "
        desc="$(qmap_field "$index" "packages" "$name" "description")"
        state="$(pkg_state "$name")"
        printf '%-34s %-22s %s\n' "$name" "$state" "${desc:-$(qmap_field "$index" "packages" "$name" "url")}"
        [ "$origin" = "bundled" ] || printf '%-34s %s\n' "" "  via $origin"
        rows=$((rows + 1))
    done < <(qmap_keys "$index" "packages")
}

if [ -n "$manifest" ]; then
    while IFS= read -r url; do
        [ -n "$url" ] || continue
        index="$(_fetch_index "${url#git+}")"
        if [ -z "$index" ]; then
            echo "  WARN: registry unreachable or missing index.yaml: $url" >&2
            continue
        fi
        emit_index "$index" "$url"
    done < <(registries_list "$manifest")
fi
if [ "$rows" -eq 0 ]; then
    if [ -n "$term" ]; then
        echo "Nothing matching '$term' in this project's trusted registries."
    else
        echo "No trusted registries (or they offer nothing) — intelligence registry add <repo-url>."
    fi
    echo "Explicit installs need no registry: intelligence package add github:org/repo"
    exit 0
fi

echo ""
echo "add one: intelligence package add <name>   |   private registry: intelligence registry add <repo-url>"
