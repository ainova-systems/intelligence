#!/bin/bash
# intelligence adapter <list|create|enable|disable|remove> [name]
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"
source "$CLI_DIR/lib/usage.sh"

action="${1:-}"
name="${2:-}"

# adapter_list_output <manifest-or-empty> <target> — the OUTPUT column: the
# manifest's output, the default an entry without one renders at, or, for a
# target the manifest lacks, the output `adapter enable` would write.
adapter_list_output() {
    local configured=""
    if [ -n "$1" ] && target_exists "$1" "$2"; then
        configured="$(get_target_output "$1" "$2")"
        if [ -n "$configured" ]; then printf '%s' "$configured"; else default_target_output "$2"; fi
    else
        init_target_output "$2"
    fi
}

adapter_list() {
    detect_project
    local manifest="" content_dir="" seen=" " file item enabled output
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
            enabled="disabled"
            [ "$(is_target_enabled "$manifest" "$item")" = "1" ] && enabled="enabled"
            output="$(adapter_list_output "$manifest" "$item")"
            printf '%-16s %-10s %-10s %s\n' "$item" "project" "$enabled" "$output"
        done
    fi
    for file in "$IS_ENGINE_DIR/adapters"/*.sh; do
        [ -f "$file" ] || continue
        item="$(basename "$file" .sh)"
        [ "$item" = "_template" ] && continue
        case "$seen" in *" $item "*) continue ;; esac
        enabled="disabled"
        if [ -n "$manifest" ]; then
            [ "$(is_target_enabled "$manifest" "$item")" = "1" ] && enabled="enabled"
        fi
        output="$(adapter_list_output "$manifest" "$item")"
        printf '%-16s %-10s %-10s %s\n' "$item" "built-in" "$enabled" "$output"
    done
}

adapter_create() {
    [ -n "$name" ] && [ $# -eq 0 ] || cli_usage_die adapter create
    assert_valid_target_name "$name"
    require_cli_project
    project_as_committed "$IP_ROOT"
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
    [ -n "$name" ] || cli_usage_die adapter remove
    assert_valid_target_name "$name"
    require_cli_project
    project_as_committed "$IP_ROOT"
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
    # A render sources project adapters: never remove one under it.
    project_lock_hold "$IP_ROOT"
    rm -f "$file"
    echo "removed: $content_dir/adapters/$name.sh"
    echo "  generated output was kept"
}

case "$action" in
    list)
        [ $# -eq 1 ] || cli_usage_die adapter list
        adapter_list
        ;;
    create)
        shift 2 || true
        adapter_create "$@"
        ;;
    enable|disable)
        [ -n "$name" ] && [ $# -eq 2 ] || cli_usage_die adapter "$action"
        assert_valid_target_name "$name"
        require_cli_project
        # Held through the final render: target-state and sync join it.
        project_lock_hold "$IP_ROOT"
        project_as_committed "$IP_ROOT"
        if [ "$action" = "enable" ]; then
            state_stage="$(mktemp -d -t intelligence-adapter-state-XXXXXX)"
            cp "$IP_ROOT/intelligence.yaml" "$state_stage/intelligence.yaml"
            gitignore_existed=0
            if [ -f "$IP_ROOT/.gitignore" ]; then
                gitignore_existed=1
                cp "$IP_ROOT/.gitignore" "$state_stage/gitignore"
            fi
            while IFS= read -r policy_file; do
                [ -f "$IP_ROOT/$policy_file" ] || continue
                cp "$IP_ROOT/$policy_file" "$state_stage/$policy_file"
            done < <(publisher_ignore_file_names)
            enable_rc=0
            bash "$CLI_DIR/internal/target-state.sh" "$action" "$name" || enable_rc=$?
            if [ "$enable_rc" -eq 0 ]; then
                bash "$CLI_DIR/commands/sync.sh" || enable_rc=$?
            fi
            if [ "$enable_rc" -ne 0 ]; then
                cp "$state_stage/intelligence.yaml" "$IP_ROOT/intelligence.yaml"
                if [ "$gitignore_existed" -eq 1 ]; then
                    cp "$state_stage/gitignore" "$IP_ROOT/.gitignore"
                else
                    rm -f "$IP_ROOT/.gitignore"
                fi
                while IFS= read -r policy_file; do
                    [ -f "$state_stage/$policy_file" ] || continue
                    cp "$state_stage/$policy_file" "$IP_ROOT/$policy_file"
                done < <(publisher_ignore_file_names)
                echo "ERROR: adapter enable failed; manifest and ignore policies were restored." >&2
            else
                report_tracked_managed_ignores "$IP_ROOT" "$IP_ROOT/intelligence.yaml"
            fi
            rm -rf "$state_stage"
            exit "$enable_rc"
        fi
        bash "$CLI_DIR/internal/target-state.sh" "$action" "$name"
        ;;
    remove)
        [ -n "$name" ] || cli_usage_die adapter remove
        shift 2 || true
        adapter_remove "$@"
        ;;
    *)
        case "$name" in
            list)
                die "adapter action comes first - run: intelligence adapter list"
                ;;
            create|enable|disable|remove)
                die "adapter action comes first - run: intelligence adapter $name $action"
                ;;
        esac
        cli_usage_die adapter
        ;;
esac
