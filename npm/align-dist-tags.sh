#!/bin/bash
# Keep npm's stable and preview channels coherent after a successful publish.
set -euo pipefail

channel="${1:?usage: align-dist-tags.sh <latest|next> <version> [package]}"
version="${2:?usage: align-dist-tags.sh <latest|next> <version> [package]}"
pkg="${3:-@ainova-systems/intelligence}"

case "$channel" in
    latest)
        current="$(npm view "$pkg" dist-tags.next 2>/dev/null || true)"
        if [ "$current" != "$version" ]; then
            npm dist-tag add "$pkg@$version" next
            echo "next: ${current:-<unset>} -> $version (stable release)"
        else
            echo "next already points at stable $version"
        fi
        ;;
    next)
        # npm assigns `latest` to a package's first publication even when that
        # publication used --tag next. Until the first stable release exists,
        # keep that accidental prerelease pointer current. Never replace a
        # stable latest with a prerelease.
        current="$(npm view "$pkg" dist-tags.latest 2>/dev/null || true)"
        case "$current" in
            *-*)
                if [ "$current" != "$version" ]; then
                    npm dist-tag add "$pkg@$version" latest
                    echo "latest: $current -> $version (no stable release yet)"
                else
                    echo "latest already points at prerelease $version"
                fi
                ;;
            *) echo "latest is ${current:-<unset>} (stable or unset) - left alone" ;;
        esac
        ;;
    *)
        echo "unsupported npm channel '$channel' (expected latest or next)" >&2
        exit 2
        ;;
esac
