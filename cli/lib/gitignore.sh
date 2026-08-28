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
    while IFS= read -r target; do
        [ -n "$target" ] || continue
        if [ "$(is_target_enabled "$manifest" "$target")" = "1" ]; then
            ensure_target_gitignore "$root" "$manifest" "$target"
        fi
    done < <(target_names "$manifest")
}

# Publishing/build tools do not share Git's ignore policy. In particular,
# .vscodeignore and .npmignore become the packager's own filter, while Docker
# always builds from its independent context filter. Only amend files the
# project already has: their presence is the explicit signal that this root is
# packaged or sent as a build context.
publisher_ignore_file_names() {
    printf '%s\n' .vscodeignore .npmignore .dockerignore
}

publisher_ignore_add_line() {
    local file="$1" line="$2"
    if grep -Fqx -- "$line" "$file" 2>/dev/null; then
        return 0
    fi
    printf '%s\n' "$line" >> "$file"
    PUBLISH_IGNORE_FILE_CHANGED=1
}

publisher_ignore_add_path() {
    local file="$1" path="${2#./}"
    path="${path%/}"
    [ -n "$path" ] || return 0
    publisher_ignore_add_line "$file" "$path"
    publisher_ignore_add_line "$file" "$path/**"
}

ensure_manifest_publisher_ignores() {
    local root="$1" manifest="$2" rel file content_dir target output records kind value
    content_dir="$(manifest_intelligence_dir "$manifest")"
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        file="$root/$rel"
        [ -f "$file" ] || continue
        PUBLISH_IGNORE_FILE_CHANGED=0
        if ! grep -Fqx '# Intelligence development context and generated output' "$file" 2>/dev/null; then
            if [ -s "$file" ] && [ -n "$(tail -c 1 "$file" 2>/dev/null)" ]; then
                printf '\n' >> "$file"
            fi
            printf '%s\n' '# Intelligence development context and generated output' >> "$file"
            PUBLISH_IGNORE_FILE_CHANGED=1
        fi
        publisher_ignore_add_path "$file" '.intelligence'
        publisher_ignore_add_line "$file" 'intelligence.yaml'
        publisher_ignore_add_line "$file" 'intelligence.lock'
        publisher_ignore_add_path "$file" "$content_dir"
        while IFS= read -r target; do
            [ -n "$target" ] || continue
            [ "$(is_target_enabled "$manifest" "$target")" = "1" ] || continue
            output="$(get_target_output "$manifest" "$target")"
            [ -n "$output" ] || output="$(default_target_output "$target")"
            publisher_ignore_add_path "$file" "$output"
            records="$(adapter_records_for "$root" "$content_dir" "$target" "$output")" \
                || die "adapter '$target' has an invalid ownership contract"
            while IFS=$'\t' read -r kind value; do
                case "$kind" in
                    owned|managed|legacy) publisher_ignore_add_path "$file" "$value" ;;
                esac
            done <<< "$records"
        done < <(target_names "$manifest")
        if [ "$PUBLISH_IGNORE_FILE_CHANGED" -eq 1 ]; then
            echo "packaging exclusions updated: $rel"
        fi
    done < <(publisher_ignore_file_names)
}

managed_gitignore_patterns() {
    local root="$1" manifest="$2" content_dir target output records kind value
    content_dir="$(manifest_intelligence_dir "$manifest")"
    printf '%s\n' '.intelligence/' "$content_dir/_backup/"
    while IFS= read -r target; do
        [ -n "$target" ] || continue
        [ "$(is_target_enabled "$manifest" "$target")" = "1" ] || continue
        output="$(get_target_output "$manifest" "$target")"
        [ -n "$output" ] || output="$(default_target_output "$target")"
        records="$(adapter_records_for "$root" "$content_dir" "$target" "$output")" \
            || return 1
        while IFS=$'\t' read -r kind value; do
            case "$kind" in
                ignore) printf '%s\n' "$value" ;;
                include) printf '!%s\n' "$value" ;;
            esac
        done <<< "$records"
    done < <(target_names "$manifest")
}

# Git does not apply ignore rules retroactively to files already in its index.
# Name each affected path and print a command which only untracks it; the local
# file remains available as migration input.
report_tracked_managed_ignores() {
    local root="$1" manifest="$2" patterns tracked path quoted
    git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
    patterns="$(mktemp -t intelligence-gitignore-XXXXXX)"
    managed_gitignore_patterns "$root" "$manifest" > "$patterns" || {
        rm -f "$patterns"
        return 0
    }
    tracked="$(git -C "$root" ls-files -ci --exclude-from="$patterns" 2>/dev/null || true)"
    rm -f "$patterns"
    [ -n "$tracked" ] || return 0
    echo "  Tracked files still bypass these .gitignore rules. Untrack them without deleting local copies:"
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        quoted="${path//\"/\\\"}"
        echo "    git rm --cached -- \"$quoted\""
    done <<< "$tracked"
}
