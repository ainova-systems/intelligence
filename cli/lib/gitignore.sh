#!/bin/bash
# Generated-output policy derived from each adapter's ownership contract.

gitignore_add_line() {
    local root="$1" line="$2" file="$1/.gitignore"
    if [ -f "$file" ] && grep -Fqx -- "$line" "$file"; then
        return 0
    fi
    printf '%s\n' "$line" >> "$file"
}

ensure_gitignore_header() {
    local root="$1" file="$1/.gitignore"
    if [ ! -f "$file" ] || ! grep -Fqx '# Intelligence generated state and tool output' "$file"; then
        if [ -f "$file" ] && [ -s "$file" ] && [ -n "$(tail -c 1 "$file" 2>/dev/null)" ]; then
            printf '\n' >> "$file"
        fi
        printf '%s\n' '# Intelligence generated state and tool output' >> "$file"
    fi
}

ensure_base_gitignore() {
    local root="$1"
    ensure_gitignore_header "$root"
    gitignore_add_line "$root" '.intelligence/'
}

ensure_target_gitignore() {
    local root="$1" manifest="$2" target="$3" content_dir output kind value records
    ensure_gitignore_header "$root"
    content_dir="$(manifest_intelligence_dir "$manifest")"
    output="$(get_target_output "$manifest" "$target")"
    [ -n "$output" ] || output="$(default_target_output "$target")"
    records="$(adapter_records_for "$root" "$content_dir" "$target" "$output")" \
        || die "adapter '$target' has an invalid ownership contract"
    while IFS=$'\t' read -r kind value; do
        case "$kind" in
            ignore)  gitignore_add_line "$root" "$value" ;;
            include) gitignore_add_line "$root" "!$value" ;;
        esac
    done <<< "$records"
}

ensure_manifest_gitignore() {
    local root="$1" manifest="$2" target
    ensure_base_gitignore "$root"
    for target in agents claude cursor copilot codex pi opencode; do
        if [ "$(is_target_enabled "$manifest" "$target")" = "1" ]; then
            ensure_target_gitignore "$root" "$manifest" "$target"
        fi
    done
}
