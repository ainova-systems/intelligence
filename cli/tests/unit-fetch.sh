#!/bin/bash
# Exact-commit acquisition and offline bundle identity, using local Git objects.
set -euo pipefail
REPO="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
REPO="$(cd "$REPO" && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
CLI_DIR="$REPO/cli"
IS_ENGINE_DIR="$REPO/engine"
source "$CLI_DIR/lib/cli-common.sh"
fail=0
chk() { if ! "$@" >/dev/null 2>&1; then echo "FAIL: $*"; fail=1; fi; }
chknot() { if "$@" >/dev/null 2>&1; then echo "FAIL(not): $*"; fail=1; fi; }

fetch_test_git_mode=normal
git() {
    if [ "$fetch_test_git_mode" = refuse-direct ]; then
        case " $* " in
            *' fetch --quiet --no-tags --depth 1 -- '*) return 1 ;;
        esac
    elif [ "$fetch_test_git_mode" = trace ]; then
        printf 'called\n' >> "$OUT/git-calls"
    fi
    command git "$@"
}

PACK="$OUT/pack"
mkdir -p "$PACK/content/rules"
printf 'LOCKED_BYTES\n' > "$PACK/content/rules/rule.md"
command git -C "$PACK" init --quiet
command git -C "$PACK" -c user.email=t@t -c user.name=t add -A
command git -C "$PACK" -c user.email=t@t -c user.name=t commit --quiet -m first
FIRST="$(command git -C "$PACK" rev-parse HEAD)"
command git -C "$PACK" -c user.email=t@t -c user.name=t tag -a v1 -m first
TAG_OBJECT="$(command git -C "$PACK" rev-parse v1)"
printf 'NEW_BYTES\n' > "$PACK/content/rules/rule.md"
command git -C "$PACK" -c user.email=t@t -c user.name=t commit --quiet -am second
SECOND="$(command git -C "$PACK" rev-parse HEAD)"
URL="file://$PACK"

echo '== explicit commit acquisition preserves LF bytes under inherited Git settings =='
command git -C "$PACK" show "$FIRST:content/rules/rule.md" > "$OUT/expected-rule"
got="$(GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=core.autocrlf GIT_CONFIG_VALUE_0=true \
    GIT_CONFIG_KEY_1=core.eol GIT_CONFIG_VALUE_1=crlf \
    fetch_package "$URL" "$FIRST" content "$OUT/ref-sha")"
chk test "$got" = "$FIRST"
chk cmp -s "$OUT/expected-rule" "$OUT/ref-sha/rules/rule.md"

echo '== retained commit and subpath after a tag is deleted =='
command git -C "$PACK" tag -d v1 >/dev/null
got="$(fetch_package "$URL" v1 content "$OUT/restored" "$FIRST")"
chk test "$got" = "$FIRST"
chk grep -qx LOCKED_BYTES "$OUT/restored/rules/rule.md"
chknot test -e "$OUT/restored/.git"

echo '== server refusing direct SHA fetch still exposes retained history =='
# Inject a transport refusal for direct wants; all history acquisition uses Git.
fetch_test_git_mode=refuse-direct
got="$(fetch_package "$URL" v1 content "$OUT/fallback" "$FIRST")"
fetch_test_git_mode=normal
chk test "$got" = "$FIRST"
chk grep -qx LOCKED_BYTES "$OUT/fallback/rules/rule.md"

echo '== unavailable object, non-commit object and missing subpath preserve destination =='
for identity in 0000000000000000000000000000000000000000 "$TAG_OBJECT"; do
    if (fetch_package "$URL" HEAD content "$OUT/restored" "$identity") >"$OUT/result" 2>"$OUT/error"; then
        echo "FAIL: accepted unavailable/non-commit identity $identity"; fail=1
    fi
    chk grep -q "locked commit $identity unavailable" "$OUT/error"
    chk grep -qx LOCKED_BYTES "$OUT/restored/rules/rule.md"
done
if (fetch_package "$URL" HEAD absent "$OUT/restored" "$FIRST") >"$OUT/result" 2>"$OUT/error"; then
    echo 'FAIL: accepted missing subpath'; fail=1
fi
chk grep -q "path 'absent' not found" "$OUT/error"
chk grep -qx LOCKED_BYTES "$OUT/restored/rules/rule.md"

echo '== matching release bundle stays offline; mismatched identity fetches locked bytes =='
IS_ENGINE_DIR="$OUT/bundle-engine"
IS_BUNDLED_PKG_DIR="$OUT/bundle-content"
mkdir -p "$IS_ENGINE_DIR" "$IS_BUNDLED_PKG_DIR/rules"
printf '1.0.0\n' > "$IS_ENGINE_DIR/VERSION"
printf '%s\n' "$SECOND" > "$IS_ENGINE_DIR/ENGINE_SHA"
printf 'NEW_BYTES\n' > "$IS_BUNDLED_PKG_DIR/rules/rule.md"
export SYNC_PKG_URL="$URL" SYNC_PKG_PATH=content
fetch_test_git_mode=trace
got="$(fetch_package "$URL" v1.0.0 content "$OUT/bundled" "$SECOND" 2>"$OUT/error")"
chk test "$got" = "$SECOND"
chk grep -qx NEW_BYTES "$OUT/bundled/rules/rule.md"
chknot test -s "$OUT/error"
chknot test -e "$OUT/git-calls"
got="$(fetch_package "$URL" v1.0.0 content "$OUT/bundled" "$FIRST")"
chk test "$got" = "$FIRST"
chk grep -qx LOCKED_BYTES "$OUT/bundled/rules/rule.md"
chk test -s "$OUT/git-calls"
if (fetch_package "$URL" v1.0.0 content "$OUT/bundled" 0000000000000000000000000000000000000000) >"$OUT/result" 2>"$OUT/error"; then
    echo 'FAIL: unavailable bundle identity was substituted'; fail=1
fi
chk grep -q 'locked commit .* unavailable' "$OUT/error"
chk grep -qx LOCKED_BYTES "$OUT/bundled/rules/rule.md"
fetch_test_git_mode=normal

echo '== development lock and bundle exceptions warn without claiming verification =='
rm -f "$OUT/git-calls"
fetch_test_git_mode=trace
got="$(fetch_package "$URL" v1.0.0 content "$OUT/bundled" '' 2>"$OUT/error")"
chk test "$got" = "$SECOND"
chk grep -q 'without commit verification' "$OUT/error"
rm -f "$IS_ENGINE_DIR/ENGINE_SHA"
got="$(fetch_package "$URL" v1.0.0 content "$OUT/bundled" "$FIRST" 2>"$OUT/error")"
chk test -z "$got"
chk grep -qx NEW_BYTES "$OUT/bundled/rules/rule.md"
chk grep -q 'without commit verification' "$OUT/error"
chknot test -e "$OUT/git-calls"
fetch_test_git_mode=normal

[ "$fail" -ne 0 ] || echo 'UNIT-FETCH: ALL OK'
exit "$fail"
