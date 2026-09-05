#!/bin/bash
# Internal deep consistency check. No writes; exits 1 on problems.
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

problems=0
warn() { echo "  ✗ $*"; problems=$((problems + 1)); }
note() { echo "  ! $*"; }
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
        echo "  → 'intelligence init' converts it into an Intelligence project"
        exit 0
        ;;
esac

echo "project: $IP_ROOT"
manifest="$IP_ROOT/intelligence.yaml"
lock="$IP_ROOT/intelligence.lock"
if ! validate_project_lock "$IP_ROOT"; then
    warn "invalid intelligence.lock — restore a valid committed lock before continuing"
    echo "$problems problem(s)."
    exit 1
fi

stamp="$(read_schema_version "$manifest")"
eng="$(bundled_engine_version)"
if [ -z "$stamp" ]; then
    warn "manifest has no schema_version — run 'intelligence init'"
elif _ver_gt "$stamp" "$eng"; then
    if [ "$(_ver_major "$stamp")" -gt "$(_ver_major "$eng")" ]; then
        warn "manifest schema $stamp is a newer major than this CLI's engine $eng — update the CLI: npm i -g @ainova-systems/intelligence@latest"
    else
        note "manifest schema $stamp is newer than this CLI's engine $eng — the project uses a newer CLI; update it: npm i -g @ainova-systems/intelligence@latest"
    fi
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
    elif [ "${sync_locked#v}" = "$stamp" ] && _ver_gt "$stamp" "$eng"; then
        note "$SYNC_PKG_NAME at $sync_locked (matches the project schema; the engine is $eng)"
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
        ok "$name @ $(pin_label "$m_ref" "$l_res" "$(qmap_field "$lock" "packages" "$name" "sha")")"
    fi
done < <(qmap_keys "$manifest" "packages")

# Adapter contracts are the shared source of truth for dependencies, rollback,
# onboarding backup and Git policy. Validate every declared target, including
# disabled ones, so a later enable cannot reveal a stale custom adapter.
content_dir="$(manifest_intelligence_dir "$manifest")"
while IFS= read -r target; do
    [ -n "$target" ] || continue
    output="$(get_target_output "$manifest" "$target")"
    [ -n "$output" ] || output="$(default_target_output "$target")"
    adapter_file="$(adapter_file_for "$IP_ROOT" "$content_dir" "$target" 2>/dev/null || true)"
    if [ -z "$adapter_file" ]; then
        warn "adapter '$target' is declared but its implementation is missing"
        continue
    fi
    records="$(adapter_contract_records "$target" "$adapter_file" "$output" 2>/dev/null || true)"
    if ! printf '%s\n' "$records" | grep -Fqx $'version\t1'; then
        warn "adapter '$target' has an invalid ownership contract"
        continue
    fi
    while IFS=$'\t' read -r kind value; do
        if [ "$kind" = "requires" ] \
            && [ "$(is_target_enabled "$manifest" "$target")" = "1" ] \
            && [ "$(is_target_enabled "$manifest" "$value")" != "1" ]; then
            warn "enabled adapter '$target' requires enabled adapter '$value'"
        fi
        if [ "$(is_target_enabled "$manifest" "$target")" = "1" ]; then
            case "$kind" in
                ignore)
                    grep -Fqx -- "$value" "$IP_ROOT/.gitignore" 2>/dev/null \
                        || warn "adapter '$target' Git policy is missing '$value'"
                    ;;
                include)
                    if ! grep -Fqx -- "!$value" "$IP_ROOT/.gitignore" 2>/dev/null; then
                        warn "adapter '$target' Git policy is missing '!$value'"
                    elif git -C "$IP_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
                        if git -C "$IP_ROOT" check-ignore -q --no-index -- "$value"; then
                            warn "adapter '$target' Git policy cannot re-include '$value' because another ignore rule still wins"
                        else
                            ignore_rc=$?
                            [ "$ignore_rc" -eq 1 ] \
                                || warn "adapter '$target' Git policy for '$value' could not be evaluated"
                        fi
                    fi
                    ;;
            esac
        fi
    done <<< "$records"
    ok "adapter $target contract v1"
done < <(target_names "$manifest")

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
