#!/bin/bash
# intelligence-sync: OpenAI Codex CLI adapter
# Transforms source prompts to Codex format.
#
# Codex reads AGENTS.md natively for project context — the `agents` adapter
# inlines always-on rules into AGENTS.md, so this adapter only emits skills
# and subagent definitions.
#
# Skills: copy skill directories in full to .agents/skills/{name}/ (Codex
#   reads from $REPO_ROOT/.agents/skills exclusively per official docs)
# Agents: -> .codex/agents/{name}.toml (name, description, model,
#   model_reasoning_effort, sandbox_mode, developer_instructions)
#
# Every per-file loop batches its work into one awk process (see the batched
# helpers in lib/common.sh): process spawns dominate sync time on Windows.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

adapter_contract_codex() {
    local output="${1%/}"
    adapter_contract_version 1
    adapter_contract_requires agents
    adapter_contract_managed ".agents/skills"
    adapter_contract_owned "$output/agents"
    adapter_contract_ignore ".agents/skills/"
    adapter_contract_ignore "$output/agents/"
}

# Sync skills to Codex format (.agents/skills/{name}/SKILL.md)
sync_codex_skills() {
    local repo_root="$1"
    local config_file="$2"
    local output_dir="$3"

    sync_open_skill_dirs "$repo_root" "$config_file" "$output_dir"
}

# Sync agents to Codex format (.codex/agents/{name}.toml)
sync_codex_agents() {
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

    local count=0
    if [ "${#files[@]}" -gt 0 ]; then
        load_model_tiers "$config_file" "codex"

        local path tier access description name effort sandbox spec="" report="" LS=$'\x1e'
        while IFS=$'\x1f' read -r path tier access description; do
            [ -n "$path" ] || continue
            name="${path##*/}"; name="${name%.md}"
            resolve_model_var "$tier"
            case "$tier" in
                heavy)    effort="high" ;;
                standard) effort="medium" ;;
                light)    effort="low" ;;
                *)        effort="medium" ;;
            esac
            case "$access" in
                readonly) sandbox="read-only" ;;
                *)        sandbox="workspace-write" ;;
            esac
            local name_escaped description_escaped
            toml_escape_var "$name";        name_escaped="$IS_TOML_ESCAPED"
            toml_escape_var "$description"; description_escaped="$IS_TOML_ESCAPED"

            local header
            header="${LS}name = \"$name_escaped\""
            header+="${LS}description = \"$description_escaped\""
            header+="${LS}model = \"$IS_MODEL\""
            header+="${LS}model_reasoning_effort = \"$effort\""
            header+="${LS}sandbox_mode = \"$sandbox\""
            header+="${LS}"
            header+="${LS}developer_instructions = \"\"\""

            spec+="$path"$'\x1f'"$output_dir/$name.toml"$'\x1f'"fence"$'\x1f'"1"$'\x1f'"toml"$'\x1f'"$header"$'\x1f'"${LS}\"\"\""$'\n'
            report+="  agent: $name.toml"$'\n'
            count=$((count + 1))
        done < <(frontmatter_index "tier,access,description" "${files[@]}")

        emit_wrapped_bodies "$spec"
        printf '%s' "$report"
    fi

    echo "  -> Agents: $count"
}

# Main entry point for Codex adapter
sync_to_codex() {
    local repo_root="$1"
    local config_file="$2"
    local output_dir="$3"

    echo "=== OpenAI Codex ==="

    # Skills -> .agents/skills/ (Codex reads from this fixed path).
    # `sync_open_skill_dirs` owns clean + populate of this shared dir.
    local skills_dir="$repo_root/.agents/skills"
    sync_codex_skills "$repo_root" "$config_file" "$skills_dir"

    # Agents -> .codex/agents/
    local agents_dir="$output_dir/agents"
    rm -rf "$agents_dir"
    mkdir -p "$agents_dir"
    sync_codex_agents "$repo_root" "$config_file" "$agents_dir"
}
