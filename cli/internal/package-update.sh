#!/bin/bash
# Internal package range update operation.
#
# Resolve requested versions/refs against each package's locked source and
# rewrite the lock. `update <name>` limits the pass to one package; re-adding
# is the explicit operation for changing a source URL/path.
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

only="" no_sync=0 preview=0 latest=0
while [ $# -gt 0 ]; do
    case "$1" in
        --no-sync) no_sync=1 ;;
        --preview) preview=1 ;;
        --latest) latest=1 ;;
        @*) only="$1" ;;
        *) die "unknown argument '$1'" ;;
    esac
    shift || true
done
# Crossing a range is per package on purpose: each boundary SemVer marks is a
# changelog to read, so a blanket sweep would be one confirmation for several
# unrelated decisions.
[ "$latest" -eq 0 ] || [ -n "$only" ] \
    || die "--latest needs the package to move: intelligence update @scope/name --latest"

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

moved=0 found=0 outside=0
while IFS= read -r name; do
    [ -n "$name" ] || continue
    # Manifest keys are untrusted input on their way into store paths.
    assert_valid_pkg_name "$name"
    [ -n "$only" ] && [ "$name" != "$only" ] && continue
    # A named package that exists is "found" whatever happens next — a skip
    # message followed by "not in the manifest" would contradict itself.
    found=1
    if [ "$name" = "$SYNC_PKG_NAME" ]; then
        [ "$latest" -eq 0 ] \
            || die "$name is the engine content package — its pin follows the installed CLI; use 'intelligence upgrade'"
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

    ref_moved=0 remote_sha="" beyond="" range_move=""
    [ "$latest" -eq 0 ] || [ -z "$ref" ] \
        || die "$name is pinned to ref '$ref', not a version range — a ref pin is frozen by intent; re-add the package to change it"
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
        # One remote read answers both questions: what the range selects, and
        # what it excludes.
        versions="$(list_remote_versions "$url")"
        picked="$(printf '%s\n' "$versions" | semver_pick_highest "$range")"
        [ -n "$picked" ] || { echo "  $name: nothing satisfies '$range' at $url" >&2; continue; }
        read -r tag _ <<< "$(remote_tag_for_version "$url" "$picked")"
        requested="$range"
        # A range is a ceiling as much as a floor, and on a 0.x package the
        # caret stops at the minor: a project sits on 0.4.x while 0.6.1 ships
        # and every plan still reads "up to date". Name what the range leaves
        # out. Crossing it edits requested intent, which is a manifest change
        # and never this command's to make.
        newest="$(printf '%s\n' "$versions" | semver_pick_highest "latest")"
        if [ -n "$newest" ] && [ "$(semver_cmp "$newest" "$picked")" = "1" ]; then
            if [ "$latest" -eq 1 ]; then
                # Asked for by name: take the newest and widen the recorded
                # intent to match, keeping the caret so the next boundary is
                # still a decision. The manifest keeps saying what the project
                # asked for — that is what makes the move reviewable.
                picked="$newest"
                read -r tag _ <<< "$(remote_tag_for_version "$url" "$picked")"
                requested="^$newest"
                range_move=" (range $range -> $requested)"
            else
                beyond=" — $newest available outside '$range'"
                beyond="$beyond
      follow it: intelligence update $name --latest"
                outside=$((outside + 1))
            fi
        fi
        # When the newest version is already inside the range there is nothing
        # to cross: `--latest` falls through to the ordinary comparison, which
        # still installs a move the lock is behind on and still widens nothing.
    fi
    if [ "$ref_moved" -eq 0 ] && [ "$tag" = "$current" ] && [ "$requested" != "$locked_requested" ]; then
        if [ "$preview" -eq 1 ]; then
            echo "  $name: request ${locked_requested:-<none>} -> ${requested:-<ref>} (keeps $current)$beyond"
        else
            lock_upsert "$lock" "$name" "$requested" "$url" "$path" "$current" "$locked_sha"
            echo "  $name: request ${locked_requested:-<none>} -> ${requested:-<ref>} (kept $current)$beyond"
        fi
        moved=$((moved + 1))
        continue
    fi
    if [ "$ref_moved" -eq 0 ] && [ "$tag" = "$current" ]; then
        echo "  $name: $(pin_label "$ref" "$current" "$locked_sha") (up to date)$beyond"
        continue
    fi
    if [ "$preview" -eq 1 ]; then
        echo "  $name: $(move_label "$ref" "$current" "$tag" "$locked_sha" "$remote_sha")$range_move$beyond"
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
    # The widened intent is recorded only once its content is installed and
    # wired: a manifest saying ^0.6.1 over a failed fetch would describe a
    # state the project never reached.
    [ -z "$range_move" ] || qmap_set "$manifest" "packages" "$name" "version" "$requested"
    echo "  $name: $(move_label "$ref" "$current" "$tag" "$locked_sha" "$sha")$range_move$beyond"
    moved=$((moved + 1))
done < <(qmap_keys "$manifest" "packages")

[ -n "$only" ] && [ "$found" -eq 0 ] && die "package '$only' is not in the manifest"
if [ "$preview" -eq 1 ]; then
    echo "updates available: $moved package(s)"
else
    echo "updated: $moved package(s)"
fi
# Counted apart from the movable ones: no mode of this command installs these,
# so folding them into "updates available" would promise work --apply skips.
if [ "$outside" -gt 0 ]; then
    echo "outside the requested range: $outside package(s) — read the changelog, then run the 'follow it' command above"
fi

if [ "$preview" -eq 0 ] && [ "$moved" -gt 0 ] && [ "$no_sync" -eq 0 ]; then
    exec bash "$CLI_DIR/commands/sync.sh"
fi
