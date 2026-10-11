#!/bin/bash
# intelligence-sync: Claude Code adapter
# Transforms source prompts to .claude/ format
#
# Rules: copy as-is (paths: frontmatter preserved)
# Skills: copy skill directories in full (SKILL.md + bundled resources),
#   effort -> Claude's effort level
# Agents: tier -> model, effort -> effort, access -> tools/disallowedTools
#
# Every per-file loop batches its work into one awk process (see the batched
# helpers in lib/common.sh): process spawns dominate sync time on Windows.

# The engine and the CLI load the shared library before any adapter. Only a
# standalone source of this file loads it here: that costs a dirname process.
declare -F finalize_output_file >/dev/null 2>&1 || source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

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

    local name
    # Every source reaches this adapter through the source catalog (decision
    # 0021): rendered names, overrides and local artifacts are settled there.
    output_rel_var "$repo_root" "$output_dir"
    source_artifacts_var "$repo_root" "$config_file" rules claude "$IS_OUTPUT_REL/rules/{}.md"
    [ "${#IS_SOURCE_FILES[@]}" -gt 0 ] || return 0
    finalize_copy_named "$output_dir/rules" "$IS_SOURCE_NAME_MAP" "${IS_SOURCE_FILES[@]}"
    for name in "${IS_SOURCE_NAMES[@]}"; do
        echo "  rule: $name.md"
    done
}

# Sync skills to Claude format (copy skill directories in full)
sync_claude_skills() {
    local repo_root="$1"
    local config_file="$2"
    local output_dir="$3"

    local i name
    local -a skill_dirs=()
    # The catalog's skills are the ones the inventory renders, symlinked ones
    # included (decision 0017).
    output_rel_var "$repo_root" "$output_dir"
    source_artifacts_var "$repo_root" "$config_file" skills claude "$IS_OUTPUT_REL/skills/{}"
    [ "${#IS_SOURCE_FILES[@]}" -gt 0 ] || return 0
    for ((i = 0; i < ${#IS_SOURCE_FILES[@]}; i++)); do
        skill_dirs+=("${IS_SOURCE_FILES[i]%/SKILL.md}/")
    done
    copy_skill_bundle_dirs_named claude "$output_dir/skills" "$IS_SOURCE_NAME_MAP" "${skill_dirs[@]}"
    for name in "${IS_SOURCE_NAMES[@]}"; do
        echo "  skill: $name"
    done
}

# Sync all agents to Claude format: one frontmatter pass resolves
# tier/effort/access for every file, one transform pass writes every output.
sync_claude_agents() {
    local repo_root="$1"
    local config_file="$2"
    local output_dir="$3"

    local i
    local -a files=() names=()
    output_rel_var "$repo_root" "$output_dir"
    source_artifacts_var "$repo_root" "$config_file" agents claude "$IS_OUTPUT_REL/agents/{}.md"
    [ "${#IS_SOURCE_FILES[@]}" -gt 0 ] || return 0
    files=("${IS_SOURCE_FILES[@]}")
    names=("${IS_SOURCE_NAMES[@]}")
    local name_map="$IS_SOURCE_NAME_MAP"

    load_model_tiers "$config_file" "claude"

    local path tier access effort spec="" report=""
    i=0
    while IFS=$'\x1f' read -r path tier access effort; do
        resolve_model_var "$tier"
        map_effort_var claude "$effort"
        map_access_to_claude_tools_var "$access"
        map_access_to_claude_disallowed_var "$access"
        spec+="$path"$'\x1f'"$IS_MODEL"$'\x1f'"$IS_CLAUDE_TOOLS"$'\x1f'"$IS_CLAUDE_DISALLOWED"$'\x1f'"$IS_EFFORT"$'\n'
        report+="  agent: ${names[i]}.md (tier=$tier -> model=$IS_MODEL, access=$access)"$'\n'
        i=$((i + 1))
    done < <(frontmatter_index "tier,access,effort" "${files[@]}")

    # The transform used to run per file with the values injected via -v;
    # the batched form carries them per file through the environment (awk -v
    # would reprocess backslash escapes). The first frontmatter `effort:` line
    # becomes Claude's level in place, or goes when there is none; a later
    # one goes too, since frontmatter_index read only the first.
    is_fin_awk_vars
    IS_NAME_MAP="$name_map" IS_MAP_SPEC="$spec" awk "${IS_FIN_V[@]}" -v dst="$output_dir/agents" "$IS_AWK_LIB"'
        BEGIN {
            US = sprintf("%c", 31)
            n = split(ENVIRON["IS_MAP_SPEC"], recs, "\n")
            for (i = 1; i <= n; i++) {
                if (recs[i] == "") continue
                split(recs[i], f, US)
                MODEL[f[1]] = f[2]; TOOLS[f[1]] = f[3]; EXTRA[f[1]] = f[4]; EFFORT[f[1]] = f[5]
            }
        }
        FNR == 1 {
            if (out != "") close(out)
            out = dst "/" art_file(FILENAME, ".md")
            count = 0
            fm = 0
            effort_seen = 0
            tgt_reset()
        }
        /^tier:/  { next }
        /^access:/ { next }
        { sub(/\r$/, "") }
        FNR == 1 && $0 == "---" { fm = 1 }
        /^---$/ { count++ }
        fm && count == 1 && !/^---$/ && tgt_drop($0) { next }
        fm && count == 1 && substr($0, 1, 7) == "effort:" {
            if (!effort_seen++ && EFFORT[FILENAME] != "") print fin_line("effort: " EFFORT[FILENAME]) > out
            next
        }
        count == 2 && /^---$/ {
            if (TOOLS[FILENAME] != "") print fin_line("tools: " TOOLS[FILENAME]) > out
            if (EXTRA[FILENAME] != "") print fin_line("disallowedTools: " EXTRA[FILENAME]) > out
            print fin_line("model: " MODEL[FILENAME]) > out
        }
        { print fin_line($0) > out }
    ' "${files[@]}"
    # awk never reads a record from an empty source; the old per-file shell
    # redirect still created an empty output for it.
    for ((i = 0; i < ${#files[@]}; i++)); do
        [ -s "${files[i]}" ] || : > "$output_dir/agents/${names[i]}.md"
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
        find "$output_dir/skills" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -exec rm -rf {} +
    fi
    mkdir -p "$output_dir/rules" "$output_dir/skills" "$output_dir/agents"

    sync_claude_rules "$repo_root" "$config_file" "$output_dir"
    sync_claude_skills "$repo_root" "$config_file" "$output_dir"
    sync_claude_agents "$repo_root" "$config_file" "$output_dir"

    count_matching_files "$output_dir/rules" "*.md" \
        "$output_dir/skills" "SKILL.md" "$output_dir/agents" "*.md"
    echo "  -> Rules: ${IS_FILE_COUNTS[0]}, Skills: ${IS_FILE_COUNTS[1]}, Agents: ${IS_FILE_COUNTS[2]}"
}
