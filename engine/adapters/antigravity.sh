#!/bin/bash
# intelligence-sync: Google Antigravity adapter
# Transforms source prompts to Antigravity's native resource model.
#
# Rules:
#   - Always-on (no `paths:`) -> SKIPPED here. Antigravity reads AGENTS.md
#     natively at the workspace root, and the `agents` adapter inlines
#     always-on rule content into it. Emitting copies under .agents/rules/
#     would double-load the same text.
#   - Path-scoped (with `paths:`) -> .agents/rules/<name>.md carrying
#     `trigger: glob` and `globs:` (activation modes: always_on, manual,
#     model_decision, glob). Antigravity documents a 12,000-character limit
#     per rule file, so scoped rules stay short.
#   - GEMINI.md outranks AGENTS.md in Antigravity's rule precedence, so the
#     contract quarantines it at onboarding: left in place it would silently
#     override every synced rule.
# Skills:
#   - Copied to .agents/skills/ (Agent Skills open standard, shared with
#     Codex, Pi and opencode). Antigravity reads that fixed workspace path,
#     never the configured output, and selects skills by description.
# Agents:
#   - Converted to .agents/agents/<name>.md. `name` and `description` are
#     required; `model` accepts only inherit|flash|pro; `subagent: true` with
#     `mainAgent: false` matches how every other adapter exposes Intelligence
#     agents — as delegates, not as chat personas. A readonly agent gets an
#     explicit `tools:` allowlist.
#
# Every per-file loop batches its work into one awk process (see the batched
# helpers in lib/common.sh): process spawns dominate sync time on Windows.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

adapter_contract_antigravity() {
    local output="${1%/}"
    adapter_contract_version 1
    adapter_contract_requires agents
    adapter_contract_owned "$output/rules"
    adapter_contract_owned "$output/agents"
    adapter_contract_managed ".agents/skills"
    adapter_contract_legacy "GEMINI.md"
    adapter_contract_ignore "GEMINI.md"
    adapter_contract_ignore "$output/rules/"
    adapter_contract_ignore "$output/agents/"
    adapter_contract_ignore ".agents/skills/"
}

sync_antigravity_rules() {
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

    # Skip always-on rules: AGENTS.md (canonical) carries them.
    local path hp base
    local -a scoped=()
    if [ "${#files[@]}" -gt 0 ]; then
        while IFS=$'\x1f' read -r path hp; do
            [ -n "$path" ] || continue
            [ "$hp" -eq 0 ] && continue
            scoped+=("$path")
        done < <(frontmatter_index "paths#" "${files[@]}")
    fi
    if [ "${#scoped[@]}" -eq 0 ]; then
        echo "  -> Rules: 0 scoped (AGENTS.md carries always-on)"
        return 0
    fi

    # Path-scoped rule -> Glob activation (paths -> globs)
    is_fin_awk_vars
    awk "${IS_FIN_V[@]}" -v dst="$output_dir/rules" "$IS_AWK_LIB"'
        FNR == 1 {
            if (out != "") close(out)
            out = dst "/" base_name(FILENAME)
        }
        {
            sub(/\r$/, "")
            sub(/^paths:/, "globs:")
        }
        FNR == 1 {
            print fin_line($0) > out
            print fin_line("trigger: glob") > out
            next
        }
        { print fin_line($0) > out }
        END { if (out != "") close(out) }
    ' "${scoped[@]}"

    for f in "${scoped[@]}"; do
        base="${f##*/}"
        echo "  rule: $base (scoped)"
    done
    echo "  -> Rules: ${#scoped[@]} scoped"
}

sync_antigravity_agents() {
    local repo_root="$1"
    local config_file="$2"
    local agents_dir="$3"

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
        load_model_tiers "$config_file" "antigravity"

        local path tier access description name spec="" report="" LS=$'\x1e'
        while IFS=$'\x1f' read -r path tier access description; do
            [ -n "$path" ] || continue
            name="${path##*/}"; name="${name%.md}"
            resolve_model_var "$tier"

            local header
            yaml_dq_escape_var "$name"
            header="${LS}---"
            header+="${LS}name: \"$IS_YAML_ESCAPED\""
            yaml_dq_escape_var "$description"
            header+="${LS}description: \"$IS_YAML_ESCAPED\""
            if [ -n "$IS_MODEL" ]; then
                yaml_dq_escape_var "$IS_MODEL"
                header+="${LS}model: \"$IS_YAML_ESCAPED\""
            fi
            header+="${LS}subagent: true"
            header+="${LS}mainAgent: false"
            # A readonly agent gets an explicit allowlist. It holds only tool
            # identifiers the official docs name, because an unknown entry in
            # an allowlist silently removes a capability rather than failing:
            # a directory-listing tool is left out until one is documented.
            # An unrestricted agent declares no list and inherits the main
            # agent's tools, which is Antigravity's default.
            if [ "$access" = "readonly" ]; then
                header+="${LS}tools:"
                header+="${LS}  - view_file"
                header+="${LS}  - grep_search"
                header+="${LS}  - search_web"
                header+="${LS}  - read_url_content"
            fi
            header+="${LS}---"
            header+="${LS}"
            header+="${LS}<!-- Generated by intelligence-sync. Do not edit manually. -->"
            header+="${LS}"

            spec+="$path"$'\x1f'"$agents_dir/$name.md"$'\x1f'"strip"$'\x1f'"1"$'\x1f'"none"$'\x1f'"$header"$'\x1f\n'
            report+="  agent: $name.md"$'\n'
            count=$((count + 1))
        done < <(frontmatter_index "tier,access,description" "${files[@]}")

        emit_wrapped_bodies "$spec"
        printf '%s' "$report"
    fi

    echo "  -> Agents: $count"
}

sync_to_antigravity() {
    local repo_root="$1"
    local config_file="$2"
    local output_dir="$3"

    echo "=== Antigravity ==="

    rm -rf "$output_dir/rules" "$output_dir/agents"
    mkdir -p "$output_dir/rules" "$output_dir/agents"

    sync_antigravity_rules "$repo_root" "$config_file" "$output_dir"

    # Skills -> .agents/skills/ (open standard; Antigravity reads that fixed
    # workspace path). `sync_open_skill_dirs` owns clean + populate of this
    # shared dir, and replays it when Codex, Pi or opencode already filled it.
    sync_open_skill_dirs "$repo_root" "$config_file" "$repo_root/.agents/skills"

    sync_antigravity_agents "$repo_root" "$config_file" "$output_dir/agents"
}
