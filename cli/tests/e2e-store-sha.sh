#!/bin/bash
# The package store must hold what intelligence.lock pins. A teammate moves a
# package and commits the lock; `git pull` brings the lock but not the ignored
# store, so the store still holds the old commit. sync must restore the locked
# commit, and status --check must not call the old one good.
set -euo pipefail
unset CI
REPO="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
REPO="$(cd "$REPO" && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
CLI="$REPO/cli/intelligence"
fail=0
checks=0
check() { checks=$((checks + 1)); if ! "$@" >/dev/null 2>&1; then echo "FAIL: $*"; printf '%s\n' "$OUTPUT" | tail -6; fail=1; fi; }
checknot() { checks=$((checks + 1)); if "$@" >/dev/null 2>&1; then echo "FAIL(not): $*"; printf '%s\n' "$OUTPUT" | tail -6; fail=1; fi; }
run() {
    local dir="$1"
    shift
    RC=0
    OUTPUT="$(cd "$dir" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" "$@" 2>&1)" || RC=$?
}
has() { grep -qF -- "$1" <<< "$OUTPUT"; }

PACK="$OUT/pack"
mkdir -p "$PACK/rules"
printf '# Pack rule\n\nPACK_V1_MARKER\n' > "$PACK/rules/pack-rule.md"
git -C "$PACK" init --quiet
git -C "$PACK" -c user.email=t@t -c user.name=t add -A
git -C "$PACK" -c user.email=t@t -c user.name=t commit --quiet -m v1
git -C "$PACK" tag v1.0.0
V1="$(git -C "$PACK" rev-parse HEAD)"
printf '# Pack rule\n\nPACK_V2_MARKER\n' > "$PACK/rules/pack-rule.md"
git -C "$PACK" -c user.email=t@t -c user.name=t commit --quiet -am v2
git -C "$PACK" tag v1.1.0
V2="$(git -C "$PACK" rev-parse HEAD)"

PROJ="$OUT/proj"
mkdir -p "$PROJ/intelligence/rules"
ENGINE_VER="$(tr -d ' \t\r\n' < "$REPO/engine/VERSION")"
cat > "$PROJ/intelligence.yaml" <<EOF
project:
  name: store-sha

schema_version: "$ENGINE_VER"

sources:
  rules:
    - "intelligence/rules"

targets:
  agents: { enabled: true, output: "AGENTS.md" }
EOF
printf '# Ctx\n\nproject context\n' > "$PROJ/intelligence/rules/context.md"
printf '.intelligence/\n' > "$PROJ/.gitignore"
git -C "$PROJ" init --quiet

echo '== install the package at v1.0.0 =='
run "$PROJ" package add "git+file://$PACK@v1.0.0" --name @acme/pack
check test "$RC" -eq 0
check grep -q PACK_V1_MARKER "$PROJ/AGENTS.md"
check grep -q "sha: \"$V1\"" "$PROJ/intelligence.lock"
run "$PROJ" status --check
check test "$RC" -eq 0
check has "${V1:0:7}"

echo '== a teammate moves it to v1.1.0 and commits the lock =='
git -C "$PROJ" -c user.email=t@t -c user.name=t add -A
git -C "$PROJ" -c user.email=t@t -c user.name=t commit --quiet -m pinned-v1
MATE="$OUT/mate"
git clone --quiet "$PROJ" "$MATE"
run "$MATE" package add "git+file://$PACK@v1.1.0" --name @acme/pack
check test "$RC" -eq 0
check grep -q "sha: \"$V2\"" "$MATE/intelligence.lock"
# `git pull`: tracked files move, the ignored store does not.
cp "$MATE/intelligence.yaml" "$MATE/intelligence.lock" "$PROJ/"

echo '== status --check reports the store that disagrees with the lock =='
run "$PROJ" status --check
check test "$RC" -ne 0
check has "${V1:0:7}"
check has "${V2:0:7}"
checknot has "@acme/pack @ v1.1.0@${V2:0:7}"

echo '== sync restores the locked commit =='
run "$PROJ" sync
check test "$RC" -eq 0
check grep -q PACK_V2_MARKER "$PROJ/AGENTS.md"
checknot grep -q PACK_V1_MARKER "$PROJ/AGENTS.md"
check grep -q PACK_V2_MARKER "$PROJ/.intelligence/packages/@acme/pack/rules/pack-rule.md"
run "$PROJ" status --check
check test "$RC" -eq 0
check has "${V2:0:7}"

echo '== a store that matches the lock is not fetched again =='
mv "$PACK" "$OUT/pack-away"
run "$PROJ" sync --force
check test "$RC" -eq 0
check grep -q PACK_V2_MARKER "$PROJ/AGENTS.md"
mv "$OUT/pack-away" "$PACK"

echo '== a store written by an older CLI is verified once =='
# No record of what it holds: it is refetched rather than trusted.
rm -f "$PROJ/.intelligence/packages/.installed"
printf '# Pack rule\n\nTAMPERED_MARKER\n' > "$PROJ/.intelligence/packages/@acme/pack/rules/pack-rule.md"
run "$PROJ" status --check
check test "$RC" -ne 0
run "$PROJ" sync
check test "$RC" -eq 0
check grep -q PACK_V2_MARKER "$PROJ/AGENTS.md"
checknot grep -q TAMPERED_MARKER "$PROJ/AGENTS.md"

echo '== the bundled engine content is recorded without a network =='
SP="$OUT/sync-pkg"
mkdir -p "$SP"
git -C "$SP" init --quiet
run "$SP" init --targets agents
check test "$RC" -eq 0
check test -f "$SP/.intelligence/packages/.installed"
rm -f "$SP/.intelligence/packages/.installed"
run "$SP" sync
check test "$RC" -eq 0
check test -f "$SP/.intelligence/packages/.installed"

[ "$fail" -eq 0 ] && echo "== store-sha: $checks checks passed =="
exit "$fail"
