#!/bin/bash
# intelligence upgrade [--preview|--apply]
#
# Replace the installed CLI with the newest version on its npm channel:
# `next` when the running version is a prerelease, `latest` otherwise.
# `update` plans this step and points here; this is the one command that
# writes to the npm prefix, and it never reads or writes a project.
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

mode="ask" preview_seen=0 apply_seen=0
while [ $# -gt 0 ]; do
    case "$1" in
        --preview) preview_seen=1; mode="preview" ;;
        --apply) apply_seen=1; mode="apply" ;;
        *) die "usage: intelligence upgrade [--preview|--apply]" ;;
    esac
    shift
done
[ "$preview_seen" -eq 0 ] || [ "$apply_seen" -eq 0 ] || die "choose either --preview or --apply"

pkg_dir="$(cd "$CLI_DIR/.." && pwd -P)"
installed="${INTELLIGENCE_NPM_VERSION:-}"
pkg="${INTELLIGENCE_NPM_PACKAGE:-}"
# Both come from the npm launcher; `bash cli/intelligence` in a checkout has neither.
[ -n "$installed" ] && [ -n "$pkg" ] \
    || die "this CLI runs from a source checkout ($pkg_dir), not an npm installation — pull the repository instead"
command -v npm >/dev/null 2>&1 || die "npm is not on PATH — it installed this CLI and is needed to replace it"

channel="$(npm_channel_for "$installed")"
available="$(npm view "$pkg" "dist-tags.$channel" 2>/dev/null || true)"
available="${available//[$' \t\r\n']/}"
[ -n "$available" ] || die "npm could not report $pkg dist-tag $channel — check the network or the registry and retry"
is_npm_version "$available" \
    || die "npm reported an unusable version '$available' for $pkg dist-tag $channel"

case "$(semver_cmp_full "$available" "$installed")" in
    0)
        echo "CLI $installed is up to date (npm $channel)"
        exit 0
        ;;
    -1)
        echo "CLI $installed is newer than npm $channel ($available); nothing to do"
        exit 0
        ;;
esac

# The installation to replace is the one this process runs from, so its npm
# prefix is read off its own location — `<prefix>/lib/node_modules/<pkg>` on
# POSIX, `<prefix>/node_modules/<pkg>` on Windows — and handed to npm
# explicitly. Asking npm (`npm root -g`) would answer for the current npm
# config, not for this tree, and npm redacts UUID-like path segments from
# everything it prints. Anything else running this launcher — an npx cache,
# another package manager's store, a checkout — would stay on PATH beside a
# second copy, so name the command that upgrades it where it lives and stop.
prefix=""
case "$pkg_dir" in
    */_npx/*) hint="nothing is installed globally (this run came through npx) — install it: npm install -g $pkg" ;;
    */.volta/*) hint="volta install $pkg@$available" ;;
    */.pnpm/*) hint="pnpm add -g $pkg@$available" ;;
    */.bun/install/global/*) hint="bun add -g $pkg@$available" ;;
    */yarn/global/*) hint="yarn global add $pkg@$available" ;;
    */lib/node_modules/"$pkg") prefix="${pkg_dir%/lib/node_modules/"$pkg"}" ;;
    */node_modules/"$pkg") prefix="${pkg_dir%/node_modules/"$pkg"}" ;;
    *) hint="upgrade it with the tool that installed it, or pull it if it is a checkout" ;;
esac
[ -n "$prefix" ] || die "this CLI ($pkg_dir) is not laid out like an npm global installation — $hint"
# Git Bash: npm is a native program and needs the Windows spelling.
if command -v cygpath >/dev/null 2>&1; then
    prefix="$(cygpath -w "$prefix")"
fi

echo "CLI upgrade: $installed -> $available (npm $channel)"
echo "  npm install -g --prefix $(shell_single_quote "$prefix") $pkg@$available"
[ "$mode" != "preview" ] || exit 0
if [ "$mode" = "ask" ]; then
    [ -t 0 ] || die "upgrade requires confirmation — rerun with --preview or --apply"
    printf '\nInstall %s? [Y/n] ' "$available"
    read -r answer
    case "$answer" in
        ""|y|Y|yes|YES) ;;
        *) echo "upgrade cancelled"; exit 0 ;;
    esac
fi
echo ""

launcher="$pkg_dir/bin/intelligence.js"
# npm rewrites the directory this script lives in, and Windows refuses to
# delete a file another process still holds open. `bash -c` parses its whole
# program before running it, so the fresh shell reads nothing from the
# package while npm replaces it, and exec leaves no old process behind.
# The version installed is the one the plan showed, never a moving tag.
exec "$BASH" -c '
    set -euo pipefail
    npm install -g --prefix "$5" "$1@$3"
    echo ""
    echo "upgraded: $2 -> $3"
    if [ -f "$4" ] && command -v node >/dev/null 2>&1; then
        node "$4" version
    fi
' intelligence-upgrade "$pkg" "$installed" "$available" "$launcher" "$prefix"
