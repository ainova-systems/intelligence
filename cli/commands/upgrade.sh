#!/bin/bash
# intelligence upgrade [--next] [--preview|--apply]
#
# Replace the installed CLI with the newest version on its npm channel:
# `next` when the running version is a prerelease or --next is given,
# `latest` otherwise. `update` plans this step and points here; this is the
# one command that writes to an npm prefix, and it never reads or writes a
# project.
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

mode="ask" preview_seen=0 apply_seen=0 channel=""
while [ $# -gt 0 ]; do
    case "$1" in
        --preview) preview_seen=1; mode="preview" ;;
        --apply) apply_seen=1; mode="apply" ;;
        --next) channel="next" ;;
        *) die "usage: intelligence upgrade [--next] [--preview|--apply]" ;;
    esac
    shift
done
[ "$preview_seen" -eq 0 ] || [ "$apply_seen" -eq 0 ] || die "choose either --preview or --apply"

pkg_dir="$(cd "$CLI_DIR/.." && pwd -P)"
installed="${INTELLIGENCE_NPM_VERSION:-}"
pkg="${INTELLIGENCE_NPM_PACKAGE:-}"
bin="${INTELLIGENCE_NPM_BIN:-}"
# All of it comes from the npm launcher; `bash cli/intelligence` in a checkout has none.
[ -n "$installed" ] && [ -n "$pkg" ] && [ -n "$bin" ] && [ -n "${INTELLIGENCE_NPM_LAUNCHER:-}" ] \
    || die "this CLI runs from a source checkout ($pkg_dir), not an npm installation — pull the repository instead"
command -v npm >/dev/null 2>&1 || die "npm is not on PATH — it installed this CLI and is needed to replace it"
[ -n "$channel" ] || channel="$(npm_channel_for "$installed")"

# Where this tree lives is decided locally, before any network: a tree npm
# did not make is refused whatever the registry would say. The hint names
# the exact version when the registry answers and the channel otherwise.
cli_install_classify "$pkg_dir" "$pkg" "$bin"
if [ "$CLI_INSTALL_KIND" != "npm" ]; then
    available="$(cli_registry_version "$pkg" "$channel" || true)"
    die "this CLI ($pkg_dir) is not an npm global installation — $(cli_install_hint "$CLI_INSTALL_KIND" "$pkg" "${available:-$channel}")"
fi
prefix="$(native_path "$CLI_INSTALL_PREFIX")"
launcher="$(native_path "$pkg_dir/$INTELLIGENCE_NPM_LAUNCHER")"

available="$(cli_registry_version "$pkg" "$channel" "$prefix")" \
    || die "npm could not report a version for $pkg dist-tag $channel — check the network or the registry and retry"

case "$(semver_cmp_full "$available" "$installed")" in
    0)
        echo "CLI $installed is up to date (npm $channel)"
        exit 0
        ;;
    -1)
        # Never a downgrade: a channel moved back on purpose is a decision
        # the user takes by hand, with the command that does it.
        echo "CLI $installed is newer than npm $channel ($available); nothing to do"
        echo "  to move back deliberately: npm install -g --prefix $(quote_for_shell "$prefix") $pkg@$available"
        exit 0
        ;;
esac

echo "CLI upgrade: $installed -> $available (npm $channel)"
echo "  npm install -g --prefix $(quote_for_shell "$prefix") $pkg@$available"
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

# npm rewrites the directory this script lives in, and Windows refuses to
# delete a file another process still holds open. `bash -c` parses its whole
# program before running it, so the fresh shell reads nothing from the
# package while npm replaces it, and exec leaves no old process behind.
# The version installed is the one the plan showed, never a moving tag, and
# success is what the new launcher reports, not what npm returned.
exec "$BASH" -c '
    set -euo pipefail
    pkg="$1" from="$2" to="$3" launcher="$4" prefix="$5" bin="$6"
    npm install -g --prefix "$prefix" "$pkg@$to"
    echo ""
    if [ -f "$launcher" ] && command -v node >/dev/null 2>&1; then
        got="$(node "$launcher" version 2>/dev/null || true)"
        case "$got" in
            "$to"|"$to "*) echo "upgraded: $from -> $to"; echo "$got" ;;
            *)
                echo "ERROR: npm reported success but the installed launcher answers: ${got:-<nothing>}" >&2
                echo "       expected $to — inspect the installation at $prefix" >&2
                exit 1
                ;;
        esac
    else
        echo "upgraded: $from -> $to (not verified — run: $bin version)"
    fi
' intelligence-upgrade "$pkg" "$installed" "$available" "$launcher" "$prefix" "$bin"
