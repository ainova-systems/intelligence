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

# Meta-skills that the CLI replaces with first-class commands — staging skips
# them so a v2 project never carries a skill telling the agent to run a flow
# the CLI already owns.
CLI_OBSOLETE_SKILLS="intelligence-update intelligence-sync"

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

# --- Engine content staging ----------------------------------------------
# The v2 project vendors no engine code; the engine's own rules / agents /
# meta-skills / docs are staged into the package store so sources can reach
# them as ordinary repo-relative dirs. Re-staged whenever the bundled engine
# version differs from the `.version` stamp.
# stage_engine_content <dest-dir> — unconditional copy of the engine's own
# content into <dest-dir> plus the `.version` stamp.
stage_engine_content() {
    local store="$1"
    rm -rf "$store"
    mkdir -p "$store"
    local d s name skip
    # `scripts` travels too: engine-shipped skills reference `<module>/scripts/…`
    # (adapters, docs) and `<module>` resolves here, so the paths they hand an
    # agent must exist. Running that sync.sh directly is harmless — outside CLI
    # mode it fails closed rather than generating against the wrong layout.
    for d in rules agents docs scripts; do
        [ -d "$IS_ENGINE_DIR/$d" ] && cp -R "$IS_ENGINE_DIR/$d" "$store/$d"
    done
    if [ -d "$IS_ENGINE_DIR/skills" ]; then
        mkdir -p "$store/skills"
        for s in "$IS_ENGINE_DIR"/skills/*/; do
            [ -d "$s" ] || continue
            name="$(basename "$s")"
            skip=0
            for d in $CLI_OBSOLETE_SKILLS; do
                [ "$name" = "$d" ] && skip=1
            done
            [ "$skip" = "1" ] && continue
            cp -R "$s" "$store/skills/$name"
        done
    fi
    bundled_engine_version > "$store/.version"
}

ensure_engine_staged() {
    local root="$1"
    local store="$root/.intelligence/engine"
    local bundled_ver staged_ver
    bundled_ver="$(bundled_engine_version)"
    staged_ver=""
    [ -f "$store/.version" ] && staged_ver="$(tr -d ' \t\r\n' < "$store/.version")"
    [ "$staged_ver" = "$bundled_ver" ] && return 0
    stage_engine_content "$store"
    echo "  engine content staged: .intelligence/engine ($bundled_ver)"
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
    export IS_MODULE_REL=".intelligence/engine"
    export IS_SYNC_CMD="intelligence sync"
    export IS_PROTECTED_DIRS="$umbrella:.intelligence"
}
