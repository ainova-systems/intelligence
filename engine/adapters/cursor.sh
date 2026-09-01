#!/bin/bash
# intelligence-sync: Cursor adapter
# Transforms source prompts to .cursor/ format
#
# Rules:
#   - Path-scoped (with `paths:`)  -> .cursor/rules/<name>.mdc with `globs:`
#   - Always-on (no `paths:`)      -> SKIPPED here. Cursor reads AGENTS.md
#     natively for project-level context, and the `agents` adapter inlines
#     always-on rule content into AGENTS.md. Generating .mdc copies of the
#     same rules would cause double-loading and burn the context window.
# Skills: copy skill directories in full (SKILL.md + bundled resources)
# Agents: strip tier/access/tools/disallowedTools, add model + readonly:true
#
# Every per-file loop batches its work into one awk process (see the batched
# helpers in lib/common.sh): process spawns dominate sync time on Windows.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

adapter_contract_cursor() {
    local output="${1%/}"
    adapter_contract_version 1
    adapter_contract_requires agents
    adapter_contract_owned "$output/rules"
    adapter_contract_owned "$output/agents"
    adapter_contract_owned "$output/skills"
    adapter_contract_legacy ".cursorrules"
    adapter_contract_legacy "$output/commands"
    adapter_contract_preserve "$output/settings.json"
    adapter_contract_ignore ".cursorrules"
    adapter_contract_ignore "$output/*"
    adapter_contract_include "$output/settings.json"
}

# Sync rules to Cursor format (.md -> .mdc, paths -> globs)
sync_cursor_rules() {
    local repo_root="$1"
    local config_file="$2"
    local output_dir="$3"

    local src f
    local -a files=()
    load_yaml_list "$config_file" "rules"
    local list="$IS_YAML_LIST"
    while IFS= read -r src; do
        [ -z "$src" ] && continue
        local dir="$repo_root/$src"
        [ -d "$dir" ] || continue
        for f in "$dir"/*.md; do
            [ -f "$f" ] || continue
            files+=("$f")
        done
    done <<< "$list"
    [ "${#files[@]}" -gt 0 ] || return 0

    # Skip always-on rules: AGENTS.md (canonical) carries them.
    local path hp base
    local -a scoped=()
    while IFS=$'\x1f' read -r path hp; do
        [ -n "$path" ] || continue
        [ "$hp" -eq 0 ] && continue
        scoped+=("$path")
    done < <(frontmatter_index "paths#" "${files[@]}")
    [ "${#scoped[@]}" -gt 0 ] || return 0

    # Path-scoped rule -> Auto Attached (paths -> globs)
    is_fin_awk_vars
    awk "${IS_FIN_V[@]}" -v dst="$output_dir/rules" "$IS_AWK_LIB"'
        FNR == 1 {
            if (out != "") close(out)
            nm = base_name(FILENAME)
            sub(/\.md$/, ".mdc", nm)
            out = dst "/" nm
        }
        {
            sub(/\r$/, "")
            sub(/^paths:/, "globs:")
        }
        FNR == 1 { print fin_line($0) > out; print fin_line("alwaysApply: false") > out; next }
        { print fin_line($0) > out }
    ' "${scoped[@]}"
    for f in "${scoped[@]}"; do
        base="${f##*/}"; base="${base%.md}"
        echo "  rule: $base.mdc (scoped)"
    done
}

# Sync skills to Cursor format (copy as-is)
sync_cursor_skills() {
    local repo_root="$1"
    local config_file="$2"
    local output_dir="$3"

    local src d skill_name
    local -a skill_dirs=()
    load_yaml_list "$config_file" "skills"
    local list="$IS_YAML_LIST"
    while IFS= read -r src; do
        [ -z "$src" ] && continue
        local dir="$repo_root/$src"
        [ -d "$dir" ] || continue
        for d in "$dir"/*/; do
            [ -d "$d" ] || continue
            [ -f "$d/SKILL.md" ] || continue
            skill_dirs+=("$d")
        done
    done <<< "$list"
    [ "${#skill_dirs[@]}" -gt 0 ] || return 0
    copy_skill_bundle_dirs "$output_dir/skills" "${skill_dirs[@]}"
    for d in "${skill_dirs[@]}"; do
        skill_name="${d%/}"
        echo "  skill: ${skill_name##*/}"
    done
}

# Sync agents to Cursor format
sync_cursor_agents() {
    local repo_root="$1"
    local config_file="$2"
    local output_dir="$3"

    local src f
    local -a files=()
    load_yaml_list "$config_file" "agents"
    local list="$IS_YAML_LIST"
    while IFS= read -r src; do
        [ -z "$src" ] && continue
        local dir="$repo_root/$src"
        [ -d "$dir" ] || continue
        for f in "$dir"/*.md; do
            [ -f "$f" ] || continue
            files+=("$f")
        done
    done <<< "$list"
    [ "${#files[@]}" -gt 0 ] || return 0

    load_model_tiers "$config_file" "cursor"

    local path tier access spec="" report="" cursor_readonly
    while IFS=$'\x1f' read -r path tier access; do
        [ -n "$path" ] || continue
        resolve_model_var "$tier"
        cursor_readonly=""
        [ "$access" = "readonly" ] && cursor_readonly="readonly: true"
        spec+="$path"$'\x1f'"$IS_MODEL"$'\x1f'"$cursor_readonly"$'\n'
        report+="  agent: ${path##*/} (tier=$tier -> cursor)"$'\n'
    done < <(frontmatter_index "tier,access" "${files[@]}")

    # Always emit model: line (even when value matches Cursor's default)
    # so config is explicit and grep-able.
    is_fin_awk_vars
    IS_MAP_SPEC="$spec" awk "${IS_FIN_V[@]}" -v dst="$output_dir/agents" "$IS_AWK_LIB"'
        BEGIN {
            US = sprintf("%c", 31)
            n = split(ENVIRON["IS_MAP_SPEC"], recs, "\n")
            for (i = 1; i <= n; i++) {
                if (recs[i] == "") continue
                split(recs[i], f, US)
                MODEL[f[1]] = f[2]; RO[f[1]] = f[3]
            }
        }
        FNR == 1 {
            if (out != "") close(out)
            out = dst "/" base_name(FILENAME)
            count = 0
        }
        /^tier:/  { next }
        /^access:/ { next }
        /^tools:/ { next }
        /^disallowedTools:/ { next }
        { sub(/\r$/, "") }
        /^---$/ { count++ }
        count == 2 && /^---$/ {
            print fin_line("model: " MODEL[FILENAME]) > out
            if (RO[FILENAME] != "") print fin_line(RO[FILENAME]) > out
        }
        { print fin_line($0) > out }
    ' "${files[@]}"
    for f in "${files[@]}"; do
        [ -s "$f" ] || : > "$output_dir/agents/${f##*/}"
    done
    printf '%s' "$report"
}

# Main entry point for Cursor adapter
sync_to_cursor() {
    local repo_root="$1"
    local config_file="$2"
    local output_dir="$3"

    echo "=== Cursor ==="

    rm -rf "$output_dir/rules" "$output_dir/agents" "$output_dir/skills"
    mkdir -p "$output_dir/rules" "$output_dir/skills" "$output_dir/agents"

    sync_cursor_rules "$repo_root" "$config_file" "$output_dir"
    sync_cursor_skills "$repo_root" "$config_file" "$output_dir"
    sync_cursor_agents "$repo_root" "$config_file" "$output_dir"

    local rules_count skills_count agents_count
    rules_count=$(find "$output_dir/rules" -name "*.mdc" 2>/dev/null | wc -l)
    skills_count=$(find "$output_dir/skills" -name "SKILL.md" 2>/dev/null | wc -l)
    agents_count=$(find "$output_dir/agents" -name "*.md" 2>/dev/null | wc -l)
    echo "  -> Rules: $rules_count (.mdc), Skills: $skills_count, Agents: $agents_count"
}
