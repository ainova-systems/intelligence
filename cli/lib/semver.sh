#!/bin/bash
# Semver over git tags — the whole version story of Intelligence Packages.
#
# Ranges match STABLE x.y.z versions only (an optional leading `v` is
# stripped); prerelease/build-suffixed tags are ignored, matching the
# engine's own digits-only comparator (`_ver_gt`) and BSD sort's lack of
# `sort -V`. A branch or SHA pin is expressed with `ref:` instead of a range.

# semver_cmp <a> <b> — prints -1 / 0 / 1.
semver_cmp() {
    awk -v a="${1#v}" -v b="${2#v}" '
        BEGIN {
            na = split(a, A, "."); nb = split(b, B, ".")
            for (i = 1; i <= 3; i++) {
                x = (i <= na) ? A[i] + 0 : 0
                y = (i <= nb) ? B[i] + 0 : 0
                if (x < y) { print -1; exit }
                if (x > y) { print 1; exit }
            }
            print 0
        }'
}

# semver_is_stable <version> — 0 iff `[v]x.y.z` with nothing else.
semver_is_stable() {
    case "${1#v}" in
        *[!0-9.]*) return 1 ;;
    esac
    awk -v v="${1#v}" 'BEGIN { exit (split(v, P, ".") == 3 && P[1] != "" && P[2] != "" && P[3] != "") ? 0 : 1 }'
}

# semver_match <version> <range> — 0 iff the stable version satisfies the range.
# Ranges: `*`/`latest` (any), exact `1.2.3`, `^1.2.3` (npm caret, incl. the
# 0.x rules), `~1.2.3` (same minor).
semver_match() {
    local v="${1#v}" range="$2"
    semver_is_stable "$v" || return 1
    case "$range" in
        ""|"*"|latest) return 0 ;;
    esac
    local op="" base="$range"
    # Both strip patterns are quoted: an unquoted `~` in ${range#~} is a tilde
    # EXPANSION (it becomes $HOME), so the prefix never strips and every
    # `~x.y.z` range silently matches nothing.
    case "$range" in
        "^"*) op="^"; base="${range#'^'}" ;;
        "~"*) op="~"; base="${range#'~'}" ;;
    esac
    base="${base#v}"
    semver_is_stable "$base" || return 1
    awk -v v="$v" -v base="$base" -v op="$op" '
        BEGIN {
            split(v, V, "."); split(base, B, ".")
            for (i = 1; i <= 3; i++) { V[i] += 0; B[i] += 0 }
            # below the base -> never a match
            for (i = 1; i <= 3; i++) {
                if (V[i] < B[i]) exit 1
                if (V[i] > B[i]) break
            }
            if (op == "") {
                exit (V[1] == B[1] && V[2] == B[2] && V[3] == B[3]) ? 0 : 1
            }
            if (op == "~") {
                exit (V[1] == B[1] && V[2] == B[2]) ? 0 : 1
            }
            # caret: everything up to the next left-most non-zero digit bump
            if (B[1] != 0) exit (V[1] == B[1]) ? 0 : 1
            if (B[2] != 0) exit (V[1] == 0 && V[2] == B[2]) ? 0 : 1
            exit (V[1] == 0 && V[2] == 0 && V[3] == B[3]) ? 0 : 1
        }'
}

# list_remote_versions <git-url> — stable versions from remote tags, one per
# line, `v` stripped, unsorted, deduplicated. Peeled refs (`^{}`) collapse
# onto their tag.
list_remote_versions() {
    local url="$1"
    assert_safe_source_url "$url"
    # `|| true` inside the pipeline: an unreachable repo must read as "no
    # versions", not kill a pipefail caller mid-command-substitution —
    # reachability is the CALLER's question (add probes it explicitly).
    { GIT_TERMINAL_PROMPT=0 git ls-remote --tags -- "$url" 2>/dev/null || true; } \
        | awk '{
            sub(/\r$/, "")
            ref = $2
            sub(/\^\{\}$/, "", ref)
            n = split(ref, P, "/")
            t = P[n]
            sub(/^v/, "", t)
            if (t ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ && !(t in seen)) { seen[t] = 1; print t }
        }'
}

# remote_tag_for_version <git-url> <version> — the actual tag name (with or
# without `v`) a stable version came from, and its commit sha:
# prints "<tag> <sha>". Peeled sha (the commit a tag object points at) wins.
remote_tag_for_version() {
    local url="$1" ver="${2#v}"
    assert_safe_source_url "$url"
    { GIT_TERMINAL_PROMPT=0 git ls-remote --tags -- "$url" 2>/dev/null || true; } \
        | awk -v want="$ver" '
            {
                sub(/\r$/, "")
                ref = $2; peeled = 0
                if (sub(/\^\{\}$/, "", ref)) peeled = 1
                n = split(ref, P, "/")
                tag = P[n]
                t = tag
                sub(/^v/, "", t)
                if (t != want) next
                if (peeled) { psha[tag] = $1 } else { sha[tag] = $1; order[++cnt] = tag }
            }
            END {
                for (i = 1; i <= cnt; i++) {
                    tag = order[i]
                    s = (tag in psha) ? psha[tag] : sha[tag]
                    print tag " " s
                    exit
                }
            }'
}

# semver_pick_highest <range> — reads versions on stdin, prints the highest
# one matching the range (empty output when nothing matches).
semver_pick_highest() {
    local range="$1" best="" v
    while IFS= read -r v; do
        [ -n "$v" ] || continue
        semver_match "$v" "$range" || continue
        if [ -z "$best" ] || [ "$(semver_cmp "$v" "$best")" = "1" ]; then
            best="$v"
        fi
    done
    printf '%s' "$best"
}
