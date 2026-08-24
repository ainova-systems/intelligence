#!/bin/bash
# intelligence install [--frozen] [--force] [--no-sync]
#
# Restore .intelligence/ from intelligence.lock — the fresh-clone command.
# --frozen additionally refuses any manifest/lock divergence (CI mode) and
# fails on a sha mismatch instead of re-resolving.
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

frozen=0 force=0 no_sync=0
while [ $# -gt 0 ]; do
    case "$1" in
        --frozen) frozen=1 ;;
        --force) force=1 ;;
        --no-sync) no_sync=1 ;;
        *) die "unknown option '$1'" ;;
    esac
    shift || true
done

require_v2
manifest="$IP_ROOT/intelligence.yaml"
lock="$IP_ROOT/intelligence.lock"

ensure_engine_staged "$IP_ROOT"

# Manifest packages missing from the lock: resolve them now (npm install
# semantics). Under --frozen that is an error instead.
missing=""
while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ ! -f "$lock" ] || [ -z "$(qmap_field "$lock" "packages" "$name" "url")" ]; then
        missing="$missing $name"
    fi
done < <(qmap_keys "$manifest" "packages")
if [ -n "$missing" ]; then
    [ "$frozen" -eq 1 ] && die "lockfile is missing packages:$missing — run 'intelligence install' without --frozen"
    for name in $missing; do
        url="$(qmap_field "$manifest" "packages" "$name" "url")"
        path="$(qmap_field "$manifest" "packages" "$name" "path")"
        ref="$(qmap_field "$manifest" "packages" "$name" "ref")"
        range="$(qmap_field "$manifest" "packages" "$name" "version")"
        if [ -z "$url" ]; then
            resolve_package_source "$manifest" "$name"
            url="$RES_URL"; path="$RES_PATH"
        fi
        resolved_tag=""
        if [ -z "$ref" ]; then
            picked="$(list_remote_versions "$url" | semver_pick_highest "$range")"
            [ -n "$picked" ] || die "no tag of $url satisfies '${range:-*}' for $name"
            read -r resolved_tag _ <<< "$(remote_tag_for_version "$url" "$picked")"
        fi
        rel=".intelligence/packages/$name"
        sha="$(fetch_package "$url" "${ref:-$resolved_tag}" "$path" "$IP_ROOT/$rel")"
        wire_package_sources "$manifest" "$name" "$rel" "$IP_ROOT"
        lock_upsert "$lock" "$name" "$range" "$url" "$path" "${ref:-$resolved_tag}" "$sha"
        echo "+ $name@${resolved_tag:-${ref:-HEAD}} (resolved)"
    done
fi

# Restore every locked package that is not already in the store.
if [ -f "$lock" ]; then
    while IFS="$LOCK_SEP" read -r name requested url path resolved sha; do
        [ -n "$name" ] || continue
        rel=".intelligence/packages/$name"
        if [ -d "$IP_ROOT/$rel" ] && [ "$force" -eq 0 ]; then
            continue
        fi
        got="$(fetch_package "$url" "$resolved" "$path" "$IP_ROOT/$rel")"
        if [ -n "$sha" ] && [ "$got" != "$sha" ]; then
            if [ "$frozen" -eq 1 ]; then
                die "$name: fetched $got but the lock pins $sha — the ref moved; refusing under --frozen"
            fi
            echo "  WARN: $name resolved to $got, lock had $sha — updating the lock" >&2
            lock_upsert "$lock" "$name" "$requested" "$url" "$path" "$resolved" "$got"
        fi
        wire_package_sources "$manifest" "$name" "$rel" "$IP_ROOT"
        echo "= $name@${resolved:-HEAD}"
    done < <(lock_to_tsv "$lock")
fi

if [ "$no_sync" -eq 0 ]; then
    exec bash "$CLI_DIR/commands/sync.sh"
fi
