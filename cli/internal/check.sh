#!/bin/bash
# Internal deep consistency check. No writes; exits 1 on problems.
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
        echo "project: legacy Intelligence Sync at $IP_ROOT"
        ok "vendored engine $(tr -d ' \t\r\n' < "$IP_MODULE_DIR/scripts/VERSION")"
        echo "  → 'intelligence init' converts it to the CLI setup"
        exit 0
        ;;
esac

echo "project: $IP_ROOT"
manifest="$IP_ROOT/intelligence.yaml"
lock="$IP_ROOT/intelligence.lock"

stamp="$(read_schema_version "$manifest")"
eng="$(bundled_engine_version)"
if [ -z "$stamp" ]; then
    warn "manifest has no schema_version — run 'intelligence init'"
elif _ver_gt "$stamp" "$eng"; then
    warn "manifest schema $stamp is newer than this CLI's engine $eng — update the CLI: npm i -g @ainova-systems/intelligence@latest"
elif _ver_gt "$eng" "$stamp"; then
    warn "manifest schema $stamp behind engine $eng — run 'intelligence init'"
else
    ok "schema_version $stamp matches the engine"
fi

# The engine-content package must sit at the bundled engine version — the
# content documents exactly the scripts the CLI executes.
sync_locked="$(qmap_field "$lock" "packages" "$SYNC_PKG_NAME" "resolved")"
if [ -n "$sync_locked" ]; then
    if [ "${sync_locked#v}" = "$eng" ]; then
        ok "$SYNC_PKG_NAME at $sync_locked (matches the engine)"
    else
        warn "$SYNC_PKG_NAME locked at $sync_locked but the engine is $eng — run 'intelligence init'"
    fi
fi
if [ -d "$IP_ROOT/.intelligence/engine" ]; then
    warn "stale .intelligence/engine directory (pre-package layout) — run 'intelligence init'"
fi

# Manifest packages: names valid, requested intent only, locked and installed.
# The lock is authoritative for resolved source URL/path until an explicit
# package re-add changes that trust decision.
while IFS= read -r name; do
    [ -n "$name" ] || continue
    assert_valid_pkg_name "$name"
    if [ -z "$(qmap_field "$lock" "packages" "$name" "url")" ]; then
        warn "$name is in the manifest but not in intelligence.lock — run 'intelligence init'"
    else
        m_ver="$(qmap_field "$manifest" "packages" "$name" "version")"
        m_ref="$(qmap_field "$manifest" "packages" "$name" "ref")"
        l_req="$(qmap_field "$lock" "packages" "$name" "requested")"
        l_res="$(qmap_field "$lock" "packages" "$name" "resolved")"
        [ -z "$m_ver" ] || [ "$m_ver" = "$l_req" ] \
            || warn "$name requests '$m_ver' but the lock recorded '$l_req' — run 'intelligence update --preview'"
        [ -z "$m_ref" ] || [ "$m_ref" = "$l_res" ] \
            || warn "$name pins ref '$m_ref' but the lock resolved '$l_res'"
        if [ -n "$(qmap_field "$manifest" "packages" "$name" "url")" ] \
            || [ -n "$(qmap_field "$manifest" "packages" "$name" "path")" ]; then
            warn "$name stores source details in the manifest — run 'intelligence init --apply' to move them to the lock-only model"
        fi
        if [ ! -d "$IP_ROOT/.intelligence/packages/$name" ]; then
            warn "$name is locked but not installed — run 'intelligence sync'"
            continue
        fi
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
        [ "$found" -eq 1 ] || warn "$name is locked but absent from the manifest — 'intelligence package remove $name' cleans it up"
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
                # Store content is restorable state: absent means un-installed.
                .intelligence/*) warn "sources.$section '$src' missing — run 'intelligence sync'" ;;
                # A project-owned dir that does not exist yet is a legitimate
                # state — a project consuming only packages authors nothing of
                # its own — and the engine simply skips it. Declared up front so
                # authoring later needs no config edit.
                *) ok "sources.$section '$src' — not created yet (optional)" ;;
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
