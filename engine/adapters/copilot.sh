#!/bin/bash
# intelligence-sync: GitHub Copilot adapter
# Transforms source prompts to .github/ format
#
# Rules:
#   - Path-scoped (with `paths:`) -> .github/instructions/{name}.instructions.md (applyTo:)
#   - Always-on (no `paths:`)     -> SKIPPED here. Copilot reads AGENTS.md
#     natively, and the `agents` adapter inlines always-on rule content
#     into AGENTS.md. We also do not generate .github/copilot-instructions.md
#     because Copilot bug copilot-cli#489 makes AGENTS.md ignored when
#     copilot-instructions.md is present.
# Skills: copy skill directories in full to .github/skills/{name}/
# Agents: -> .github/agents/{name}.agent.md (description, tools, model)
#
# Git policy (decision 0014): generated output is ignored by default, as it is
# for Cursor and Claude Code — Copilot in the editor reads it from disk after
# sync. GitHub's cloud Copilot (code review, the coding agent) reads the
# repository instead, so `targets.copilot.commit_output: true` keeps the output
# tracked. Only the generated subdirectories are named, never `.github/`
# itself: workflows, templates and hand-written files there stay tracked.
#
# Every per-file loop batches its work into one awk process (see the batched
# helpers in lib/common.sh): process spawns dominate sync time on Windows.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

adapter_contract_copilot() {
    local output="${1%/}" record=adapter_contract_ignore sub
    adapter_contract_version 1
    adapter_contract_requires agents
    adapter_contract_owned "$output/instructions"
    adapter_contract_owned "$output/prompts"
    adapter_contract_owned "$output/agents"
    adapter_contract_owned "$output/skills"
    adapter_contract_legacy "$output/copilot-instructions.md"
    # A malformed value declares the default here; sync refuses it with the
    # reason, so the policy never rests on a guess.
    if copilot_commit_output_var "${2:-}" && [ "$IS_COPILOT_COMMIT_OUTPUT" = 1 ]; then
        record=adapter_contract_unignore
    fi
    # The same four paths the contract owns: every sync rewrites them, so the
    # ignore covers generated output only.
    for sub in instructions prompts agents skills; do
        "$record" "$output/$sub/"
    done
}

# copilot_commit_output_var <manifest> — the one reader of
# targets.copilot.commit_output. Sets IS_COPILOT_COMMIT_OUTPUT to 1 when the
# project commits generated output and 0 for the default; returns 1 for any
# value other than true or false. No manifest — a caller reading ownership
# only — is the default.
copilot_commit_output_var() {
    local manifest="$1" setting
    IS_COPILOT_COMMIT_OUTPUT=0
    [ -n "$manifest" ] && [ -f "$manifest" ] || return 0
    setting="$(get_target_field "$manifest" "copilot" "commit_output")"
    case "$setting" in
        ''|false) ;;
        true) IS_COPILOT_COMMIT_OUTPUT=1 ;;
        *) return 1 ;;
    esac
}

# copilot_paths_rows <file>... — batch form of the old per-file `paths:`
# joiner: one row per file in argument order, `path \x1f p1,p2,...`. Quotes
# are stripped anywhere in a pattern and the list is scanned from the first
# `paths:` line, exactly like the per-file reader did.
copilot_paths_rows() {
    [ "$#" -gt 0 ] || return 0
    awk '
        BEGIN { US = sprintf("%c", 31) }
        function store() { if (cur != "") R[cur] = row }
        FNR == 1 { store(); cur = FILENAME; row = cur US; sep = ""; done_f = 0; in_paths = 0 }
        { sub(/\r$/, "") }
        done_f { next }
        /^paths:/ { in_paths = 1; next }
        in_paths && /^  - / {
            val = $0
            sub(/^  - /, "", val)
            gsub(/["\047]/, "", val)
            row = row sep val
            sep = ","
            next
        }
        in_paths && !/^  - / && !/^$/ { done_f = 1 }
        END {
            store()
            for (i = 1; i < ARGC; i++) {
                if (ARGV[i] in R) print R[ARGV[i]]
                else print ARGV[i] US
            }
        }
    ' "$@"
}

# Sync rules to Copilot format. Only path-scoped rules are emitted —
# always-on rules live in AGENTS.md (read by Copilot natively).
sync_copilot_rules() {
    local repo_root="$1"
    local config_file="$2"
    local output_dir="$3"

    local instructions_dir="$output_dir/instructions"
    mkdir -p "$instructions_dir"

    local scoped_count=0

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

    local -a scoped=()
    if [ "${#files[@]}" -gt 0 ]; then
        local path hp
        while IFS=$'\x1f' read -r path hp; do
            [ -n "$path" ] || continue
            [ "$hp" -eq 0 ] && continue
            scoped+=("$path")
        done < <(frontmatter_index "paths#" "${files[@]}")
    fi

    if [ "${#scoped[@]}" -gt 0 ]; then
        local base paths_line spec="" report="" LS=$'\x1e'
        while IFS=$'\x1f' read -r path paths_line; do
            [ -n "$path" ] || continue
            base="${path##*/}"; base="${base%.md}"

            local header
            header="${LS}---"
            header+="${LS}applyTo: \"$paths_line\""
            header+="${LS}---"
            header+="${LS}"

            spec+="$path"$'\x1f'"$instructions_dir/$base.instructions.md"$'\x1f'"fence_nofm"$'\x1f'"0"$'\x1f'"none"$'\x1f'"$header"$'\x1f\n'
            report+="  rule: $base.instructions.md (scoped)"$'\n'
            scoped_count=$((scoped_count + 1))
        done < <(copilot_paths_rows "${scoped[@]}")

        emit_wrapped_bodies "$spec"
        printf '%s' "$report"
    fi

    echo "  rules: $scoped_count scoped"
}

# Sync skills to Copilot format (SKILL.md in .github/skills/)
sync_copilot_skills() {
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

    local count=0
    if [ "${#skill_dirs[@]}" -gt 0 ]; then
        copy_skill_bundle_dirs "$output_dir/skills" "${skill_dirs[@]}"
        for d in "${skill_dirs[@]}"; do
            skill_name="${d%/}"
            count=$((count + 1))
            echo "  skill: ${skill_name##*/}"
        done
    fi

    echo "  -> Skills: $count"
}

# Sync agents to Copilot format (.github/agents/{name}.agent.md)
sync_copilot_agents() {
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
        load_model_tiers "$config_file" "copilot"

        local path tier access description name tools_line spec="" report="" LS=$'\x1e'
        while IFS=$'\x1f' read -r path tier access description; do
            [ -n "$path" ] || continue
            name="${path##*/}"; name="${name%.md}"
            resolve_model_var "$tier"

            # Build tools list based on access. Tool aliases per Copilot custom-agent
            # spec: `read`, `search`, `edit`, `execute`, `agent`, `web`, `todo`, `*`.
            # Omitting `tools:` grants all; restrict to read/search for readonly access.
            tools_line=""
            if [ "$access" = "readonly" ]; then
                tools_line="tools: [\"read\", \"search\"]"
            fi

            local header
            yaml_dq_escape_var "$description"
            header="${LS}---"
            header+="${LS}description: \"$IS_YAML_ESCAPED\""
            header+="${LS}model: $IS_MODEL"
            [ -n "$tools_line" ] && header+="${LS}$tools_line"
            header+="${LS}---"
            header+="${LS}"

            spec+="$path"$'\x1f'"$output_dir/agents/$name.agent.md"$'\x1f'"fence"$'\x1f'"0"$'\x1f'"none"$'\x1f'"$header"$'\x1f\n'
            report+="  agent: $name.agent.md (tier=$tier -> model=$IS_MODEL)"$'\n'
            count=$((count + 1))
        done < <(frontmatter_index "tier,access,description" "${files[@]}")

        emit_wrapped_bodies "$spec"
        printf '%s' "$report"
    fi

    echo "  -> Agents: $count"
}

# Main entry point for Copilot adapter
sync_to_copilot() {
    local repo_root="$1"
    local config_file="$2"
    local output_dir="$3"

    echo "=== GitHub Copilot ==="

    copilot_commit_output_var "$config_file" || {
        echo "ERROR: targets.copilot.commit_output must be true or false: true keeps generated Copilot output tracked, false or omission ignores it." >&2
        return 1
    }

    # Clean generated content (preserve workflows, etc.)
    rm -rf "$output_dir/instructions" "$output_dir/prompts"
    if [ -d "$output_dir/skills" ]; then
        find "$output_dir/skills" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} +
    fi
    rm -rf "$output_dir/agents"
    mkdir -p "$output_dir" "$output_dir/skills" "$output_dir/agents"

    sync_copilot_rules "$repo_root" "$config_file" "$output_dir"
    sync_copilot_skills "$repo_root" "$config_file" "$output_dir"
    sync_copilot_agents "$repo_root" "$config_file" "$output_dir"
}
