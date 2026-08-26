#!/bin/bash
# Shared plumbing for every CLI command. Commands are separate processes (the
# dispatcher execs them), so each one sources this file first.
#
# All YAML reading goes through the engine's lib/common.sh — the CLI never
# grows a parallel parser for shapes the engine can already read. The only
# CLI-owned parsing lives in lib/manifest.sh (quoted-key `packages:` /
# `registries:` blocks, which the engine deliberately never reads).

# Engine libraries (readers, is_status, IS_RC_*, engine_version). CLI_DIR /
# IS_ENGINE_DIR come exported from the dispatcher.
source "$IS_ENGINE_DIR/lib/common.sh"
source "$IS_ENGINE_DIR/lib/contract.sh"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# --- Untrusted-input guards ----------------------------------------------
# Manifest, lock and registry indexes arrive with a cloned repo: every value
# they carry is attacker-adjacent. URLs and refs reach git argv (a leading
# `-` would be an option — `--upload-pack=<cmd>` is code execution), names
# become store paths fed to rm -rf. Guard at the choke points, loudly.

# assert_safe_source_url <url> — scheme allowlist (the engine's own list) or
# scp-like user@host:path; never option-shaped, never quote-bearing.
assert_safe_source_url() {
    local url="$1"
    case "$url" in
        ""|-*) die "unsafe source url '$url' — option-shaped or empty" ;;
        *[\"\'\ ]*) die "unsafe source url '$url' — quotes or spaces" ;;
        https://*|http://*|ssh://*|git://*|file://*) ;;
        *@*:*) ;;
        *) die "unsafe source url '$url' — allowed: https, http, ssh, git, file, or user@host:path" ;;
    esac
}

# assert_safe_ref <ref-or-empty> — tags/branches/SHAs; never option-shaped.
assert_safe_ref() {
    local ref="$1"
    [ -z "$ref" ] && return 0
    case "$ref" in
        -*) die "unsafe git ref '$ref' — option-shaped" ;;
        *[\"\'\ \\]*) die "unsafe git ref '$ref'" ;;
    esac
}

source "$CLI_DIR/lib/manifest.sh"
source "$CLI_DIR/lib/semver.sh"
source "$CLI_DIR/lib/registry.sh"
source "$CLI_DIR/lib/lockfile.sh"

# The engine-content package: OPTIONAL but auto-selected at init. Package by
# UX (manifest entry, lockfile row, list/search/remove), bundle by mechanics —
# at the version the CLI ships, it materializes from the npm bundle without
# network; only a cross-version acquisition reaches git. The pin is held
# exactly at the bundled engine version and moved by lifecycle alignment.
#
# Its identity is DATA shipped with the distribution (cli/engine-package.yaml),
# never a name compiled into cli code — a fork edits the file.
_EPKG="$CLI_DIR/engine-package.yaml"
SYNC_PKG_NAME="$(top_scalar "$_EPKG" "name")"
SYNC_PKG_URL="$(top_scalar "$_EPKG" "url")"
SYNC_PKG_PATH="$(top_scalar "$_EPKG" "path")"
# Read by commands (init seeds it) — per-file shellcheck cannot see that.
# shellcheck disable=SC2034
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
        legacy) die "this is a vendored (v1) setup — run 'intelligence init' to migrate it, or keep using its own flow" ;;
        *) die "no intelligence project found here — run 'intelligence init'" ;;
    esac
}

# --- Manifest basics (engine-readable shapes) ----------------------------

manifest_intelligence_dir() {
    local manifest="$1" v
    v="$(get_yaml_field "$manifest" "project" "intelligence_dir")"
    printf '%s' "${v:-intelligence}"
}

default_target_output() {
    case "$1" in
        agents) printf '%s' "AGENTS.md" ;;
        copilot) printf '%s' ".github" ;;
        *) printf '.%s' "$1" ;;
    esac
}

bundled_engine_version() {
    tr -d ' \t\r\n' < "$IS_ENGINE_DIR/VERSION"
}

# --- The sync package's manifest/lock plumbing ---------------------------
# sync_pkg_entry <manifest> — write/refresh only the requested exact pin.
# The built-in source lives in engine-package.yaml and resolved source state
# belongs exclusively to intelligence.lock.
sync_pkg_entry() {
    local manifest="$1"
    qmap_set "$manifest" "packages" "$SYNC_PKG_NAME" "version" "$(bundled_engine_version)"
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
    local content_rel
    content_rel="$(manifest_intelligence_dir "$root/intelligence.yaml")"
    export IS_CLI=1
    export CONFIG_FILE="$root/intelligence.yaml"
    export REPO_ROOT="$root"
    export IS_CONTENT_REL="$content_rel"
    export IS_MODULE_REL="$SYNC_PKG_STORE"
    export IS_SYNC_CMD="intelligence sync"
    export IS_MANIFEST_NAME="intelligence.yaml"
    export IS_PROTECTED_DIRS="$content_rel:.intelligence"
}

# --- Project lifecycle preflight -----------------------------------------
# Public commands are intentionally few. They share this state gate so a CLI
# installed at a newer engine version brings the current v2 project forward
# before a mutating operation. The npm install itself cannot do that: it runs
# outside any project and does not know which repositories the user owns.

is_ci_environment() {
    case "${CI:-}" in
        1|true|TRUE|True|yes|YES|Yes|on|ON|On) return 0 ;;
        *) return 1 ;;
    esac
}

# Validate a repository-relative project content directory, including every
# existing symlinked path component. Call before writing a new manifest.
assert_safe_content_dir() {
    local root="$1" content_dir="$2" repo_phys probe old_ifs part probe_phys
    local -a parts
    case "$content_dir" in
        ""|/*|.|..|../*|*/../*|*/..|.git|.git/*|.intelligence|.intelligence/*|*\\*|[A-Za-z]:*)
            die "unsafe content directory '$content_dir'"
            ;;
    esac
    repo_phys="$(cd "$root" && pwd -P)"
    probe="$root"
    old_ifs="$IFS"; IFS='/'; read -r -a parts <<< "$content_dir"; IFS="$old_ifs"
    for part in "${parts[@]}"; do
        [ -n "$part" ] || continue
        probe="$probe/$part"
        if [ -e "$probe" ] || [ -L "$probe" ]; then
            probe_phys="$(cd "$probe" 2>/dev/null && pwd -P)" \
                || die "cannot resolve project content path '$content_dir'"
            case "$probe_phys" in
                "$repo_phys"|"$repo_phys"/*) ;;
                *) die "project content directory resolves outside the repository: '$content_dir'" ;;
            esac
        fi
    done
}

project_needs_upgrade() {
    local root="$1" manifest="$1/intelligence.yaml" stamp eng pinned locked name
    [ -f "$manifest" ] || return 1
    stamp="$(read_schema_version "$manifest")"
    eng="$(bundled_engine_version)"
    [ -z "$stamp" ] && return 0
    [ -n "$(top_scalar "$manifest" "sync_version")" ] && return 0
    _ver_gt "$eng" "$stamp" && return 0
    [ -d "$root/.intelligence/engine" ] && return 0

    while IFS= read -r name; do
        [ -n "$name" ] || continue
        # Early RC manifests mixed requested intent with resolved source
        # details. Source URL/path now live only in the required lockfile.
        [ -n "$(qmap_field "$manifest" "packages" "$name" "url")" ] && return 0
        [ -n "$(qmap_field "$manifest" "packages" "$name" "path")" ] && return 0
        if [ "$name" = "$SYNC_PKG_NAME" ]; then
            pinned="$(qmap_field "$manifest" "packages" "$name" "version")"
            locked="$(qmap_field "$root/intelligence.lock" "packages" "$name" "resolved")"
            [ "$pinned" = "$eng" ] || return 0
            if [ -f "$root/intelligence.lock" ]; then
                [ -n "$locked" ] || return 0
                [ "${locked#v}" = "$eng" ] || return 0
            fi
        fi
    done < <(qmap_keys "$manifest" "packages")
    return 1
}

# A manifest with packages but no lock has no trustworthy resolved state from
# which lifecycle alignment can proceed. Never manufacture a partial lock.
project_has_packages() {
    local root="$1" name found=1
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        assert_valid_pkg_name "$name"
        found=0
    done < <(qmap_keys "$root/intelligence.yaml" "packages")
    return "$found"
}

ensure_project_current() {
    local root="$1" explicit="${2:-}" manifest="$1/intelligence.yaml" stamp eng
    check_version_compat "$manifest" || return $?
    if project_has_packages "$root" && [ ! -f "$root/intelligence.lock" ]; then
        die "manifest declares packages but intelligence.lock is absent — restore the committed lock before running project lifecycle commands"
    fi
    project_needs_upgrade "$root" || return 0
    stamp="$(read_schema_version "$manifest")"
    eng="$(bundled_engine_version)"
    if is_ci_environment && [ "$explicit" != "--explicit" ]; then
        die "project lifecycle requires alignment (stamp ${stamp:-unstamped}, engine $eng) — run 'intelligence init --apply' locally, review and commit the diff"
    fi
    echo "  project alignment: stamp ${stamp:-unstamped}, engine $eng"
    bash "$CLI_DIR/internal/upgrade-v2.sh" --no-sync
}

project_store_missing() {
    local root="$1" manifest="$1/intelligence.yaml" name src
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        assert_valid_pkg_name "$name"
        [ -d "$root/.intelligence/packages/$name" ] || return 0
    done < <(qmap_keys "$manifest" "packages")
    for section in rules agents skills; do
        while IFS= read -r src; do
            case "$src" in
                .intelligence/packages/*)
                    [ -d "$root/$src" ] || return 0
                    ;;
            esac
        done < <(read_yaml_list "$manifest" "$section")
    done
    return 1
}

restore_project_store_if_missing() {
    local root="$1"
    project_store_missing "$root" || return 0
    [ -f "$root/intelligence.lock" ] || die "package store is missing and intelligence.lock is absent — run 'intelligence init'"
    echo "  restoring package store from intelligence.lock"
    bash "$CLI_DIR/internal/restore.sh" --frozen --no-sync
}
