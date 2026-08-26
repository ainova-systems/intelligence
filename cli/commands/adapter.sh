#!/bin/bash
# intelligence adapter <list|create|enable|disable|remove> [name]
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

action="${1:-}"
name="${2:-}"

adapter_list() {
    detect_project
    local manifest="" content_dir="" seen=" " file item enabled output configured
    if [ "$IP_MODE" = "cli" ]; then
        manifest="$IP_ROOT/intelligence.yaml"
        content_dir="$(manifest_intelligence_dir "$manifest")"
    fi

    printf '%-16s %-10s %-10s %s\n' "NAME" "SOURCE" "STATE" "OUTPUT"
    # Project adapters come first because they override built-ins by name.
    if [ -n "$content_dir" ] && [ -d "$IP_ROOT/$content_dir/adapters" ]; then
        for file in "$IP_ROOT/$content_dir/adapters"/*.sh; do
            [ -f "$file" ] || continue
            item="$(basename "$file" .sh)"
            seen="$seen$item "
            enabled="disabled"; output="$(default_target_output "$item")"
            [ "$(is_target_enabled "$manifest" "$item")" = "1" ] && enabled="enabled"
            configured="$(get_target_output "$manifest" "$item")"
            [ -z "$configured" ] || output="$configured"
            printf '%-16s %-10s %-10s %s\n' "$item" "project" "$enabled" "$output"
        done
    fi
    for file in "$IS_ENGINE_DIR/adapters"/*.sh; do
        [ -f "$file" ] || continue
        item="$(basename "$file" .sh)"
        [ "$item" = "_template" ] && continue
        case "$seen" in *" $item "*) continue ;; esac
        enabled="disabled"; output="$(default_target_output "$item")"
        if [ -n "$manifest" ]; then
            [ "$(is_target_enabled "$manifest" "$item")" = "1" ] && enabled="enabled"
            configured="$(get_target_output "$manifest" "$item")"
            [ -z "$configured" ] || output="$configured"
        fi
        printf '%-16s %-10s %-10s %s\n' "$item" "built-in" "$enabled" "$output"
    done
}

adapter_create() {
    [ -n "$name" ] && [ $# -eq 0 ] || die "usage: intelligence adapter create <name>"
    assert_valid_target_name "$name"
    require_cli_project
    ensure_project_current "$IP_ROOT"
    local manifest="$IP_ROOT/intelligence.yaml" content_dir repo_phys probe old_ifs part probe_phys
    local template adapter_dir adapter_phys dest tmp
    local -a parts
    content_dir="$(manifest_intelligence_dir "$manifest")"
    case "$content_dir" in
        ""|/*|.|..|../*|*/../*|*/..|.intelligence|.intelligence/*)
            die "unsafe project.intelligence_dir '$content_dir'"
            ;;
    esac
    repo_phys="$(cd "$IP_ROOT" && pwd -P)"
    probe="$IP_ROOT"
    old_ifs="$IFS"; IFS='/'; read -r -a parts <<< "$content_dir"; IFS="$old_ifs"
    for part in "${parts[@]}"; do
        [ -n "$part" ] || continue
        probe="$probe/$part"
        if [ -e "$probe" ] || [ -L "$probe" ]; then
            probe_phys="$(cd "$probe" 2>/dev/null && pwd -P)" || die "cannot resolve project content path '$content_dir'"
            case "$probe_phys" in "$repo_phys"|"$repo_phys"/*) ;; *) die "project.intelligence_dir resolves outside the repository: '$content_dir'" ;; esac
        fi
    done
    template="$IS_ENGINE_DIR/adapters/_template.sh"
    [ -f "$template" ] || die "corrupt CLI installation: bundled adapter template is missing"
    adapter_dir="$IP_ROOT/$content_dir/adapters"
    dest="$adapter_dir/$name.sh"
    [ ! -e "$dest" ] || die "project adapter already exists: $content_dir/adapters/$name.sh"
    mkdir -p "$adapter_dir"
    adapter_phys="$(cd "$adapter_dir" && pwd -P)"
    case "$adapter_phys" in "$repo_phys"|"$repo_phys"/*) ;; *) die "project adapter directory resolves outside the repository" ;; esac
    tmp="$(mktemp "$adapter_dir/.${name}.XXXXXX")"
    trap '[ -z "${tmp:-}" ] || rm -f "$tmp"' EXIT
    awk -v name="$name" '{ gsub(/<agent-name>/, name); gsub(/<Agent Name>/, name); gsub(/<name>/, name); print }' "$template" > "$tmp"
    [ -s "$tmp" ] || die "adapter template produced an empty file"
    mv "$tmp" "$dest"
    tmp=""
    echo "created: $content_dir/adapters/$name.sh"
    echo "  implement sync_to_${name}(), then run: intelligence adapter enable $name"
}

adapter_remove() {
    local apply=0 manifest content_dir file answer repo_phys adapter_dir adapter_phys
    while [ $# -gt 0 ]; do
        case "$1" in --apply) apply=1 ;; *) die "unknown option '$1'" ;; esac
        shift
    done
    [ -n "$name" ] || die "usage: intelligence adapter remove <name> [--apply]"
    assert_valid_target_name "$name"
    require_cli_project
    ensure_project_current "$IP_ROOT"
    manifest="$IP_ROOT/intelligence.yaml"
    content_dir="$(manifest_intelligence_dir "$manifest")"
    case "$content_dir" in
        ""|/*|.|..|../*|*/../*|*/..|.intelligence|.intelligence/*)
            die "unsafe project.intelligence_dir '$content_dir'"
            ;;
    esac
    repo_phys="$(cd "$IP_ROOT" && pwd -P)"
    adapter_dir="$IP_ROOT/$content_dir/adapters"
    [ -d "$adapter_dir" ] || die "project adapter '$name' does not exist"
    adapter_phys="$(cd "$adapter_dir" 2>/dev/null && pwd -P)" || die "cannot resolve project adapter directory"
    case "$adapter_phys" in "$repo_phys"|"$repo_phys"/*) ;; *) die "project adapter directory resolves outside the repository" ;; esac
    file="$adapter_dir/$name.sh"
    [ -f "$file" ] || die "project adapter '$name' does not exist"
    [ "$(is_target_enabled "$manifest" "$name")" != "1" ] || die "adapter '$name' is enabled — disable it first"
    echo "remove project adapter source: $content_dir/adapters/$name.sh"
    if [ "$apply" -ne 1 ]; then
        [ -t 0 ] || die "removal requires confirmation — rerun with --apply"
        printf 'Remove it? [y/N] '
        read -r answer
        case "$answer" in y|Y|yes|YES) ;; *) echo "removal cancelled"; exit 0 ;; esac
    fi
    rm -f "$file"
    echo "removed: $content_dir/adapters/$name.sh"
    echo "  generated output was kept"
}

case "$action" in
    list)
        [ $# -eq 1 ] || die "usage: intelligence adapter list"
        adapter_list
        ;;
    create)
        shift 2 || true
        adapter_create "$@"
        ;;
    enable|disable)
        [ -n "$name" ] && [ $# -eq 2 ] || die "usage: intelligence adapter <enable|disable> <name>"
        assert_valid_target_name "$name"
        require_cli_project
        ensure_project_current "$IP_ROOT"
        bash "$CLI_DIR/internal/target-state.sh" "$action" "$name"
        if [ "$action" = "enable" ]; then
            exec bash "$CLI_DIR/commands/sync.sh"
        fi
        ;;
    remove)
        [ -n "$name" ] || die "usage: intelligence adapter remove <name> [--apply]"
        shift 2 || true
        adapter_remove "$@"
        ;;
    *)
        die "usage: intelligence adapter <list|create|enable|disable|remove> [name]"
        ;;
esac
