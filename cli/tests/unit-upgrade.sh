#!/bin/bash
# Hermetic suite for `intelligence upgrade` and the CLI section of `update`.
# npm is a fake on PATH: it answers dist-tag lookups and logs installs. The
# CLI under test is a copy laid out like a global npm installation, because
# upgrade derives the prefix it hands npm from its own location and refuses
# to replace anything laid out otherwise.
set -euo pipefail
REPO="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
REPO="$(cd "$REPO" && pwd)"
# Physical path: the command compares `pwd -P` results, and macOS hands out
# /var/... temp dirs that resolve to /private/var/...
OUT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$OUT"' EXIT
fail=0
PKG="@ainova-systems/intelligence"

# stage_install <dir> — cli/ + engine/ from this tree under <dir>: the shape
# the npm package has on disk (tests are not shipped and not needed).
stage_install() {
    mkdir -p "$1"
    cp -R "$REPO/cli" "$1/cli"
    rm -rf "$1/cli/tests"
    cp -R "$REPO/engine" "$1/engine"
}

# The Windows layout (<prefix>/node_modules/<pkg>) is the default fixture;
# the POSIX one (<prefix>/lib/node_modules/<pkg>) has its own case below.
GLOBAL="$OUT/global"
stage_install "$GLOBAL/node_modules/$PKG"
CLI="$GLOBAL/node_modules/$PKG/cli/intelligence"

# native_path <dir> — the spelling upgrade hands npm: Windows form under Git
# Bash, unchanged elsewhere.
native_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

mkdir -p "$OUT/bin"
cat > "$OUT/bin/npm" <<'EOF'
#!/bin/bash
set -euo pipefail
case "$*" in
    "view @ainova-systems/intelligence dist-tags.latest") printf '%s\n' "${FAKE_LATEST:-}" ;;
    "view @ainova-systems/intelligence dist-tags.next") printf '%s\n' "${FAKE_NEXT:-}" ;;
    "install -g --prefix "*) printf '%s\n' "$*" >> "$FAKE_LOG"; exit "${FAKE_INSTALL_RC:-0}" ;;
    *) echo "unexpected npm invocation: $*" >&2; exit 99 ;;
esac
EOF
chmod +x "$OUT/bin/npm"
export PATH="$OUT/bin:$PATH"
export FAKE_LOG="$OUT/npm.log"
export FAKE_LATEST="" FAKE_NEXT="" FAKE_INSTALL_RC=0
export INTELLIGENCE_NPM_PACKAGE="$PKG"

RC=0
OUTPUT=""
# run <dir> <installed-version> <cli> <args…> — stdin is never a terminal.
run() {
    local dir="$1" ver="$2" cli="$3"; shift 3
    : > "$FAKE_LOG"
    RC=0
    OUTPUT="$( (cd "$dir" && INTELLIGENCE_NPM_VERSION="$ver" bash "$cli" "$@" </dev/null) 2>&1 )" || RC=$?
}
expect_rc() {
    [ "$RC" -eq "$1" ] || { echo "FAIL: rc $RC, want $1"; printf '%s\n' "$OUTPUT" | tail -6; fail=1; }
}
expect_out() {
    printf '%s\n' "$OUTPUT" | grep -qF -- "$1" \
        || { echo "FAIL: output lacks '$1'"; printf '%s\n' "$OUTPUT" | tail -6; fail=1; }
}
expect_no_out() {
    if printf '%s\n' "$OUTPUT" | grep -qF -- "$1"; then echo "FAIL: output has '$1'"; fail=1; fi
}
# expect_install <prefix-dir> <spec> — exactly one install, into that prefix.
expect_install() {
    grep -qxF "install -g --prefix $(native_path "$1") $2" "$FAKE_LOG" \
        || { echo "FAIL: expected npm install of $2 into $1; log:"; cat "$FAKE_LOG"; fail=1; }
    [ "$(wc -l < "$FAKE_LOG")" -eq 1 ] || { echo "FAIL: more than one npm write:"; cat "$FAKE_LOG"; fail=1; }
}
expect_no_install() {
    [ ! -s "$FAKE_LOG" ] || { echo "FAIL: npm wrote:"; cat "$FAKE_LOG"; fail=1; }
}

echo "== a source checkout has nothing npm can replace =="
run "$OUT" "" "$REPO/cli/intelligence" upgrade --preview
expect_rc 1; expect_out "source checkout"; expect_no_install

echo "== preview and apply are exclusive; other options are unknown =="
run "$OUT" "0.12.1" "$CLI" upgrade --preview --apply
expect_rc 1; expect_out "either --preview or --apply"
run "$OUT" "0.12.1" "$CLI" upgrade --next
expect_rc 1; expect_out "usage: intelligence upgrade"

echo "== registry silence is a refusal, never up to date =="
export FAKE_LATEST=""
run "$OUT" "0.12.1" "$CLI" upgrade --apply
expect_rc 1; expect_out "could not report"; expect_no_install

echo "== up to date exits 0 without writes =="
export FAKE_LATEST="0.12.1"
run "$OUT" "0.12.1" "$CLI" upgrade
expect_rc 0; expect_out "CLI 0.12.1 is up to date (npm latest)"; expect_no_install

echo "== an installed version ahead of its channel is left alone =="
run "$OUT" "0.13.0" "$CLI" upgrade --apply
expect_rc 0; expect_out "newer than npm latest (0.12.1)"; expect_no_install

echo "== preview prints the plan and writes nothing =="
export FAKE_LATEST="0.13.0"
run "$OUT" "0.12.1" "$CLI" upgrade --preview
expect_rc 0
expect_out "CLI upgrade: 0.12.1 -> 0.13.0 (npm latest)"
expect_out "npm install -g --prefix '$(native_path "$GLOBAL")' $PKG@0.13.0"
expect_no_install

echo "== the bare form needs a terminal =="
# stdin is never a terminal here, so the accept/decline branch behind the
# prompt is not exercised — the same gap as the prompts in init, update and
# adapter remove; only the refusal that guards it is provable hermetically.
run "$OUT" "0.12.1" "$CLI" upgrade
expect_rc 1; expect_out "requires confirmation"; expect_no_install

echo "== apply installs exactly the planned version into this tree's prefix =="
run "$OUT" "0.12.1" "$CLI" upgrade --apply
expect_rc 0; expect_install "$GLOBAL" "$PKG@0.13.0"; expect_out "upgraded: 0.12.1 -> 0.13.0"

echo "== a POSIX prefix layout is recognized the same way =="
POSIX="$OUT/posix"
stage_install "$POSIX/lib/node_modules/$PKG"
run "$OUT" "0.12.1" "$POSIX/lib/node_modules/$PKG/cli/intelligence" upgrade --apply
expect_rc 0; expect_install "$POSIX" "$PKG@0.13.0"

echo "== a quote in the prefix stays a valid shell word in the printed command =="
QUOTED="$OUT/o'brien"
stage_install "$QUOTED/node_modules/$PKG"
run "$OUT" "0.12.1" "$QUOTED/node_modules/$PKG/cli/intelligence" upgrade --apply
expect_rc 0
quoted_native="$(native_path "$QUOTED")"
expect_out "--prefix '${quoted_native//\'/\'\\\'\'}' $PKG@0.13.0"
expect_install "$QUOTED" "$PKG@0.13.0"

echo "== a prerelease follows the next channel, including onto the stable that advanced it =="
export FAKE_NEXT="0.13.0-rc.2"
run "$OUT" "0.13.0-rc.1" "$CLI" upgrade --preview
expect_rc 0; expect_out "0.13.0-rc.1 -> 0.13.0-rc.2 (npm next)"
export FAKE_NEXT="0.13.0"
run "$OUT" "0.13.0-rc.2" "$CLI" upgrade --preview
expect_rc 0; expect_out "0.13.0-rc.2 -> 0.13.0 (npm next)"
export FAKE_NEXT="0.13.0-rc.2"
run "$OUT" "0.13.0-rc.2" "$CLI" upgrade --apply
expect_rc 0; expect_out "up to date (npm next)"; expect_no_install

echo "== an unusable registry answer never reaches npm =="
export FAKE_LATEST="--registry=evil"
run "$OUT" "0.12.1" "$CLI" upgrade --apply
expect_rc 1; expect_out "unusable version"; expect_no_install

echo "== npm failure keeps its exit code and claims nothing =="
export FAKE_LATEST="0.13.0" FAKE_INSTALL_RC=7
run "$OUT" "0.12.1" "$CLI" upgrade --apply
expect_rc 7; expect_no_out "upgraded:"
export FAKE_INSTALL_RC=0

echo "== a tree npm did not lay out is refused =="
ODD="$OUT/src/intelligence"
stage_install "$ODD"
run "$OUT" "0.12.1" "$ODD/cli/intelligence" upgrade --apply
expect_rc 1; expect_out "not laid out like an npm global installation"; expect_no_install

echo "== a linked checkout is judged by where it really lives =="
# Probe the link rather than the platform: Git Bash without symlink rights
# copies instead, and a filesystem that CAN link still has to pass.
LINKED="$OUT/linked/node_modules"
mkdir -p "$LINKED/@ainova-systems"
if ln -s "$ODD" "$LINKED/$PKG" 2>/dev/null && [ -L "$LINKED/$PKG" ]; then
    export FAKE_NEXT="0.13.0"
    run "$OUT" "0.0.0-dev" "$LINKED/$PKG/cli/intelligence" upgrade --apply
    expect_rc 1; expect_out "not laid out like an npm global installation"; expect_no_install
else
    echo "  NOTE: this filesystem does not create symlinks — linked checkout not exercised"
fi

echo "== another package manager's store is named as the installer =="
PNPM="$OUT/pnpm/.pnpm/x/node_modules/$PKG"
stage_install "$PNPM"
run "$OUT" "0.12.1" "$PNPM/cli/intelligence" upgrade --apply
expect_rc 1; expect_out "pnpm add -g $PKG@0.13.0"; expect_no_install

echo "== an npx cache has nothing installed =="
NPX="$OUT/_npx/abc/node_modules/$PKG"
stage_install "$NPX"
run "$OUT" "0.12.1" "$NPX/cli/intelligence" upgrade --preview
expect_rc 1; expect_out "through npx"; expect_no_install

echo "== the update plan names upgrade and never installs =="
PROJ="$OUT/proj"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
run "$PROJ" "0.12.1" "$CLI" init --bare --no-sync
expect_rc 0
run "$PROJ" "0.12.1" "$CLI" update --preview
expect_rc 0
expect_out "0.12.1 -> 0.13.0 (npm latest)"
expect_out "run: intelligence upgrade"
expect_no_out "npm install -g"
expect_no_install
run "$PROJ" "0.13.0" "$CLI" update --preview
expect_rc 0; expect_out "0.13.0 (up to date on npm latest)"
run "$PROJ" "0.13.1" "$CLI" update --preview
expect_rc 0; expect_out "0.13.1 (ahead of npm latest 0.13.0)"
export FAKE_LATEST="--registry=evil"
run "$PROJ" "0.12.1" "$CLI" update --preview
expect_rc 0; expect_out "registry check unavailable"; expect_no_out "ahead of"; expect_no_out "->"
export FAKE_LATEST="0.13.0"

[ "$fail" -eq 0 ] && echo "unit-upgrade: ALL OK"
exit "$fail"
