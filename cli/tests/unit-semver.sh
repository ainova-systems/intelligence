#!/bin/bash
# Table-driven unit suite for cli/lib/semver.sh: semver_cmp / semver_is_stable /
# semver_match / semver_pick_highest, plus list_remote_versions and
# remote_tag_for_version against a local file:// git fixture (no network).
set -euo pipefail
REPO="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
fail=0
chk() { if ! "$@" >/dev/null 2>&1; then echo "FAIL: $*"; fail=1; fi; }
chknot() { if "$@" >/dev/null 2>&1; then echo "FAIL(not): $*"; fail=1; fi; }

export CLI_DIR="$REPO/cli"
export IS_ENGINE_DIR="$REPO/engine"
source "$CLI_DIR/lib/cli-common.sh"

case_count=0

# run_case <kind> <a> <b> <expected>
#   cmp    a=left    b=right          expected = printed -1/0/1
#   stable a=version b=(unused)       expected = ok|no  (rc 0 / rc !=0)
#   match  a=version b=range          expected = ok|no  (rc 0 / rc !=0)
#   pick   a=range   b=comma-list     expected = printed version ('' when none)
#
# The `~` cases below are hard assertions, and they guard a real regression:
# an unquoted `~` in semver.sh's `${range#~}` is a tilde EXPANSION, which left
# every `~x.y.z` range matching nothing (fixed in 0.11.0 by quoting it).
run_case() {
    local kind="$1" a="$2" b="$3" exp="$4" got
    case_count=$((case_count + 1))
    case "$kind" in
        cmp)
            got="$(semver_cmp "$a" "$b")"
            [ "$got" = "$exp" ] || { echo "FAIL: cmp '$a' '$b' -> '$got' want '$exp'"; fail=1; }
            ;;
        stable)
            if semver_is_stable "$a"; then got=ok; else got=no; fi
            [ "$got" = "$exp" ] || { echo "FAIL: stable '$a' -> $got want $exp"; fail=1; }
            ;;
        match)
            if semver_match "$a" "$b"; then got=ok; else got=no; fi
            [ "$got" = "$exp" ] || { echo "FAIL: match '$a' range '$b' -> $got want $exp"; fail=1; }
            ;;
        pick)
            got="$(printf '%s\n' "$b" | tr ',' '\n' | semver_pick_highest "$a")"
            [ "$got" = "$exp" ] || { echo "FAIL: pick '$a' <- '$b' -> '$got' want '$exp'"; fail=1; }
            ;;
        *)
            echo "FAIL: unknown case kind '$kind'"; fail=1
            ;;
    esac
}

# eq_case <desc> <got> <want> — exact-string assertion for the git fixture part.
eq_case() {
    case_count=$((case_count + 1))
    if [ "$2" != "$3" ]; then echo "FAIL: $1: got '$2' want '$3'"; fail=1; fi
}

echo "== table: cmp / stable / match / pick =="
while IFS='|' read -r kind a b exp; do
    case "$kind" in ''|'#'*) continue ;; esac
    run_case "$kind" "$a" "$b" "$exp"
done <<'CASES'
# --- semver_cmp: equal / greater / less on each field, v-mixing, short forms
cmp|1.2.3|1.2.3|0
cmp|2.0.0|1.9.9|1
cmp|1.9.9|2.0.0|-1
cmp|1.3.0|1.2.9|1
cmp|1.2.9|1.3.0|-1
cmp|1.2.4|1.2.3|1
cmp|1.2.3|1.2.4|-1
cmp|v1.2.3|1.2.3|0
cmp|1.2.3|v1.2.3|0
cmp|v2.0.0|v1.9.9|1
cmp|10.0.0|9.9.9|1
cmp|1.2|1.2.0|0
cmp|1|1.0.0|0
cmp|1.2|1.2.1|-1
# --- semver_is_stable: [v]x.y.z only
stable|1.2.3||ok
stable|v1.2.3||ok
stable|0.0.0||ok
stable|1.2||no
stable|1.2.||no
stable|1.2.3-rc.1||no
stable|1.2.3.4||no
stable|abc||no
stable|v||no
stable|||no
# --- semver_match: empty / star / latest / exact
match|1.2.3||ok
match|1.2.3|*|ok
match|1.2.3|latest|ok
match|1.2.3|1.2.3|ok
match|v1.2.3|1.2.3|ok
match|1.2.3|v1.2.3|ok
match|1.2.4|1.2.3|no
# --- caret, npm 0.x semantics
match|1.2.3|^1.2.3|ok
match|1.9.9|^1.2.3|ok
match|2.0.0|^1.2.3|no
match|1.2.2|^1.2.3|no
match|1.5.0|^v1.2.3|ok
match|0.2.3|^0.2.3|ok
match|0.2.9|^0.2.3|ok
match|0.3.0|^0.2.3|no
match|0.2.2|^0.2.3|no
match|0.0.3|^0.0.3|ok
match|0.0.4|^0.0.3|no
match|0.0.2|^0.0.3|no
# --- tilde: same major.minor, at or above the base
match|1.2.3|~1.2.3|ok
match|1.2.9|~1.2.3|ok
match|1.3.0|~1.2.3|no
match|1.2.2|~1.2.3|no
# --- prereleases never match; malformed range base never matches
match|1.2.3-rc.1|*|no
match|1.2.3-rc.1|^1.0.0|no
match|1.2.3|^1.2|no
# --- semver_pick_highest: unsorted stdin, numeric-not-lexical, empty result
pick|*|1.0.0,10.0.0,9.9.9,2.0.0|10.0.0
pick|^1.2.0|1.1.0,1.9.9,1.2.0,2.0.0|1.9.9
pick|~1.2.0|1.3.0,1.2.0,1.2.5|1.2.5
pick|^3.0.0|1.0.0,2.0.0|
pick|*|2.0.0-rc.1,1.0.0|1.0.0
pick|latest|0.1.0,0.2.0|0.2.0
CASES

echo "== fixture repo: list_remote_versions / remote_tag_for_version =="
FIX="$OUT/pack"
mkdir -p "$FIX"
printf 'one\n' > "$FIX/file.txt"
git -C "$FIX" init --quiet
git -C "$FIX" -c user.email=t@t -c user.name=t add -A
git -C "$FIX" -c user.email=t@t -c user.name=t commit --quiet -m c1
git -C "$FIX" tag v1.0.0
git -C "$FIX" tag 1.1.0
git -C "$FIX" tag v2.0.0-rc.1
git -C "$FIX" tag release
printf 'two\n' > "$FIX/file.txt"
git -C "$FIX" -c user.email=t@t -c user.name=t commit --quiet -am c2
git -C "$FIX" -c user.email=t@t -c user.name=t tag -a v1.2.0 -m msg
FIX_URL="file://$FIX"

C1_SHA="$(git -C "$FIX" rev-parse v1.0.0)"
TAG_OBJ="$(git -C "$FIX" rev-parse v1.2.0)"
C2_SHA="$(git -C "$FIX" rev-parse "v1.2.0^{commit}")"
# fixture sanity: annotated tag really is a tag object, not the commit itself
eq_case "fixture v1.2.0 is annotated" "$([ "$TAG_OBJ" != "$C2_SHA" ] && echo distinct)" "distinct"

# exact list: v stripped, prerelease + non-version tags gone, peeled refs
# collapsed so the annotated 1.2.0 shows up exactly once
lv="$(list_remote_versions "$FIX_URL" | sort)"
eq_case "list_remote_versions" "$lv" "$(printf '1.0.0\n1.1.0\n1.2.0')"
printf '%s\n' "$lv" > "$OUT/versions.txt"
chk grep -qx '1.0.0' "$OUT/versions.txt"
chk grep -qx '1.1.0' "$OUT/versions.txt"
chk grep -qx '1.2.0' "$OUT/versions.txt"
chknot grep -q '2.0.0' "$OUT/versions.txt"
chknot grep -q 'release' "$OUT/versions.txt"
case_count=$((case_count + 5))

# annotated tag: the peeled COMMIT sha must win over the tag-object sha
eq_case "remote_tag_for_version annotated" \
    "$(remote_tag_for_version "$FIX_URL" 1.2.0)" "v1.2.0 $C2_SHA"
# lightweight tag without the v prefix keeps its literal tag name
eq_case "remote_tag_for_version no-v tag" \
    "$(remote_tag_for_version "$FIX_URL" 1.1.0)" "1.1.0 $C1_SHA"
# a v-prefixed request resolves the v-prefixed tag
eq_case "remote_tag_for_version v-request" \
    "$(remote_tag_for_version "$FIX_URL" v1.0.0)" "v1.0.0 $C1_SHA"
# unknown version -> empty output
eq_case "remote_tag_for_version missing" \
    "$(remote_tag_for_version "$FIX_URL" 9.9.9)" ""
# picking against the fixture's real tag list honours the caret range
eq_case "pick over remote list" \
    "$(list_remote_versions "$FIX_URL" | semver_pick_highest '^1.0.0')" "1.2.0"

echo "cases: $case_count"
[ "$fail" -eq 0 ] && echo "UNIT-SEMVER: ALL OK"
exit "$fail"
