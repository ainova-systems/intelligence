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

# move_label <ref-or-empty> <from-resolved> <to-resolved> <from-sha> <to-sha>
# A version pin moves between tags, a ref pin between commits under one name —
# printing "main -> main" would report the move by hiding what moved.
move_label() {
    local ref="$1" from="$2" to="$3" from_sha="$4" to_sha="$5"
    if [ -z "$ref" ]; then
        printf '%s -> %s' "${from:-<none>}" "$to"
    elif [ -n "$from" ] && [ "$from" != "$ref" ]; then
        printf '%s -> %s@%s' "$from" "$ref" "$(short_sha "$to_sha")"
    else
        printf '%s %s -> %s' "$ref" "$(short_sha "$from_sha")" "$(short_sha "$to_sha")"
    fi
}

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
    locked_sha="$(qmap_field "$lock" "packages" "$name" "sha")"
    url="$(qmap_field "$lock" "packages" "$name" "url")"
    path="$(qmap_field "$lock" "packages" "$name" "path")"
    [ -n "$url" ] || die "$name has no source in intelligence.lock — restore the committed lock or re-add the package"
    ref="$(qmap_field "$manifest" "packages" "$name" "ref")"
    range="$(qmap_field "$manifest" "packages" "$name" "version")"
    [ -n "$ref" ] || [ -n "$range" ] || die "$name has neither version nor ref in the manifest"

    ref_moved=0 remote_sha=""
    if [ -n "$ref" ]; then
        tag="$ref"
        requested=""
        # A ref is requested INTENT, and the lock's `resolved` column holds
        # that same ref name — comparing the two asks a question no branch can
        # ever answer differently. The sha column is the only record of where
        # the ref actually pointed, so a ref pin is compared commit to commit:
        # a moved branch, a re-cut tag and a `HEAD` pin all become visible,
        # while a pin that IS a commit stays immutable by construction.
        probe_rc=0
        remote_sha="$(remote_sha_for_ref "$url" "$ref")" || probe_rc=$?
        if [ "$probe_rc" -ne 0 ]; then
            # No answer is not "no change": reporting up to date here would
            # freeze the pin exactly as the ref-name comparison used to.
            echo "  WARN: $name: cannot reach $url — ref '$ref' was not checked" >&2
            echo "  $name: $ref (not checked — remote unreachable)"
            continue
        fi
        # ls-remote advertises refs, not arbitrary objects, so a commit pin
        # legitimately matches nothing — and cannot move. This verdict applies
        # only once the lock already resolved to this ref; a manifest that now
        # names a ref the lock never resolved is an ordinary move, and falls
        # through to the fetch below.
        if [ -z "$remote_sha" ] && [ "$ref" = "$current" ]; then
            # The lock records the commit this ref resolved to, so a ref that
            # prefixes it IS that commit. Asking the lock beats guessing from
            # the ref's shape: a deleted branch named like a hex string would
            # otherwise pass for a pin and swallow its own disappearance.
            case "$locked_sha" in
                "$ref"*)
                    echo "  $name: $(short_sha "$ref") (pinned commit)"
                    ;;
                *)
                    echo "  WARN: $name pins ref '$ref', which $url no longer advertises" >&2
                    echo "  $name: $ref (unresolvable — gone upstream)"
                    ;;
            esac
            continue
        fi
        [ -z "$remote_sha" ] || [ "$remote_sha" = "$locked_sha" ] || ref_moved=1
    else
        picked="$(list_remote_versions "$url" | semver_pick_highest "$range")"
        [ -n "$picked" ] || { echo "  $name: nothing satisfies '$range' at $url" >&2; continue; }
        read -r tag _ <<< "$(remote_tag_for_version "$url" "$picked")"
        requested="$range"
    fi
    if [ "$ref_moved" -eq 0 ] && [ "$tag" = "$current" ] && [ "$requested" != "$locked_requested" ]; then
        if [ "$preview" -eq 1 ]; then
            echo "  $name: request ${locked_requested:-<none>} -> ${requested:-<ref>} (keeps $current)"
        else
            lock_upsert "$lock" "$name" "$requested" "$url" "$path" "$current" "$locked_sha"
            echo "  $name: request ${locked_requested:-<none>} -> ${requested:-<ref>} (kept $current)"
        fi
        moved=$((moved + 1))
        continue
    fi
    if [ "$ref_moved" -eq 0 ] && [ "$tag" = "$current" ]; then
        echo "  $name: $(pin_label "$ref" "$current" "$locked_sha") (up to date)"
        continue
    fi
    if [ "$preview" -eq 1 ]; then
        echo "  $name: $(move_label "$ref" "$current" "$tag" "$locked_sha" "$remote_sha")"
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
    echo "  $name: $(move_label "$ref" "$current" "$tag" "$locked_sha" "$sha")"
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
