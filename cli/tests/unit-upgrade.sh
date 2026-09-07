#!/bin/bash
# Hermetic suite for `intelligence upgrade` and the CLI section of `update`.
# npm is a fake on PATH: it answers dist-tag lookups and logs installs. The
# CLI under test is a copy laid out like this platform's global npm
# installation — with the shim npm would have linked, because that shim is
# what upgrade trusts — and other layouts are staged to prove they are refused.
set -euo pipefail
REPO="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
REPO="$(cd "$REPO" && pwd)"
# Physical path: the command compares `pwd -P` results, and macOS hands out
# /var/... temp dirs that resolve to /private/var/...
OUT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$OUT"' EXIT
fail=0
PKG="@ainova-systems/intelligence"
BIN="intelligence"

on_windows() { case "${OSTYPE:-}" in msys*|cygwin*) return 0 ;; esac; return 1; }
# native_path <dir> — the spelling upgrade hands npm: Windows form under Git
# Bash, unchanged elsewhere.
native_path() { if on_windows; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
HAS_NODE=0
command -v node >/dev/null 2>&1 && HAS_NODE=1

# stage_install <dir> — cli/ + engine/ from this tree under <dir> (tests are
# not shipped), plus a stub launcher that reports whatever version the fake
# npm "installed".
stage_install() {
    mkdir -p "$1/bin"
    cp -R "$REPO/cli" "$1/cli"
    rm -rf "$1/cli/tests"
    cp -R "$REPO/engine" "$1/engine"
    printf '%s\n' 'console.log((process.env.FAKE_INSTALLED_VERSION || "0.0.0") + " (engine stub)");' > "$1/bin/intelligence.js"
}

# stage_global <prefix> — this platform's npm global layout, shim included;
# prints the dispatcher path.
stage_global() {
    local prefix="$1" pkg_dir
    if on_windows; then
        pkg_dir="$prefix/node_modules/$PKG"
        stage_install "$pkg_dir"
        printf '@ECHO off\r\n"%%dp0%%\\node_modules\\@ainova-systems\\intelligence\\bin\\intelligence.js" %%*\r\n' > "$prefix/$BIN.cmd"
    else
        pkg_dir="$prefix/lib/node_modules/$PKG"
        stage_install "$pkg_dir"
        mkdir -p "$prefix/bin"
        ln -s "../lib/node_modules/$PKG/bin/intelligence.js" "$prefix/bin/$BIN"
    fi
    printf '%s' "$pkg_dir/cli/intelligence"
}

mkdir -p "$OUT/bin"
cat > "$OUT/bin/npm" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_CALLS"
case "$1" in
    view)
        case "$*" in
            *" dist-tags.latest") printf '%s\n' "${FAKE_LATEST:-}" ;;
            *" dist-tags.next") printf '%s\n' "${FAKE_NEXT:-}" ;;
            *) echo "unexpected npm view: $*" >&2; exit 99 ;;
        esac
        ;;
    install) printf '%s\n' "$*" >> "$FAKE_LOG"; exit "${FAKE_INSTALL_RC:-0}" ;;
    *) echo "unexpected npm invocation: $*" >&2; exit 99 ;;
esac
EOF
chmod +x "$OUT/bin/npm"
export PATH="$OUT/bin:$PATH"
export FAKE_LOG="$OUT/npm.log" FAKE_CALLS="$OUT/npm.calls"
export FAKE_LATEST="" FAKE_NEXT="" FAKE_INSTALL_RC=0 FAKE_INSTALLED_VERSION=""
export INTELLIGENCE_NPM_PACKAGE="$PKG" INTELLIGENCE_NPM_BIN="$BIN" INTELLIGENCE_NPM_LAUNCHER="bin/intelligence.js"

RC=0
OUTPUT=""
# run <dir> <installed-version> <cli> <args…> — stdin is never a terminal.
run() {
    local dir="$1" ver="$2" cli="$3"; shift 3
    : > "$FAKE_LOG"; : > "$FAKE_CALLS"
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
expect_no_npm() {
    [ ! -s "$FAKE_CALLS" ] || { echo "FAIL: npm was invoked:"; cat "$FAKE_CALLS"; fail=1; }
}
# expect_view_at <prefix-dir> <tag> — the lookup ran in global mode at the prefix.
expect_view_at() {
    grep -qxF "view --global --prefix $(native_path "$1") --no-json $PKG dist-tags.$2" "$FAKE_CALLS" \
        || { echo "FAIL: expected a global-mode view at $1; calls:"; cat "$FAKE_CALLS"; fail=1; }
}
# expect_printed_prefix <prefix-dir> — the plan's --prefix word, read back by
# the shell, is the prefix itself (bash reads both quoting forms).
expect_printed_prefix() {
    local want word
    want="$(native_path "$1")"
    word="$(printf '%s\n' "$OUTPUT" | sed -n "s|^  npm install -g --prefix \(.*\) $PKG@.*$|\1|p" | head -1)"
    [ -n "$word" ] || { echo "FAIL: no install line in the plan"; printf '%s\n' "$OUTPUT" | tail -4; fail=1; return; }
    eval "set -- $word"
    [ "$1" = "$want" ] || { echo "FAIL: printed prefix reads back as '$1', want '$want'"; fail=1; }
}

echo "== a source checkout has nothing npm can replace =="
run "$OUT" "" "$REPO/cli/intelligence" upgrade --preview
expect_rc 1; expect_out "source checkout"; expect_no_npm

GLOBAL="$OUT/global"
CLI="$(stage_global "$GLOBAL")"

echo "== preview and apply are exclusive; other options are unknown =="
run "$OUT" "0.12.1" "$CLI" upgrade --preview --apply
expect_rc 1; expect_out "either --preview or --apply"
run "$OUT" "0.12.1" "$CLI" upgrade --latest
expect_rc 1; expect_out "usage: intelligence upgrade"

echo "== registry silence is a refusal, never up to date =="
export FAKE_LATEST=""
run "$OUT" "0.12.1" "$CLI" upgrade --apply
expect_rc 1; expect_out "could not report"; expect_no_install

echo "== the registry is asked in global mode at this tree's own prefix =="
export FAKE_LATEST="0.12.1"
run "$OUT" "0.12.1" "$CLI" upgrade
expect_rc 0; expect_out "CLI 0.12.1 is up to date (npm latest)"; expect_view_at "$GLOBAL" latest; expect_no_install

echo "== an installed version ahead of its channel is left alone, with the way back named =="
run "$OUT" "0.13.0" "$CLI" upgrade --apply
expect_rc 0; expect_out "newer than npm latest (0.12.1)"; expect_out "to move back deliberately: npm install -g --prefix"; expect_no_install

echo "== preview prints the plan as one pastable command and writes nothing =="
export FAKE_LATEST="0.13.0"
run "$OUT" "0.12.1" "$CLI" upgrade --preview
expect_rc 0
expect_out "CLI upgrade: 0.12.1 -> 0.13.0 (npm latest)"
expect_printed_prefix "$GLOBAL"
expect_no_install

echo "== the bare form needs a terminal =="
# stdin is never a terminal here, so the accept/decline branch behind the
# prompt is not exercised — the same gap as the prompts in init, update and
# adapter remove; only the refusal that guards it is provable hermetically.
run "$OUT" "0.12.1" "$CLI" upgrade
expect_rc 1; expect_out "requires confirmation"; expect_no_install

echo "== apply installs exactly the planned version into this tree's prefix =="
export FAKE_INSTALLED_VERSION="0.13.0"
run "$OUT" "0.12.1" "$CLI" upgrade --apply
expect_rc 0; expect_install "$GLOBAL" "$PKG@0.13.0"; expect_out "upgraded: 0.12.1 -> 0.13.0"
if [ "$HAS_NODE" -eq 1 ]; then
    expect_out "0.13.0 (engine stub)"
else
    expect_out "not verified"
fi

if [ "$HAS_NODE" -eq 1 ]; then
    echo "== success is what the new launcher reports, not what npm returned =="
    export FAKE_INSTALLED_VERSION="0.12.1"
    run "$OUT" "0.12.1" "$CLI" upgrade --apply
    expect_rc 1; expect_out "npm reported success but the installed launcher answers: 0.12.1"; expect_no_out "upgraded:"
    export FAKE_INSTALLED_VERSION="0.13.0"
else
    echo "  NOTE: node is not on PATH — launcher verification not exercised"
fi

echo "== --next follows the prerelease line from a stable install =="
export FAKE_NEXT="0.13.0-rc.2"
run "$OUT" "0.12.1" "$CLI" upgrade --next --preview
expect_rc 0; expect_out "0.12.1 -> 0.13.0-rc.2 (npm next)"; expect_view_at "$GLOBAL" next; expect_no_install

echo "== a prerelease follows next on its own, including onto the stable that advanced it =="
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
expect_rc 1; expect_out "could not report"; expect_no_install
export FAKE_LATEST="0.13.0"

echo "== npm failure keeps its exit code and claims nothing =="
export FAKE_INSTALL_RC=7
run "$OUT" "0.12.1" "$CLI" upgrade --apply
expect_rc 7; expect_no_out "upgraded:"
export FAKE_INSTALL_RC=0

echo "== a project's own dependency is not a prefix =="
DEP="$OUT/proj/node_modules/$PKG"
stage_install "$DEP"
run "$OUT" "0.12.1" "$DEP/cli/intelligence" upgrade --apply
expect_rc 1; expect_out "project dependency"; expect_out "npm install -D $PKG@0.13.0"; expect_no_install

echo "== a shim that does not point at this tree proves nothing =="
FOREIGN="$OUT/foreign"
if on_windows; then
    FCLI="$(stage_global "$FOREIGN")"
    printf '@ECHO off\r\nnode "%%dp0%%\\node_modules\\something-else\\bin\\cli.js" %%*\r\n' > "$FOREIGN/$BIN.cmd"
else
    FCLI="$(stage_global "$FOREIGN")"
    rm -f "$FOREIGN/bin/$BIN"
    printf '#!/bin/sh\necho mine\n' > "$FOREIGN/bin/$BIN"
fi
run "$OUT" "0.12.1" "$FCLI" upgrade --apply
expect_rc 1; expect_out "not an npm global installation"; expect_no_install

echo "== a tree npm did not lay out is refused with the version to ask for =="
ODD="$OUT/src/intelligence"
stage_install "$ODD"
run "$OUT" "0.12.1" "$ODD/cli/intelligence" upgrade --apply
expect_rc 1; expect_out "not an npm global installation"; expect_out "ask for $PKG@0.13.0"; expect_no_install

echo "== a refusal needs no network and then names the channel =="
export FAKE_LATEST=""
PNPM="$OUT/pnpm/.pnpm/x/node_modules/$PKG"
stage_install "$PNPM"
run "$OUT" "0.12.1" "$PNPM/cli/intelligence" upgrade --apply
expect_rc 1; expect_out "pnpm add -g $PKG@latest"; expect_no_out "could not report"; expect_no_install
export FAKE_LATEST="0.13.0"

echo "== other package managers are named on either platform's paths =="
run "$OUT" "0.12.1" "$PNPM/cli/intelligence" upgrade --preview
expect_rc 1; expect_out "pnpm add -g $PKG@0.13.0"
VOLTA="$OUT/AppData/Local/Volta/tools/image/packages/x/node_modules/$PKG"
stage_install "$VOLTA"
run "$OUT" "0.12.1" "$VOLTA/cli/intelligence" upgrade --preview
expect_rc 1; expect_out "volta install $PKG@0.13.0"
YARN="$OUT/AppData/Local/Yarn/Data/global/node_modules/$PKG"
stage_install "$YARN"
run "$OUT" "0.12.1" "$YARN/cli/intelligence" upgrade --preview
expect_rc 1; expect_out "yarn global add $PKG@0.13.0"

echo "== an npx cache has nothing installed =="
NPX="$OUT/_npx/abc/node_modules/$PKG"
stage_install "$NPX"
run "$OUT" "0.12.1" "$NPX/cli/intelligence" upgrade --preview
expect_rc 1; expect_out "through npx"; expect_out "npm install -g $PKG@0.13.0"; expect_no_install

echo "== a quote in the prefix stays one pastable word =="
QUOTED="$OUT/o'brien"
QCLI="$(stage_global "$QUOTED")"
run "$OUT" "0.12.1" "$QCLI" upgrade --preview
expect_rc 0; expect_printed_prefix "$QUOTED"
run "$OUT" "0.12.1" "$QCLI" upgrade --apply
expect_rc 0; expect_install "$QUOTED" "$PKG@0.13.0"

echo "== the update plan names upgrade and asks the registry the same way =="
PROJ="$OUT/proj-plan"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
run "$PROJ" "0.12.1" "$CLI" init --bare --no-sync
expect_rc 0
run "$PROJ" "0.12.1" "$CLI" update --preview
expect_rc 0
expect_out "0.12.1 -> 0.13.0 (npm latest)"
expect_out "run: intelligence upgrade"
expect_no_out "npm install -g"
expect_view_at "$GLOBAL" latest
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
