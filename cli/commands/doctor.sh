#!/bin/bash
# intelligence doctor — consistency checks, no writes. Exit 1 on problems.
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

problems=0
warn() { echo "  ✗ $*"; problems=$((problems + 1)); }
ok()   { echo "  ✓ $*"; }

echo "environment:"
command -v git >/dev/null 2>&1 && ok "git $(git --version | awk '{print $3}')" || warn "git not found"
command -v awk >/dev/null 2>&1 && ok "awk present" || warn "awk not found"
ok "bash $BASH_VERSION"
ok "engine $(bundled_engine_version) at $IS_ENGINE_DIR"

detect_project
case "$IP_MODE" in
    none)
        echo "project: none here — 'intelligence init' starts one"
        exit 0
        ;;
    legacy)
        echo "project: vendored (v1) at $IP_ROOT"
        ok "vendored engine $(tr -d ' \t\r\n' < "$IP_MODULE_DIR/scripts/VERSION")"
        echo "  → 'intelligence migrate' converts it to the CLI setup"
        exit 0
        ;;
esac

echo "project: $IP_ROOT"
manifest="$IP_ROOT/intelligence.yaml"
lock="$IP_ROOT/intelligence.lock"

stamp="$(read_engine_stamp "$manifest")"
eng="$(bundled_engine_version)"
if [ -z "$stamp" ]; then
    warn "manifest has no sync_version — run 'intelligence upgrade'"
elif _ver_gt "$stamp" "$eng"; then
    warn "manifest schema $stamp is newer than this CLI's engine $eng — update the CLI: npm i -g @ainova-systems/intelligence@latest"
elif _ver_gt "$eng" "$stamp"; then
    warn "manifest schema $stamp behind engine $eng — run 'intelligence upgrade'"
else
    ok "sync_version $stamp matches the engine"
fi

if [ -f "$IP_ROOT/.intelligence/engine/.version" ]; then
    staged="$(tr -d ' \t\r\n' < "$IP_ROOT/.intelligence/engine/.version")"
    [ "$staged" = "$eng" ] && ok "engine content staged ($staged)" || warn "staged engine content is $staged, bundled is $eng — run 'intelligence install'"
else
    warn "engine content not staged — run 'intelligence install'"
fi

# Manifest packages: names valid, locked, installed.
while IFS= read -r name; do
    [ -n "$name" ] || continue
    assert_valid_pkg_name "$name"
    if [ -z "$(qmap_field "$lock" "packages" "$name" "url")" ]; then
        warn "$name is in the manifest but not in intelligence.lock — run 'intelligence install'"
    elif [ ! -d "$IP_ROOT/.intelligence/packages/$name" ]; then
        warn "$name is locked but not installed — run 'intelligence install'"
    else
        ok "$name @ $(qmap_field "$lock" "packages" "$name" "resolved")"
    fi
done < <(qmap_keys "$manifest" "packages")

# Lock orphans.
if [ -f "$lock" ]; then
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        found=0
        while IFS= read -r m; do
            [ "$m" = "$name" ] && found=1
        done < <(qmap_keys "$manifest" "packages")
        [ "$found" -eq 1 ] || warn "$name is locked but absent from the manifest — 'intelligence remove $name' cleans it up"
    done < <(qmap_keys "$lock" "packages")
fi

# Sources must exist (a missing dir is silently skipped by the engine, which
# is exactly why doctor names it).
for section in rules agents skills; do
    while IFS= read -r src; do
        [ -n "$src" ] || continue
        case "$src" in
            git+*|@*) continue ;;
        esac
        if [ ! -d "$IP_ROOT/$src" ]; then
            case "$src" in
                .intelligence/*) warn "sources.$section '$src' missing — run 'intelligence install'" ;;
                *) warn "sources.$section '$src' does not exist" ;;
            esac
        fi
    done < <(read_yaml_list "$manifest" "$section")
done

if [ "$problems" -eq 0 ]; then
    echo "all good."
else
    echo "$problems problem(s)."
    exit 1
fi
