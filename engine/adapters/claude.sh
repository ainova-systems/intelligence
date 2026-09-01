#!/bin/bash
# intelligence-sync: Claude Code adapter
# Transforms source prompts to .claude/ format
#
# Rules: copy as-is (paths: frontmatter preserved)
# Skills: copy skill directories in full (SKILL.md + bundled resources)
# Agents: tier -> model, access -> tools/disallowedTools
#
# Every per-file loop batches its work into one awk process (see the batched
# helpers in lib/common.sh): process spawns dominate sync time on Windows.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

adapter_contract_claude() {
    local output="${1%/}"
    adapter_contract_version 1
    adapter_contract_owned "$output/rules"
    adapter_contract_owned "$output/agents"
    adapter_contract_owned "$output/skills"
    adapter_contract_legacy "CLAUDE.md"
    adapter_contract_legacy "$output/commands"
    adapter_contract_preserve "$output/settings.json"
    adapter_contract_preserve "$output/settings.local.json"
    adapter_contract_ignore "CLAUDE.md"
    adapter_contract_ignore "$output/*"
    adapter_contract_include "$output/settings.json"
}

# Sync rules to Claude format (copy as-is, normalize LF)
sync_claude_rules() {
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
    finalize_copy_files "$output_dir/rules" "${files[@]}"
    for f in "${files[@]}"; do
        echo "  rule: ${f##*/}"
    done
}

# Sync skills to Claude format (copy skill directories in full)
sync_claude_skills() {
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

# Sync all agents to Claude format: one frontmatter pass resolves
# tier/access for every file, one transform pass writes every output.
sync_claude_agents() {
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

    load_model_tiers "$config_file" "claude"

    local path tier access spec="" report=""
    while IFS=$'\x1f' read -r path tier access; do
        [ -n "$path" ] || continue
        resolve_model_var "$tier"
        map_access_to_claude_tools_var "$access"
        map_access_to_claude_disallowed_var "$access"
        spec+="$path"$'\x1f'"$IS_MODEL"$'\x1f'"$IS_CLAUDE_TOOLS"$'\x1f'"$IS_CLAUDE_DISALLOWED"$'\n'
        report+="  agent: ${path##*/} (tier=$tier -> model=$IS_MODEL, access=$access)"$'\n'
    done < <(frontmatter_index "tier,access" "${files[@]}")

    # The transform used to run per file with the values injected via -v;
    # the batched form carries them per file through the environment (awk -v
    # would reprocess backslash escapes).
    is_fin_awk_vars
    IS_MAP_SPEC="$spec" awk "${IS_FIN_V[@]}" -v dst="$output_dir/agents" "$IS_AWK_LIB"'
        BEGIN {
            US = sprintf("%c", 31)
            n = split(ENVIRON["IS_MAP_SPEC"], recs, "\n")
            for (i = 1; i <= n; i++) {
                if (recs[i] == "") continue
                split(recs[i], f, US)
                MODEL[f[1]] = f[2]; TOOLS[f[1]] = f[3]; EXTRA[f[1]] = f[4]
            }
        }
        FNR == 1 {
            if (out != "") close(out)
            out = dst "/" base_name(FILENAME)
            count = 0
        }
        /^tier:/  { next }
        /^access:/ { next }
        { sub(/\r$/, "") }
        /^---$/ { count++ }
        count == 2 && /^---$/ {
            if (TOOLS[FILENAME] != "") print fin_line("tools: " TOOLS[FILENAME]) > out
            if (EXTRA[FILENAME] != "") print fin_line("disallowedTools: " EXTRA[FILENAME]) > out
            print fin_line("model: " MODEL[FILENAME]) > out
        }
        { print fin_line($0) > out }
    ' "${files[@]}"
    # awk never reads a record from an empty source; the old per-file shell
    # redirect still created an empty output for it.
    for f in "${files[@]}"; do
        [ -s "$f" ] || : > "$output_dir/agents/${f##*/}"
    done
    printf '%s' "$report"
}

# Main entry point for Claude adapter
sync_to_claude() {
    local repo_root="$1"
    local config_file="$2"
    local output_dir="$3"

    echo "=== Claude Code ==="

    # Clean generated content only — preserve any project-level files
    # the user manages directly (settings.json, settings.local.json,
    # commands/, statusline.sh, etc.).
    rm -rf "$output_dir/rules" "$output_dir/agents"
    if [ -d "$output_dir/skills" ]; then
        find "$output_dir/skills" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} +
    fi
    mkdir -p "$output_dir/rules" "$output_dir/skills" "$output_dir/agents"

    sync_claude_rules "$repo_root" "$config_file" "$output_dir"
    sync_claude_skills "$repo_root" "$config_file" "$output_dir"
    sync_claude_agents "$repo_root" "$config_file" "$output_dir"

    local rules_count skills_count agents_count
    rules_count=$(find "$output_dir/rules" -name "*.md" 2>/dev/null | wc -l)
    skills_count=$(find "$output_dir/skills" -name "SKILL.md" 2>/dev/null | wc -l)
    agents_count=$(find "$output_dir/agents" -name "*.md" 2>/dev/null | wc -l)
    echo "  -> Rules: $rules_count, Skills: $skills_count, Agents: $agents_count"
}
