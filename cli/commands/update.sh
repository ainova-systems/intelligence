#!/bin/bash
# intelligence update [@scope/name] [--preview|--apply]
#
# One update surface: show the installed-CLI/project/package plan, then either
# stop, ask interactively, or apply without a prompt. Updating the global npm
# installation remains an explicit package-manager operation.
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

only="" mode="ask" preview_seen=0 apply_seen=0
while [ $# -gt 0 ]; do
    case "$1" in
        --preview) preview_seen=1; mode="preview" ;;
        --apply) apply_seen=1; mode="apply" ;;
        @*) [ -z "$only" ] || die "only one package may be selected"; only="$1" ;;
        *) die "usage: intelligence update [@scope/name] [--preview|--apply]" ;;
    esac
    shift
done
[ "$preview_seen" -eq 0 ] || [ "$apply_seen" -eq 0 ] || die "choose either --preview or --apply"

require_cli_project
manifest="$IP_ROOT/intelligence.yaml"
check_version_compat "$manifest"
validate_project_lock "$IP_ROOT"
eng="$(bundled_engine_version)"
stamp="$(read_schema_version "$manifest")"
project_change=0

echo "Update plan"
echo ""
echo "CLI:"
if [ -n "${INTELLIGENCE_NPM_VERSION:-}" ] && [ "${IS_SKIP_NPM_CHECK:-0}" != "1" ] && command -v npm >/dev/null 2>&1; then
    channel="latest"
    case "$INTELLIGENCE_NPM_VERSION" in *-*) channel="next" ;; esac
    available="$(npm view "@ainova-systems/intelligence" "dist-tags.$channel" 2>/dev/null || true)"
    if [ -z "$available" ]; then
        echo "  installed: $INTELLIGENCE_NPM_VERSION; registry check unavailable"
    elif [ "$available" = "$INTELLIGENCE_NPM_VERSION" ]; then
        echo "  $INTELLIGENCE_NPM_VERSION (up to date on npm $channel)"
    else
        echo "  $INTELLIGENCE_NPM_VERSION -> $available (npm $channel)"
        echo "  run: npm install -g @ainova-systems/intelligence@$channel"
        echo "  then rerun: intelligence update --apply"
    fi
else
    echo "  source checkout/registry check skipped; engine $eng"
fi

echo ""
echo "Project:"
if project_stamped_ahead "$IP_ROOT"; then
    echo "  schema $stamp is ahead of engine $eng — left as is; update the CLI to align it"
elif project_needs_upgrade "$IP_ROOT"; then
    echo "  lifecycle alignment required (stamp ${stamp:-unstamped}, engine $eng)"
    project_change=1
else
    echo "  schema/content $eng (up to date)"
fi

if project_has_packages "$IP_ROOT" && [ ! -f "$IP_ROOT/intelligence.lock" ]; then
    die "manifest declares packages but intelligence.lock is absent — restore the committed lock before planning or applying updates"
fi

pkg_args=(--preview)
[ -z "$only" ] || pkg_args+=("$only")
pkg_plan="$(bash "$CLI_DIR/internal/package-update.sh" "${pkg_args[@]}")"
echo ""
echo "Packages:"
printf '%s\n' "$pkg_plan"
package_changes="$(printf '%s\n' "$pkg_plan" | awk '/^updates available:/ {print $3; exit}')"
package_changes="${package_changes:-0}"

if [ "$mode" = "preview" ]; then
    exit 0
fi
if [ "$project_change" -eq 0 ] && [ "$package_changes" -eq 0 ]; then
    echo ""
    echo "Nothing to apply with the currently installed CLI."
    exit 0
fi
if [ "$mode" = "ask" ]; then
    [ -t 0 ] || die "update requires confirmation — rerun with --preview or --apply"
    printf '\nApply this plan? [Y/n] '
    read -r answer
    case "$answer" in
        ""|y|Y|yes|YES) ;;
        *) echo "update cancelled"; exit 0 ;;
    esac
fi

ensure_project_current "$IP_ROOT"
apply_args=(--no-sync)
[ -z "$only" ] || apply_args+=("$only")
bash "$CLI_DIR/internal/package-update.sh" "${apply_args[@]}"
exec bash "$CLI_DIR/commands/sync.sh"
