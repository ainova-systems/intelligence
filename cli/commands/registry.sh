#!/bin/bash
# intelligence registry <list | add <registry-repo-url> [--force] | remove <url>>
#
# The registries block is a TRUST LIST: git repos holding an index.yaml, in
# trust order. Adding one is a committed, reviewable act — after it, every
# name that registry declares installs like a bundled one. No scope labels:
# names carry their own scope, and the first registry to declare a name wins.
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

sub="${1:-list}"
case "$sub" in
    list)
        detect_project
        if [ "$IP_MODE" = "v2" ] && [ -f "$IP_ROOT/intelligence.yaml" ]; then
            echo "Project registries (intelligence.yaml, trust order):"
            found=0
            while IFS= read -r url; do
                [ -n "$url" ] || continue
                found=1
                index="$(_fetch_index "${url#git+}")"
                if [ -n "$index" ]; then
                    n="$(qmap_keys "$index" "packages" | grep -c . || true)"
                    echo "  $url — $n package(s)"
                else
                    echo "  $url — UNREACHABLE or no index.yaml"
                fi
            done < <(registries_list "$IP_ROOT/intelligence.yaml")
            [ "$found" -eq 0 ] && echo "  (none)"
        fi
        echo "Names resolve ONLY through the list above. Registry-less installs are explicit: github:org/repo, git+<url>."
        ;;
    add)
        url="${2:-}"
        force=0
        [ "${3:-}" = "--force" ] && force=1
        [ -n "$url" ] || die "usage: intelligence registry add <registry-repo-url> [--force]"
        case "$url" in
            @*) die "registries are added by URL — names carry their own scope. To install a package: intelligence add $url/<name>" ;;
        esac
        assert_safe_source_url "${url#git+}"
        require_v2
        # Fail closed: a URL that cannot produce an index is not a registry,
        # and recording it would turn a typo here into a confusing failure at
        # the first add. --force covers the one honest case: the registry is
        # not published (or reachable) yet.
        index="$(_fetch_index "${url#git+}")"
        if [ -n "$index" ]; then
            n="$(qmap_keys "$index" "packages" | grep -c . || true)"
            echo "  index.yaml reachable — $n package(s):"
            qmap_keys "$index" "packages" | sed 's/^/    /'
        elif [ "$force" -eq 1 ]; then
            echo "  WARN: no index.yaml at $url — recording anyway (--force)." >&2
        else
            echo "ERROR: no index.yaml found at $url — not adding it." >&2
            echo "  A registry is a git repo with index.yaml at its root, mapping names to sources:" >&2
            echo "    packages:" >&2
            echo "      \"@acme/backend\":" >&2
            echo "        url: \"https://github.com/acme/intelligence.git\"" >&2
            echo "        path: \"packs/backend\"      # omit when the repo IS the package" >&2
            echo "  Format and an example: https://github.com/ainova-systems/intelligence-registry" >&2
            echo "  A single repository needs no registry at all: intelligence add github:org/repo" >&2
            echo "  Recording it ahead of a registry that does not exist yet: --force" >&2
            exit 1
        fi
        registries_add "$IP_ROOT/intelligence.yaml" "$url"
        echo "added: $url"
        ;;
    remove)
        url="${2:-}"
        [ -n "$url" ] || die "usage: intelligence registry remove <url>"
        require_v2
        registries_remove "$IP_ROOT/intelligence.yaml" "$url"
        # The retired flat-map form also stored scope keys — drop one if the
        # argument names it, so old manifests clean up with the old command.
        case "$url" in
            @*) qmap_delete_key "$IP_ROOT/intelligence.yaml" "registries" "$url" ;;
        esac
        echo "removed: $url"
        ;;
    *)
        die "usage: intelligence registry <list | add <url> [--force] | remove <url>>"
        ;;
esac
