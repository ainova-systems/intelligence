#!/bin/bash
# intelligence-sync: Google Antigravity adapter
# Transforms source prompts to Antigravity's native resource model.
#
# Vendor sources checked 2026-09-20: antigravity.google/docs/{rules-workflows,
# skills,subagents} and /docs/cli/{best-practices,gcli-migration}. Where this
# adapter goes past what they state, the comment says so — the vendor documents
# less than the product implements, and an unmarked guess is what drifts.
#
# Rules:
#   - Always-on (no `paths:`) -> SKIPPED here. The CLI docs tell a project to
#     "Create a GEMINI.md or AGENTS.md file at your workspace root", and the
#     `agents` adapter inlines always-on rule content into AGENTS.md. Emitting
#     copies under .agents/rules/ would double-load the same text.
#   - Path-scoped (with `paths:`) -> .agents/rules/<name>.md carrying
#     `trigger: glob` and `globs:`. NOT vendor-documented: the rules page names
#     four activation modes in prose (manual, always on, model decision, glob
#     pattern) and no frontmatter key, format or example anywhere. These keys
#     follow the Windsurf-lineage convention Antigravity inherits; re-check
#     them whenever that page grows a real schema.
#   - "Rules files are limited to 12,000 characters each" is documented, so a
#     generated scoped rule above the limit warns (targets.antigravity.
#     warn_rule_limit).
#   - Workspace-root instruction files outrank AGENTS.md where both are read:
#     GEMINI.md over AGENTS.md, and .antigravity.md over GEMINI.md in the CLI.
#     The docs host states neither order — nor AGENTS.md support on its rules
#     page — so both come from the CLI pages above plus third-party reports of
#     IDE 1.20.3. The contract quarantines both files at onboarding either way:
#     left in place, either silently overrides every synced rule, and a file
#     the project does not have costs nothing to declare.
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
    adapter_contract_legacy ".antigravity.md"
    adapter_contract_ignore "GEMINI.md"
    adapter_contract_ignore ".antigravity.md"
    adapter_contract_ignore "$output/rules/"
    adapter_contract_ignore "$output/agents/"
    adapter_contract_ignore ".agents/skills/"
}

# Documented Antigravity limit: "Rules files are limited to 12,000 characters
# each." A rule over it is not truncated visibly — the tool decides what to do
# with it — so sync reports the overflow instead of guessing. A project may
# match another effective limit or turn the warning off.
# The count is awk's `length()`, which is characters where the awk build is
# locale-aware and bytes where it is not; the two agree on ASCII rules.
# Sets IS_AG_RULE_LIMIT (0 disables the check).
antigravity_rule_limit() {
    local config_file="$1"
    local setting
    setting="$(get_target_field "$config_file" "antigravity" "warn_rule_limit")"
    case "$setting" in
        ''|true) IS_AG_RULE_LIMIT=12000 ;;
        false)   IS_AG_RULE_LIMIT=0 ;;
        *[!0-9]*|0|0*)
            echo "ERROR: targets.antigravity.warn_rule_limit must be true, false, or a positive character count without leading zeros." >&2
            return 1
            ;;
        *) IS_AG_RULE_LIMIT="$setting" ;;
    esac
}

sync_antigravity_rules() {
    local repo_root="$1"
    local config_file="$2"
    local output_dir="$3"

    # Read before the early return: a malformed setting is a manifest error
    # whether or not this project happens to have a scoped rule today.
    local rule_limit
    antigravity_rule_limit "$config_file" || return 1
    rule_limit="$IS_AG_RULE_LIMIT"

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

    # Path-scoped rule -> Glob activation (paths -> globs). The rewrite is
    # anchored inside the frontmatter block: a body line may legitimately start
    # with `paths:` (a rule documenting rule syntax does exactly that), and
    # rewriting it would corrupt the text it teaches.
    #
    # stdout carries nothing but the character-count overflow report, so the
    # limit check costs no extra process.
    local overflow
    is_fin_awk_vars
    overflow="$(awk "${IS_FIN_V[@]}" -v dst="$output_dir/rules" -v limit="$rule_limit" "$IS_AWK_LIB"'
        function emit(line,   rendered) {
            rendered = fin_line(line)
            print rendered > out
            chars[out] += length(rendered) + 1
        }
        FNR == 1 {
            if (out != "") close(out)
            out = dst "/" base_name(FILENAME)
            fm = 0
        }
        { sub(/\r$/, "") }
        FNR == 1 {
            if ($0 == "---") fm = 1
            emit($0)
            emit("trigger: glob")
            next
        }
        fm == 1 && $0 == "---" { fm = 2; emit($0); next }
        fm == 1 { sub(/^paths:/, "globs:") }
        { emit($0) }
        END {
            if (out != "") close(out)
            if (limit > 0)
                for (f in chars)
                    if (chars[f] > limit) printf "%s\t%d\n", f, chars[f]
        }
    ' "${scoped[@]}" | sort)"

    local over_file over_chars
    while IFS=$'\t' read -r over_file over_chars; do
        [ -n "$over_file" ] || continue
        echo "WARNING: Antigravity limits a rule file to $rule_limit characters: ${over_file#"$repo_root/"} renders $over_chars; split the rule, shorten it, set targets.antigravity.warn_rule_limit to the effective limit, or set it to false to disable this warning." >&2
    done <<< "$overflow"

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
            # A readonly agent gets an explicit allowlist, and it may hold only
            # names the vendor documents: "Specifying an unmapped or misspelled
            # tool name in the `tools` list may cause the subagent process to
            # hang during execution." The subagents page names four —
            # view_file, replace_file_content, grep_search, run_command — and
            # publishes no master list, so readonly takes the two that read.
            # Web and directory tools appear in leaked prompt dumps only; a
            # hang is too expensive a bet on an unpublished name.
            # An unrestricted agent declares no list and inherits the main
            # agent's tools, which is Antigravity's default.
            if [ "$access" = "readonly" ]; then
                header+="${LS}tools:"
                header+="${LS}  - view_file"
                header+="${LS}  - grep_search"
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

# Antigravity's resource paths are fixed, not configured: the docs call
# .agents/ a default with backward compatibility for .agent/, and name no
# setting that moves it. A configured output anywhere else therefore renders
# rules and agents the tool will never load, and leaves whatever the default
# path already holds behind as the only thing it does read. Sync still writes
# the requested path — rendering elsewhere for inspection is legitimate — but
# it says what the tool will actually see.
antigravity_warn_unread_output() {
    local repo_root="$1"
    local output_dir="$2"

    # Compare the resolved path, not its spelling: `.agents`, `./.agents` and
    # `.agents//` are the same directory, and the writer reaches it either way.
    adapter_contract_rel_path "${output_dir#"$repo_root"/}"
    local rel="$IS_ADAPTER_REL_PATH"
    case "$rel" in
        .agents|.agent) return 0 ;;
    esac

    echo "WARNING: Antigravity reads .agents/rules and .agents/agents (legacy .agent/), never a configured output: targets.antigravity.output '$rel' renders rules and agents no Antigravity surface loads." >&2
    if [ -d "$repo_root/.agents/rules" ] || [ -d "$repo_root/.agents/agents" ]; then
        echo "         .agents/ still holds output from an earlier run; that stale copy is what Antigravity loads. Remove it, or set the output back to .agents." >&2
    fi
}

sync_to_antigravity() {
    local repo_root="$1"
    local config_file="$2"
    local output_dir="$3"

    echo "=== Antigravity ==="

    antigravity_warn_unread_output "$repo_root" "$output_dir"

    rm -rf "$output_dir/rules" "$output_dir/agents"
    mkdir -p "$output_dir/rules" "$output_dir/agents"

    sync_antigravity_rules "$repo_root" "$config_file" "$output_dir"

    # Skills -> .agents/skills/ (open standard; Antigravity reads that fixed
    # workspace path). `sync_open_skill_dirs` owns clean + populate of this
    # shared dir, and replays it when Codex, Pi or opencode already filled it.
    sync_open_skill_dirs "$repo_root" "$config_file" "$repo_root/.agents/skills"

    sync_antigravity_agents "$repo_root" "$config_file" "$output_dir/agents"
}
