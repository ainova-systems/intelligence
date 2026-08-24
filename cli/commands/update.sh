#!/bin/bash
# intelligence update [name] [--no-sync]
#
# Re-resolve version ranges against the remotes and rewrite the lock. Pinned
# packages (`ref:`) never move here — repin by editing the manifest or
# re-adding. `update <name>` limits the pass to one package.
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

only="" no_sync=0
while [ $# -gt 0 ]; do
    case "$1" in
        --no-sync) no_sync=1 ;;
        @*) only="$1" ;;
        *) die "unknown argument '$1'" ;;
    esac
    shift || true
done

require_v2
manifest="$IP_ROOT/intelligence.yaml"
lock="$IP_ROOT/intelligence.lock"

moved=0 checked=0
while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ -n "$only" ] && [ "$name" != "$only" ] && continue
    ref="$(qmap_field "$manifest" "packages" "$name" "ref")"
    [ -n "$ref" ] && { echo "  $name: pinned to ref '$ref' — skipped"; continue; }
    range="$(qmap_field "$manifest" "packages" "$name" "version")"
    url="$(qmap_field "$manifest" "packages" "$name" "url")"
    path="$(qmap_field "$manifest" "packages" "$name" "path")"
    if [ -z "$url" ]; then
        resolve_package_source "$manifest" "$name"
        url="$RES_URL"; path="$RES_PATH"
    fi
    checked=$((checked + 1))
    picked="$(list_remote_versions "$url" | semver_pick_highest "$range")"
    [ -n "$picked" ] || { echo "  $name: nothing satisfies '${range:-*}' at $url" >&2; continue; }
    read -r tag _ <<< "$(remote_tag_for_version "$url" "$picked")"
    current="$(qmap_field "$lock" "packages" "$name" "resolved")"
    if [ "$tag" = "$current" ]; then
        echo "  $name: ${current:-<none>} (up to date)"
        continue
    fi
    rel=".intelligence/packages/$name"
    sha="$(fetch_package "$url" "$tag" "$path" "$IP_ROOT/$rel")"
    wire_package_sources "$manifest" "$name" "$rel" "$IP_ROOT"
    lock_upsert "$lock" "$name" "$range" "$url" "$path" "$tag" "$sha"
    echo "  $name: ${current:-<none>} -> $tag"
    moved=$((moved + 1))
done < <(qmap_keys "$manifest" "packages")

[ -n "$only" ] && [ "$checked" -eq 0 ] && die "package '$only' is not in the manifest"
echo "updated: $moved package(s)"

if [ "$moved" -gt 0 ] && [ "$no_sync" -eq 0 ]; then
    exec bash "$CLI_DIR/commands/sync.sh"
fi
