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
        echo "  $name: engine content moves with the engine — 'intelligence upgrade' owns it"
        continue
    fi
    ref="$(qmap_field "$manifest" "packages" "$name" "ref")"
    [ -n "$ref" ] && { echo "  $name: pinned to ref '$ref' — skipped"; continue; }
    range="$(qmap_field "$manifest" "packages" "$name" "version")"
    # An exact version is a pin, same as ref: — update never moves pins.
    if [ -n "$range" ] && semver_is_stable "$range"; then
        echo "  $name: pinned to $range — edit the manifest to move it"
        continue
    fi
    url="$(qmap_field "$manifest" "packages" "$name" "url")"
    path="$(qmap_field "$manifest" "packages" "$name" "path")"
    if [ -z "$url" ]; then
        resolve_package_source "$manifest" "$name"
        url="$RES_URL"; path="$RES_PATH"
    fi
    picked="$(list_remote_versions "$url" | semver_pick_highest "$range")"
    [ -n "$picked" ] || { echo "  $name: nothing satisfies '${range:-*}' at $url" >&2; continue; }
    read -r tag _ <<< "$(remote_tag_for_version "$url" "$picked")"
    current="$(qmap_field "$lock" "packages" "$name" "resolved")"
    cur_url="$(qmap_field "$lock" "packages" "$name" "url")"
    cur_path="$(qmap_field "$lock" "packages" "$name" "path")"
    # Same tag is not enough: a registry may re-point a name's source while
    # keeping the version — the move doctor warns about must be actionable
    # here, so url/path changes refetch too.
    if [ "$tag" = "$current" ] && [ "$url" = "$cur_url" ] && [ "$path" = "$cur_path" ]; then
        echo "  $name: ${current:-<none>} (up to date)"
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
    lock_upsert "$lock" "$name" "$range" "$url" "$path" "$tag" "$sha"
    echo "  $name: ${current:-<none>} -> $tag"
    moved=$((moved + 1))
done < <(qmap_keys "$manifest" "packages")

[ -n "$only" ] && [ "$found" -eq 0 ] && die "package '$only' is not in the manifest"
echo "updated: $moved package(s)"

if [ "$moved" -gt 0 ] && [ "$no_sync" -eq 0 ]; then
    exec bash "$CLI_DIR/commands/sync.sh"
fi
