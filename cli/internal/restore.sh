#!/bin/bash
# Internal locked-store restore operation.
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

# --frozen is the reproducibility contract: the lock must agree with the
# manifest on the package SET and on every requested-source field before a
# single byte is restored. Anything less lets a manifest edit ride on a stale
# lock — the exact drift the flag exists to refuse.
if [ "$frozen" -eq 1 ]; then
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        [ -n "$(qmap_field "$lock" "packages" "$name" "url")" ] \
            || die "locked restore: $name is in the manifest but not in intelligence.lock"
        m_ver="$(qmap_field "$manifest" "packages" "$name" "version")"
        m_ref="$(qmap_field "$manifest" "packages" "$name" "ref")"
        m_url="$(qmap_field "$manifest" "packages" "$name" "url")"
        m_path="$(qmap_field "$manifest" "packages" "$name" "path")"
        l_req="$(qmap_field "$lock" "packages" "$name" "requested")"
        l_res="$(qmap_field "$lock" "packages" "$name" "resolved")"
        l_url="$(qmap_field "$lock" "packages" "$name" "url")"
        l_path="$(qmap_field "$lock" "packages" "$name" "path")"
        [ -z "$m_ver" ] || [ "$m_ver" = "$l_req" ] \
            || die "locked restore: $name requests '$m_ver' but the lock recorded '$l_req' — reconcile the manifest and lock"
        [ -z "$m_ref" ] || [ "$m_ref" = "$l_res" ] \
            || die "--frozen: $name pins ref '$m_ref' but the lock resolved '$l_res'"
        [ -z "$m_url" ] || [ "$m_url" = "$l_url" ] \
            || die "--frozen: $name declares url '$m_url' but the lock recorded '$l_url'"
        [ -z "$m_path" ] || [ "$m_path" = "$l_path" ] \
            || die "--frozen: $name declares path '$m_path' but the lock recorded '$l_path'"
    done < <(qmap_keys "$manifest" "packages")
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        found=0
        while IFS= read -r m; do
            [ "$m" = "$name" ] && found=1
        done < <(qmap_keys "$manifest" "packages")
        [ "$found" -eq 1 ] || die "--frozen: $name is locked but absent from the manifest"
    done < <(qmap_keys "$lock" "packages")
fi

# Manifest packages missing from the lock: resolve them now (npm install
# semantics). Under --frozen the drift gate above has already refused.
missing=""
while IFS= read -r name; do
    [ -n "$name" ] || continue
    assert_valid_pkg_name "$name"
    if [ ! -f "$lock" ] || [ -z "$(qmap_field "$lock" "packages" "$name" "url")" ]; then
        missing="$missing $name"
    fi
done < <(qmap_keys "$manifest" "packages")
if [ -n "$missing" ]; then
    for name in $missing; do
        # The engine-content package needs no remote resolution: its pin IS
        # the bundled engine version and it seeds from the bundle, offline.
        if [ "$name" = "$SYNC_PKG_NAME" ]; then
            sync_pkg_install "$IP_ROOT"
            continue
        fi
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
        # The lock arrives with a cloned repo — its keys are untrusted input
        # on their way into rm -rf paths, and its urls into git argv.
        assert_valid_pkg_name "$name"
        rel=".intelligence/packages/$name"
        # --frozen never trusts what is already on disk: a pre-existing
        # (possibly substituted) store dir would otherwise be synced with no
        # sha verification at all.
        if [ -d "$IP_ROOT/$rel" ] && [ "$force" -eq 0 ] && [ "$frozen" -eq 0 ]; then
            continue
        fi
        # Fetch into staging and commit to the store only after the integrity
        # verdict: content that violates the lock must never be left where a
        # re-run (whose dir-exists check skips verification) would sync it.
        staging="$IP_ROOT/.intelligence/.staging-$$"
        rm -rf "$staging"
        got="$(fetch_package "$url" "$resolved" "$path" "$staging")"
        # An empty sha (bundle-seeded content on a dev build) means unknown,
        # not moved — only two known-and-different shas are a finding.
        if [ -n "$sha" ] && [ -n "$got" ] && [ "$got" != "$sha" ]; then
            if [ "$frozen" -eq 1 ]; then
                rm -rf "$staging"
                die "$name: fetched $got but the lock pins $sha — the ref moved; refusing under --frozen"
            fi
            echo "  WARN: $name resolved to $got, lock had $sha — updating the lock" >&2
            lock_upsert "$lock" "$name" "$requested" "$url" "$path" "$resolved" "$got"
        fi
        rm -rf "${IP_ROOT:?}/$rel"
        mkdir -p "$(dirname "$IP_ROOT/$rel")"
        mv "$staging" "$IP_ROOT/$rel"
        wire_package_sources "$manifest" "$name" "$rel" "$IP_ROOT"
        echo "= $name@${resolved:-HEAD}"
    done < <(lock_to_tsv "$lock")
fi

if [ "$no_sync" -eq 0 ]; then
    exec bash "$CLI_DIR/commands/sync.sh"
fi
