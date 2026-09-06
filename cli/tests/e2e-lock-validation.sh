#!/bin/bash
# Lockfile validation must fail before lifecycle commands mutate a project.
# Fixtures are local file:// repositories; no network access is required.
set -euo pipefail
unset CI
REPO="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
REPO="$(cd "$REPO" && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
CLI="$REPO/cli/intelligence"
ENGINE_VER="$(tr -d ' \t\r\n' < "$REPO/engine/VERSION")"
IFS=. read -r ENGINE_MAJOR ENGINE_MINOR ENGINE_PATCH <<< "$ENGINE_VER"
if [ "$ENGINE_PATCH" -gt 0 ]; then
    old_engine="$ENGINE_MAJOR.$ENGINE_MINOR.$((ENGINE_PATCH - 1))"
elif [ "$ENGINE_MINOR" -gt 0 ]; then
    old_engine="$ENGINE_MAJOR.$((ENGINE_MINOR - 1)).0"
elif [ "$ENGINE_MAJOR" -gt 0 ]; then
    old_engine="$((ENGINE_MAJOR - 1)).0.0"
else
    echo "FAIL: cannot construct an older SemVer fixture before 0.0.0" >&2
    exit 1
fi
newer_engine="$ENGINE_MAJOR.$ENGINE_MINOR.$((ENGINE_PATCH + 1))"
fail=0
RC=0
OUTPUT=""

chk() { if ! "$@" >/dev/null 2>&1; then echo "FAIL: $*"; fail=1; fi; }
chknot() { if "$@" >/dev/null 2>&1; then echo "FAIL(not): $*"; fail=1; fi; }

run_in() {
    local dir="$1"
    shift
    RC=0
    OUTPUT="$( (cd "$dir" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" "$@") 2>&1 )" || RC=$?
}

run_restore_in() {
    local dir="$1"
    RC=0
    OUTPUT="$( (
        cd "$dir"
        CLI_DIR="$REPO/cli" IS_ENGINE_DIR="$REPO/engine" \
            IS_BUNDLED_PKG_DIR="$REPO/packages/sync" \
            bash "$REPO/cli/internal/restore.sh" --frozen
    ) 2>&1 )" || RC=$?
}

# A malformed lock is a user-actionable input error. Each fixture asserts the
# exact underlying reason as well as the stable top-level diagnosis.
lock_xfail() {
    local reason="$1" dir="$2"
    shift 2
    run_in "$dir" "$@"
    if [ "$RC" -eq 0 ]; then
        echo "FAIL: expected invalid lock refusal: $*"
        fail=1
    fi
    if ! printf '%s\n' "$OUTPUT" | grep -qF -- "$reason"; then
        echo "FAIL: lock refusal lacks '$reason': $*"
        printf '%s\n' "$OUTPUT" | head -8
        fail=1
    fi
    if ! printf '%s\n' "$OUTPUT" | grep -qF 'invalid intelligence.lock'; then
        echo "FAIL: lock refusal did not identify invalid intelligence.lock: $*"
        printf '%s\n' "$OUTPUT" | head -8
        fail=1
    fi
}

copy_case() {
    local name="$1"
    rm -rf "${OUT:?}/$name"
    mkdir -p "$OUT/$name"
    cp -R "$BASE/." "$OUT/$name/"
    printf '%s' "$OUT/$name"
}

snapshot() {
    local dir="$1" label="$2"
    rm -rf "${OUT:?}/$label.tree"
    mkdir -p "$OUT/$label.tree"
    cp -R "$dir/." "$OUT/$label.tree/"
}

assert_snapshot() {
    local dir="$1" label="$2"
    if ! diff -ru "$OUT/$label.tree" "$dir" > "$OUT/$label.diff"; then
        echo "FAIL: project changed after lock refusal ($label)"
        sed -n '1,80p' "$OUT/$label.diff"
        fail=1
    fi
}

echo "== fixtures and generated valid lock =="
PACK="$OUT/pack"
mkdir -p "$PACK/rules"
printf '# First package\n\nFIRST_LOCK_MARKER\n' > "$PACK/rules/first.md"
git -C "$PACK" init --quiet
git -C "$PACK" -c user.email=t@t -c user.name=t add -A
git -C "$PACK" -c user.email=t@t -c user.name=t commit --quiet -m first
git -C "$PACK" tag v1.0.0
PACK_URL="file://$PACK"

BASE="$OUT/base"
mkdir -p "$BASE"
(cd "$BASE" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" init --bare --no-sync >/dev/null)
(cd "$BASE" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" package add "git+$PACK_URL" --name @acme/first --no-sync >/dev/null)
(cd "$BASE" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" package add "git+$PACK_URL" --name @acme/second --no-sync >/dev/null)
(cd "$BASE" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync >/dev/null)
chk test -f "$BASE/intelligence.lock"
chk grep -q '^lockfile_version: 1$' "$BASE/intelligence.lock"
chk grep -q '^engine_version: "[0-9][0-9.]*"$' "$BASE/intelligence.lock"
run_in "$BASE" status --check
if [ "$RC" -ne 0 ]; then
    echo "FAIL: generated lock was rejected"
    printf '%s\n' "$OUTPUT" | tail -8
    fail=1
fi

echo "== additive scalar metadata remains readable =="
METADATA="$(copy_case metadata)"
printf '\nfuture_metadata: "allowed"\n' >> "$METADATA/intelligence.lock"
run_in "$METADATA" status --check
if [ "$RC" -ne 0 ]; then
    echo "FAIL: additive lock scalar metadata was rejected"
    printf '%s\n' "$OUTPUT" | tail -8
    fail=1
fi

echo "== generated bundled lock restores offline =="
BUNDLE="$OUT/bundle"
mkdir -p "$BUNDLE"
(cd "$BUNDLE" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" init --no-sync >/dev/null)
chk test -f "$BUNDLE/intelligence.lock"
rm -rf "$BUNDLE/.intelligence/packages"
run_in "$BUNDLE" sync --compact
if [ "$RC" -ne 0 ]; then
    echo "FAIL: generated bundle lock did not restore offline"
    printf '%s\n' "$OUTPUT" | tail -8
    fail=1
fi
chk test -d "$BUNDLE/.intelligence/packages/@ainova-systems/sync"

echo "== older development bundle lock aligns with installed content =="
OLD_BUNDLE="$OUT/older-bundle"
mkdir -p "$OLD_BUNDLE"
cp -R "$BUNDLE/." "$OLD_BUNDLE/"
awk -v old="$old_engine" '
    /^schema_version:/ { print "schema_version: \"" old "\""; next }
    /version: "/ { print "    version: \"" old "\""; next }
    { print }
' "$OLD_BUNDLE/intelligence.yaml" > "$OLD_BUNDLE/intelligence.yaml.tmp"
mv "$OLD_BUNDLE/intelligence.yaml.tmp" "$OLD_BUNDLE/intelligence.yaml"
awk -v old="$old_engine" '
    /^engine_version:/ { print "engine_version: \"" old "\""; next }
    /requested: "/ { print "    requested: \"" old "\""; next }
    /resolved: "/ { print "    resolved: \"v" old "\""; next }
    { print }
' "$OLD_BUNDLE/intelligence.lock" > "$OLD_BUNDLE/intelligence.lock.tmp"
mv "$OLD_BUNDLE/intelligence.lock.tmp" "$OLD_BUNDLE/intelligence.lock"
run_in "$OLD_BUNDLE" init --apply
if [ "$RC" -ne 0 ]; then
    echo "FAIL: older development bundle lock did not align"
    printf '%s\n' "$OUTPUT" | tail -8
    fail=1
fi
chk grep -q "^schema_version: \"$ENGINE_VER\"" "$OLD_BUNDLE/intelligence.yaml"

echo "== ahead development lock survives package mutation without verification =="
AHEAD="$OUT/ahead-development"
mkdir -p "$AHEAD"
cp -R "$BUNDLE/." "$AHEAD/"
awk -v newer="$newer_engine" '
    /^schema_version:/ { print "schema_version: \"" newer "\""; next }
    /version: "/ { print "    version: \"" newer "\""; next }
    { print }
' "$AHEAD/intelligence.yaml" > "$AHEAD/intelligence.yaml.tmp"
mv "$AHEAD/intelligence.yaml.tmp" "$AHEAD/intelligence.yaml"
awk -v newer="$newer_engine" '
    /^engine_version:/ { print "engine_version: \"" newer "\""; next }
    /requested: "/ { print "    requested: \"" newer "\""; next }
    /resolved: "/ { print "    resolved: \"v" newer "\""; next }
    { print }
' "$AHEAD/intelligence.lock" > "$AHEAD/intelligence.lock.tmp"
mv "$AHEAD/intelligence.lock.tmp" "$AHEAD/intelligence.lock"
(cd "$AHEAD" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" package add "git+$PACK_URL" --name @acme/ahead --no-sync >/dev/null)
chk grep -q "^schema_version: \"$newer_engine\"" "$AHEAD/intelligence.yaml"
chk grep -q "version: \"$newer_engine\"" "$AHEAD/intelligence.yaml"
chk grep -q "^engine_version: \"$ENGINE_VER\"" "$AHEAD/intelligence.lock"
chk grep -q "resolved: \"v$newer_engine\"" "$AHEAD/intelligence.lock"
printf '# First package update\n\nFIRST_LOCK_MARKER_UPDATE\n' > "$PACK/rules/first.md"
git -C "$PACK" -c user.email=t@t -c user.name=t commit --quiet -am update
git -C "$PACK" tag v1.1.0
run_in "$AHEAD" update @acme/ahead --apply
if [ "$RC" -ne 0 ]; then
    echo "FAIL: ahead development lock update lifecycle failed"
    printf '%s\n' "$OUTPUT" | tail -12
    fail=1
fi
warning_count="$(printf '%s\n' "$OUTPUT" | grep -cF 'commit verification is unavailable' || true)"
if [ "$warning_count" -ne 1 ]; then
    echo "FAIL: update lifecycle emitted $warning_count verification warnings (expected 1)"
    printf '%s\n' "$OUTPUT" | tail -20
    fail=1
fi
run_in "$AHEAD" sync
if [ "$RC" -ne 0 ]; then
    echo "FAIL: ahead development lock failed after package mutation"
    printf '%s\n' "$OUTPUT" | tail -8
    fail=1
fi
for command in 'status --check' 'init --preview' 'update --preview'; do
    # shellcheck disable=SC2086 # Each fixture command is a fixed two-word literal.
    run_in "$AHEAD" $command
    if [ "$RC" -ne 0 ]; then
        echo "FAIL: ahead development lock failed: $command"
        printf '%s\n' "$OUTPUT" | tail -8
        fail=1
    fi
    if ! printf '%s\n' "$OUTPUT" | grep -qF 'commit verification is unavailable'; then
        echo "FAIL: ahead development lock lacks verification warning: $command"
        printf '%s\n' "$OUTPUT" | tail -8
        fail=1
    fi
done
chk grep -q "^schema_version: \"$newer_engine\"" "$AHEAD/intelligence.yaml"
chk grep -q "resolved: \"v$newer_engine\"" "$AHEAD/intelligence.lock"
chk grep -q "^engine_version: \"$ENGINE_VER\"" "$AHEAD/intelligence.lock"

echo "== status --check uses strict restore metadata when store is missing =="
AHEAD_MISSING="$OUT/ahead-development-missing"
mkdir -p "$AHEAD_MISSING"
cp -R "$AHEAD/." "$AHEAD_MISSING/"
rm -rf "$AHEAD_MISSING/.intelligence/packages"
snapshot "$AHEAD_MISSING" ahead-development-missing
lock_xfail "missing or invalid commit SHA" "$AHEAD_MISSING" status --check
if ! printf '%s\n' "$OUTPUT" | grep -qF "manifest schema $newer_engine is newer than this CLI's engine $ENGINE_VER"; then
    echo "FAIL: strict missing-store status skipped its independent schema check"
    printf '%s\n' "$OUTPUT" | tail -16
    fail=1
fi
if ! printf '%s\n' "$OUTPUT" | grep -qF 'adapter agents contract v1'; then
    echo "FAIL: strict missing-store status skipped its independent adapter check"
    printf '%s\n' "$OUTPUT" | tail -16
    fail=1
fi
assert_snapshot "$AHEAD_MISSING" ahead-development-missing

echo "== cross-version empty bundle SHA never restores =="
CROSS_BUNDLE="$OUT/cross-version-bundle"
mkdir -p "$CROSS_BUNDLE"
cp -R "$BUNDLE/." "$CROSS_BUNDLE/"
awk -v old="$old_engine" '
    /^engine_version:/ { print "engine_version: \"" old "\""; next }
    /requested: "/ { print "    requested: \"" old "\""; next }
    /resolved: "/ { print "    resolved: \"v" old "\""; next }
    { print }
' "$CROSS_BUNDLE/intelligence.lock" > "$CROSS_BUNDLE/intelligence.lock.tmp"
mv "$CROSS_BUNDLE/intelligence.lock.tmp" "$CROSS_BUNDLE/intelligence.lock"
rm -rf "$CROSS_BUNDLE/.intelligence/packages"
snapshot "$CROSS_BUNDLE" cross-version-bundle
run_restore_in "$CROSS_BUNDLE"
if [ "$RC" -eq 0 ]; then
    echo "FAIL: cross-version empty bundle SHA restored"
    fail=1
fi
if ! printf '%s\n' "$OUTPUT" | grep -qF 'missing or invalid commit SHA'; then
    echo "FAIL: cross-version empty bundle SHA refusal lacks the SHA reason"
    printf '%s\n' "$OUTPUT" | head -8
    fail=1
fi
if ! printf '%s\n' "$OUTPUT" | grep -qF 'invalid intelligence.lock'; then
    echo "FAIL: cross-version empty bundle SHA refusal did not name invalid intelligence.lock"
    printf '%s\n' "$OUTPUT" | head -8
    fail=1
fi
assert_snapshot "$CROSS_BUNDLE" cross-version-bundle
chknot test -d "$CROSS_BUNDLE/.intelligence/packages"

echo "== malformed top-level structure is refused with an installed store =="
CASE="$(copy_case malformed)"
awk 'BEGIN { done=0 } /^lockfile_version:/ && !done { print "lockfile_version: 2"; done=1; next } { print }' \
    "$CASE/intelligence.lock" > "$CASE/intelligence.lock.tmp"
mv "$CASE/intelligence.lock.tmp" "$CASE/intelligence.lock"
snapshot "$CASE" malformed
lock_xfail "unsupported or missing lockfile_version '2'" "$CASE" sync
assert_snapshot "$CASE" malformed
chk test -d "$CASE/.intelligence/packages/@acme/first"

echo "== malformed package map and scalar rows are refused =="
for kind in missing-url unsafe-path unquoted-package duplicate-field duplicate-package; do
    CASE="$(copy_case "$kind")"
    case "$kind" in
        missing-url)
            awk '
                /^  "@acme\/second":/ { second=1 }
                second && /^    url:/ { next }
                { print }
            ' "$CASE/intelligence.lock" > "$CASE/intelligence.lock.tmp"
            ;;
        unsafe-path)
            awk '
                /^  "@acme\/second":/ { second=1 }
                second && /^    path:/ { print "    path: \"../escape\""; path_seen=1; next }
                second && /^    resolved:/ && !path_seen { print "    path: \"../escape\""; path_seen=1 }
                { print }
            ' "$CASE/intelligence.lock" > "$CASE/intelligence.lock.tmp"
            ;;
        unquoted-package)
            awk '
                /^  "@acme\/second":/ { print "  @acme/second:"; next }
                { print }
            ' "$CASE/intelligence.lock" > "$CASE/intelligence.lock.tmp"
            ;;
        duplicate-field)
            awk '
                /^  "@acme\/first":/ { first=1 }
                first && /^    resolved:/ { print; print "    resolved: \"v1.0.0\""; first=0; next }
                { print }
            ' "$CASE/intelligence.lock" > "$CASE/intelligence.lock.tmp"
            ;;
        duplicate-package)
            cat "$CASE/intelligence.lock" > "$CASE/intelligence.lock.tmp"
            cat >> "$CASE/intelligence.lock.tmp" <<EOF
  "@acme/first":
    requested: "^1.0.0"
    url: "$PACK_URL"
    path: ""
    resolved: "v1.0.0"
    sha: "0000000000000000000000000000000000000000"
EOF
            ;;
    esac
    mv "$CASE/intelligence.lock.tmp" "$CASE/intelligence.lock"
    case "$kind" in
        missing-url) reason="unsafe source url ''" ;;
        unsafe-path) reason="unsafe path '../escape'" ;;
        unquoted-package) reason="malformed lock structure" ;;
        duplicate-field) reason="duplicate field @acme/first.resolved" ;;
        duplicate-package) reason="duplicate package @acme/first" ;;
    esac
    snapshot "$CASE" "$kind"
    lock_xfail "$reason" "$CASE" sync
    assert_snapshot "$CASE" "$kind"
done

echo "== later invalid row preserves earlier installed package =="
CASE="$(copy_case later-row)"
touch "$CASE/.intelligence/packages/@acme/first/preserve-on-refusal"
rm -rf "$CASE/.intelligence/packages/@acme/second"
awk '
    /^  "@acme\/second":/ { second=1 }
    second && /^    sha:/ { print "    sha: \"invalid\""; next }
    { print }
' "$CASE/intelligence.lock" > "$CASE/intelligence.lock.tmp"
mv "$CASE/intelligence.lock.tmp" "$CASE/intelligence.lock"
snapshot "$CASE" later-row
lock_xfail "missing or invalid commit SHA" "$CASE" sync
assert_snapshot "$CASE" later-row
chk test -f "$CASE/.intelligence/packages/@acme/first/preserve-on-refusal"
chknot test -d "$CASE/.intelligence/packages/@acme/second"

echo "== invalid lock refuses a missing-store restore =="
CASE="$(copy_case missing-store)"
rm -rf "$CASE/.intelligence/packages"
awk '/^engine_version:/ { print "engine_version: \"\""; next } { print }' \
    "$CASE/intelligence.lock" > "$CASE/intelligence.lock.tmp"
mv "$CASE/intelligence.lock.tmp" "$CASE/intelligence.lock"
snapshot "$CASE" missing-store
lock_xfail "missing or invalid engine_version" "$CASE" sync
assert_snapshot "$CASE" missing-store
chknot test -d "$CASE/.intelligence/packages"

echo "== empty package map cannot stand in for a nonempty manifest =="
CASE="$(copy_case empty-packages)"
awk '
    /^  "@/ { skip=1 }
    skip && /^    / { next }
    /^  "@/ { next }
    { if (!/^  "@/) print }
' "$CASE/intelligence.lock" > "$CASE/intelligence.lock.tmp"
mv "$CASE/intelligence.lock.tmp" "$CASE/intelligence.lock"
snapshot "$CASE" empty-packages
lock_xfail 'packages is empty but the manifest declares packages' "$CASE" sync
assert_snapshot "$CASE" empty-packages

echo "== validation precedes lifecycle alignment, previews, and status checks =="
CASE="$(copy_case lifecycle)"
awk -v old="$old_engine" '/^schema_version:/ { print "schema_version: \"" old "\""; next } { print }' \
    "$CASE/intelligence.yaml" > "$CASE/intelligence.yaml.tmp"
mv "$CASE/intelligence.yaml.tmp" "$CASE/intelligence.yaml"
awk '/^lockfile_version:/ { print "lockfile_version: 9"; next } { print }' \
    "$CASE/intelligence.lock" > "$CASE/intelligence.lock.tmp"
mv "$CASE/intelligence.lock.tmp" "$CASE/intelligence.lock"
snapshot "$CASE" lifecycle
lock_xfail "unsupported or missing lockfile_version '9'" "$CASE" init --apply
assert_snapshot "$CASE" lifecycle
lock_xfail "unsupported or missing lockfile_version '9'" "$CASE" init --preview
assert_snapshot "$CASE" lifecycle
lock_xfail "unsupported or missing lockfile_version '9'" "$CASE" update --preview
assert_snapshot "$CASE" lifecycle
lock_xfail "unsupported or missing lockfile_version '9'" "$CASE" status --check
if ! printf '%s\n' "$OUTPUT" | grep -qF "manifest schema $old_engine behind engine $ENGINE_VER"; then
    echo "FAIL: status --check stopped before its independent schema check"
    printf '%s\n' "$OUTPUT" | tail -12
    fail=1
fi
if ! printf '%s\n' "$OUTPUT" | grep -qF 'adapter agents contract v1'; then
    echo "FAIL: status --check stopped before its independent adapter check"
    printf '%s\n' "$OUTPUT" | tail -12
    fail=1
fi
assert_snapshot "$CASE" lifecycle
lock_xfail "unsupported or missing lockfile_version '9'" "$CASE" status
if ! printf '%s\n' "$OUTPUT" | grep -qF 'Lockfile: INVALID (locked state unchecked)'; then
    echo "FAIL: plain status did not mark the invalid lock unchecked"
    printf '%s\n' "$OUTPUT"
    fail=1
fi
if ! printf '%s\n' "$OUTPUT" | grep -qF 'Content:  unchecked'; then
    echo "FAIL: plain status did not mark content unchecked"
    printf '%s\n' "$OUTPUT"
    fail=1
fi
assert_snapshot "$CASE" lifecycle
lock_xfail "unsupported or missing lockfile_version '9'" "$CASE" package list
assert_snapshot "$CASE" lifecycle

[ "$fail" -eq 0 ] && echo "E2E-LOCK-VALIDATION: ALL OK"
exit "$fail"
