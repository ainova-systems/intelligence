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
# Cursor has no per-agent or per-skill effort field (its effort is part of a
# model ID), so `effort:` is stripped from both.
#
# Every per-file loop batches its work into one awk process (see the batched
# helpers in lib/common.sh): process spawns dominate sync time on Windows.

# The engine and the CLI load the shared library before any adapter. Only a
# standalone source of this file loads it here: that costs a dirname process.
declare -F finalize_output_file >/dev/null 2>&1 || source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

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

    local i
    local -a scoped=() scoped_names=()
    output_rel_var "$repo_root" "$output_dir"
    source_artifacts_var "$repo_root" "$config_file" rules cursor "$IS_OUTPUT_REL/rules/{}.mdc"
    # Skip always-on rules: AGENTS.md (canonical) carries them.
    for ((i = 0; i < ${#IS_SOURCE_FILES[@]}; i++)); do
        [ "${IS_SOURCE_SCOPED[i]}" = 1 ] || continue
        scoped+=("${IS_SOURCE_FILES[i]}")
        scoped_names+=("${IS_SOURCE_NAMES[i]}")
    done
    [ "${#scoped[@]}" -gt 0 ] || return 0

    # Path-scoped rule -> Auto Attached (paths -> globs). The rewrite is
    # anchored inside the frontmatter block: a body line may legitimately start
    # with `paths:` (a rule documenting rule syntax does exactly that), and
    # rewriting it would corrupt the text it teaches.
    is_fin_awk_vars
    IS_NAME_MAP="$IS_SOURCE_NAME_MAP" awk "${IS_FIN_V[@]}" -v dst="$output_dir/rules" "$IS_AWK_LIB"'
        FNR == 1 {
            if (out != "") close(out)
            out = dst "/" art_name(FILENAME) ".mdc"
            fm = 0
        }
        { sub(/\r$/, "") }
        FNR == 1 {
            if ($0 == "---") fm = 1
            print fin_line($0) > out
            print fin_line("alwaysApply: false") > out
            next
        }
        fm == 1 && $0 == "---" { fm = 2; print fin_line($0) > out; next }
        fm == 1 { sub(/^paths:/, "globs:") }
        { print fin_line($0) > out }
    ' "${scoped[@]}"
    for ((i = 0; i < ${#scoped_names[@]}; i++)); do
        echo "  rule: ${scoped_names[i]}.mdc (scoped)"
    done
}

# Sync skills to Cursor format (copy as-is)
sync_cursor_skills() {
    local repo_root="$1"
    local config_file="$2"
    local output_dir="$3"

    local i name
    local -a skill_dirs=()
    # The catalog's skills are the ones the inventory renders, symlinked ones
    # included (decision 0017).
    output_rel_var "$repo_root" "$output_dir"
    source_artifacts_var "$repo_root" "$config_file" skills cursor "$IS_OUTPUT_REL/skills/{}"
    [ "${#IS_SOURCE_FILES[@]}" -gt 0 ] || return 0
    for ((i = 0; i < ${#IS_SOURCE_FILES[@]}; i++)); do
        skill_dirs+=("${IS_SOURCE_FILES[i]%/SKILL.md}/")
    done
    copy_skill_bundle_dirs_named cursor "$output_dir/skills" "$IS_SOURCE_NAME_MAP" "${skill_dirs[@]}"
    for name in "${IS_SOURCE_NAMES[@]}"; do
        echo "  skill: $name"
    done
}

# Sync agents to Cursor format
sync_cursor_agents() {
    local repo_root="$1"
    local config_file="$2"
    local output_dir="$3"

    local i
    local -a files=() names=()
    output_rel_var "$repo_root" "$output_dir"
    source_artifacts_var "$repo_root" "$config_file" agents cursor "$IS_OUTPUT_REL/agents/{}.md"
    [ "${#IS_SOURCE_FILES[@]}" -gt 0 ] || return 0
    files=("${IS_SOURCE_FILES[@]}")
    names=("${IS_SOURCE_NAMES[@]}")
    local name_map="$IS_SOURCE_NAME_MAP"

    load_model_tiers "$config_file" "cursor"

    local path tier access spec="" report="" cursor_readonly
    i=0
    while IFS=$'\x1f' read -r path tier access; do
        resolve_model_var "$tier"
        cursor_readonly=""
        [ "$access" = "readonly" ] && cursor_readonly="readonly: true"
        spec+="$path"$'\x1f'"$IS_MODEL"$'\x1f'"$cursor_readonly"$'\n'
        report+="  agent: ${names[i]}.md (tier=$tier -> cursor)"$'\n'
        i=$((i + 1))
    done < <(frontmatter_index "tier,access" "${files[@]}")

    # Always emit model: line (even when value matches Cursor's default)
    # so config is explicit and grep-able.
    is_fin_awk_vars
    IS_NAME_MAP="$name_map" IS_MAP_SPEC="$spec" awk "${IS_FIN_V[@]}" -v dst="$output_dir/agents" "$IS_AWK_LIB"'
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
            out = dst "/" art_file(FILENAME, ".md")
            count = 0
            fm = 0
        }
        /^tier:/  { next }
        /^access:/ { next }
        /^tools:/ { next }
        /^disallowedTools:/ { next }
        { sub(/\r$/, "") }
        FNR == 1 && $0 == "---" { fm = 1 }
        /^---$/ { count++ }
        fm && count == 1 && substr($0, 1, 7) == "effort:" { next }
        count == 2 && /^---$/ {
            print fin_line("model: " MODEL[FILENAME]) > out
            if (RO[FILENAME] != "") print fin_line(RO[FILENAME]) > out
        }
        { print fin_line($0) > out }
    ' "${files[@]}"
    for ((i = 0; i < ${#files[@]}; i++)); do
        [ -s "${files[i]}" ] || : > "$output_dir/agents/${names[i]}.md"
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

    count_matching_files "$output_dir/rules" "*.mdc" \
        "$output_dir/skills" "SKILL.md" "$output_dir/agents" "*.md"
    echo "  -> Rules: ${IS_FILE_COUNTS[0]} (.mdc), Skills: ${IS_FILE_COUNTS[1]}, Agents: ${IS_FILE_COUNTS[2]}"
}
