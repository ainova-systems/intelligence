#!/bin/bash
# Internal package range update operation.
#
# Resolve requested versions/refs against each package's locked source and
# rewrite the lock. `update <name>` limits the pass to one package; re-adding
# is the explicit operation for changing a source URL/path.
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

only="" no_sync=0 preview=0
while [ $# -gt 0 ]; do
    case "$1" in
        --no-sync) no_sync=1 ;;
        --preview) preview=1 ;;
        @*) only="$1" ;;
        *) die "unknown argument '$1'" ;;
    esac
    shift || true
done

require_cli_project
manifest="$IP_ROOT/intelligence.yaml"
lock="$IP_ROOT/intelligence.lock"

moved=0 found=0
while IFS= read -r name; do
    [ -n "$name" ] || continue
    # Manifest keys are untrusted input on their way into store paths.
    assert_valid_pkg_name "$name"
    [ -n "$only" ] && [ "$name" != "$only" ] && continue
    # A named package that exists is "found" whatever happens next — a skip
    # message followed by "not in the manifest" would contradict itself.
    found=1
    if [ "$name" = "$SYNC_PKG_NAME" ]; then
        echo "  $name: engine content follows the installed CLI — skipped"
        continue
    fi
    current="$(qmap_field "$lock" "packages" "$name" "resolved")"
    locked_requested="$(qmap_field "$lock" "packages" "$name" "requested")"
    url="$(qmap_field "$lock" "packages" "$name" "url")"
    path="$(qmap_field "$lock" "packages" "$name" "path")"
    [ -n "$url" ] || die "$name has no source in intelligence.lock — restore the committed lock or re-add the package"
    ref="$(qmap_field "$manifest" "packages" "$name" "ref")"
    range="$(qmap_field "$manifest" "packages" "$name" "version")"
    [ -n "$ref" ] || [ -n "$range" ] || die "$name has neither version nor ref in the manifest"

    if [ -n "$ref" ]; then
        tag="$ref"
        requested=""
    else
        picked="$(list_remote_versions "$url" | semver_pick_highest "$range")"
        [ -n "$picked" ] || { echo "  $name: nothing satisfies '$range' at $url" >&2; continue; }
        read -r tag _ <<< "$(remote_tag_for_version "$url" "$picked")"
        requested="$range"
    fi
    if [ "$tag" = "$current" ] && [ "$requested" != "$locked_requested" ]; then
        if [ "$preview" -eq 1 ]; then
            echo "  $name: request ${locked_requested:-<none>} -> ${requested:-<ref>} (keeps $current)"
        else
            locked_sha="$(qmap_field "$lock" "packages" "$name" "sha")"
            lock_upsert "$lock" "$name" "$requested" "$url" "$path" "$current" "$locked_sha"
            echo "  $name: request ${locked_requested:-<none>} -> ${requested:-<ref>} (kept $current)"
        fi
        moved=$((moved + 1))
        continue
    fi
    if [ "$tag" = "$current" ]; then
        echo "  $name: ${current:-<none>} (up to date)"
        continue
    fi
    if [ "$preview" -eq 1 ]; then
        echo "  $name: ${current:-<none>} -> $tag"
        moved=$((moved + 1))
        continue
    fi
    rel=".intelligence/packages/$name"
    # Fetch into staging FIRST: a failed clone must leave the current install
    # fully wired and intact. Only after success is the old shape unwired
    # (the new version may have dropped a section dir), the store swapped,
    # and the new shape wired.
    staging="$IP_ROOT/.intelligence/.staging-$$"
    rm -rf "$staging"
    sha="$(fetch_package "$url" "$tag" "$path" "$staging")"
    unwire_package_sources "$manifest" "$rel"
    rm -rf "${IP_ROOT:?}/$rel"
    mkdir -p "$(dirname "$IP_ROOT/$rel")"
    mv "$staging" "$IP_ROOT/$rel"
    wire_package_sources "$manifest" "$name" "$rel" "$IP_ROOT"
    lock_upsert "$lock" "$name" "$requested" "$url" "$path" "$tag" "$sha"
    echo "  $name: ${current:-<none>} -> $tag"
    moved=$((moved + 1))
done < <(qmap_keys "$manifest" "packages")

[ -n "$only" ] && [ "$found" -eq 0 ] && die "package '$only' is not in the manifest"
if [ "$preview" -eq 1 ]; then
    echo "updates available: $moved package(s)"
else
    echo "updated: $moved package(s)"
fi

if [ "$preview" -eq 0 ] && [ "$moved" -gt 0 ] && [ "$no_sync" -eq 0 ]; then
    exec bash "$CLI_DIR/commands/sync.sh"
fi
