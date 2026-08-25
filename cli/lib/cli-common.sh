#!/bin/bash
# Shared plumbing for every CLI command. Commands are separate processes (the
# dispatcher execs them), so each one sources this file first.
#
# All YAML reading goes through the engine's lib/common.sh — the CLI never
# grows a parallel parser for shapes the engine can already read. The only
# CLI-owned parsing lives in lib/manifest.sh (quoted-key `packages:` /
# `registries:` blocks, which the engine deliberately never reads).

# Engine libraries (readers, is_status, IS_RC_*, engine_version). Sourced in
# the same order sync.sh uses. CLI_DIR / IS_ENGINE_DIR come exported from the
# dispatcher.
source "$IS_ENGINE_DIR/scripts/lib/common.sh"
source "$IS_ENGINE_DIR/scripts/lib/layout.sh"
source "$IS_ENGINE_DIR/scripts/lib/migrations.sh"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

source "$CLI_DIR/lib/manifest.sh"
source "$CLI_DIR/lib/semver.sh"
source "$CLI_DIR/lib/registry.sh"
source "$CLI_DIR/lib/lockfile.sh"

# The engine-content package: OPTIONAL but auto-selected at init. Package by
# UX (manifest entry, lockfile row, list/search/remove), bundle by mechanics —
# at the version the CLI ships, it materializes from the npm bundle without
# network; only a cross-version install reaches git. The pin is held exactly
# at the bundled engine version and moved only by `upgrade`.
#
# Its identity is DATA shipped with the distribution (cli/engine-package.yaml),
# never a name compiled into cli code — a fork edits the file.
_EPKG="$CLI_DIR/engine-package.yaml"
SYNC_PKG_NAME="$(top_scalar "$_EPKG" "name")"
SYNC_PKG_URL="$(top_scalar "$_EPKG" "url")"
SYNC_PKG_PATH="$(top_scalar "$_EPKG" "path")"
DEFAULT_REGISTRY_URL="$(top_scalar "$_EPKG" "default_registry")"
[ -n "$SYNC_PKG_NAME" ] || die "corrupt CLI installation: $_EPKG is missing or has no 'name'"
SYNC_PKG_STORE=".intelligence/packages/$SYNC_PKG_NAME"

# --- Project detection ---------------------------------------------------
# Sets: IP_MODE (v2|legacy|none), IP_ROOT, IP_UMBRELLA, IP_MODULE_DIR.
# These ARE this lib's public API — every command reads them after calling
# detect_project, which per-file shellcheck cannot see.
# shellcheck disable=SC2034
# v2 wins: the nearest ancestor holding intelligence.yaml. Legacy is a git
# repo holding an umbrella (a dir with config.yaml) whose module is identified
# by role — scripts/sync.sh + scripts/VERSION — never by name.
detect_project() {
    IP_MODE="none"; IP_ROOT=""; IP_UMBRELLA=""; IP_MODULE_DIR=""
    local dir="$PWD"
    while :; do
        if [ -f "$dir/intelligence.yaml" ]; then
            IP_MODE="v2"
            IP_ROOT="$(cd "$dir" && pwd)"
            return 0
        fi
        [ "$dir" = "$(dirname "$dir")" ] && break
        dir="$(dirname "$dir")"
    done
    local root
    root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$root" ] || return 0
    root="$(cd "$root" && pwd)"
    local cf umbrella mod
    while IFS= read -r cf; do
        [ -n "$cf" ] || continue
        umbrella="$(cd "$(dirname "$cf")" && pwd)"
        for mod in "$umbrella"/*/; do
            [ -d "$mod" ] || continue
            if [ -f "${mod}scripts/sync.sh" ] && [ -f "${mod}scripts/VERSION" ]; then
                IP_MODE="legacy"; IP_ROOT="$root"; IP_UMBRELLA="$umbrella"
                IP_MODULE_DIR="${mod%/}"
                return 0
            fi
        done
    done < <(find "$root" -maxdepth 2 -name 'config.yaml' -not -path '*/.*' 2>/dev/null)
    return 0
}

require_v2() {
    detect_project
    case "$IP_MODE" in
        v2) ;;
        legacy) die "this is a vendored (v1) setup — run 'intelligence migrate' first, or keep using its own flow" ;;
        *) die "no intelligence project found here — run 'intelligence init'" ;;
    esac
}

# --- Manifest basics (engine-readable shapes) ----------------------------

manifest_intelligence_dir() {
    local manifest="$1" v
    v="$(get_yaml_field "$manifest" "project" "intelligence_dir")"
    printf '%s' "${v:-intelligence}"
}

bundled_engine_version() {
    tr -d ' \t\r\n' < "$IS_ENGINE_DIR/scripts/VERSION"
}

# --- The sync package's manifest/lock plumbing ---------------------------
# sync_pkg_entry <manifest> — write/refresh the package's manifest entry:
# name + exact pin + explicit url/path, so resolution never depends on any
# registry (a project registry shadowing the name cannot brick the engine).
sync_pkg_entry() {
    local manifest="$1"
    qmap_set "$manifest" "packages" "$SYNC_PKG_NAME" "version" "$(bundled_engine_version)"
    qmap_set "$manifest" "packages" "$SYNC_PKG_NAME" "url" "$SYNC_PKG_URL"
    qmap_set "$manifest" "packages" "$SYNC_PKG_NAME" "path" "$SYNC_PKG_PATH"
}

# sync_pkg_install <root> — materialize the package into the store and lock
# it (offline at the bundled version — fetch_package's bundle-seed guard).
sync_pkg_install() {
    local root="$1" ver sha
    ver="$(bundled_engine_version)"
    sha="$(fetch_package "$SYNC_PKG_URL" "v$ver" "$SYNC_PKG_PATH" "$root/$SYNC_PKG_STORE")"
    wire_package_sources "$root/intelligence.yaml" "$SYNC_PKG_NAME" "$SYNC_PKG_STORE" "$root"
    lock_upsert "$root/intelligence.lock" "$SYNC_PKG_NAME" "$ver" "$SYNC_PKG_URL" "$SYNC_PKG_PATH" "v$ver" "$sha"
    echo "  engine content installed: $SYNC_PKG_STORE (v$ver)"
}

# --- The engine env contract ---------------------------------------------
# Everything the IS_CLI mode of sync.sh needs, derived from the manifest.
export_engine_env() {
    local root="$1"
    local umbrella
    umbrella="$(manifest_intelligence_dir "$root/intelligence.yaml")"
    export IS_CLI=1
    export CONFIG_FILE="$root/intelligence.yaml"
    export REPO_ROOT="$root"
    export IS_UMBRELLA_REL="$umbrella"
    export IS_MODULE_REL="$SYNC_PKG_STORE"
    export IS_SYNC_CMD="intelligence sync"
    export IS_MANIFEST_NAME="intelligence.yaml"
    export IS_PROTECTED_DIRS="$umbrella:.intelligence"
}
