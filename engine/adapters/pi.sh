#!/bin/bash
# intelligence-sync: Pi adapter
# Transforms source prompts to Pi's native resource model.
#
# Rules:
#   - Always-on (no `paths:`) -> SKIPPED here. Pi reads AGENTS.md natively.
#   - Path-scoped (with `paths:`) -> copied to .pi/intelligence-sync/rules/
#     and surfaced via a generated Pi extension that lists them in the system
#     prompt so the model can `read` the relevant rule on demand.
# Skills:
#   - Copied to .agents/skills/ (Agent Skills open standard, read by Pi)
# Agents:
#   - Converted to .pi/prompts/intelligence-agent-<name>.md prompt templates
#     so users can invoke a persona explicitly via `/intelligence-agent-<name>`.
#
# Every per-file loop batches its work into one awk process (see the batched
# helpers in lib/common.sh): process spawns dominate sync time on Windows.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

adapter_contract_pi() {
    local output="${1%/}"
    adapter_contract_version 1
    adapter_contract_requires agents
    adapter_contract_managed ".agents/skills"
    adapter_contract_owned "$output/intelligence-sync"
    adapter_contract_managed "$output/extensions"
    adapter_contract_managed "$output/prompts"
    adapter_contract_ignore ".agents/skills/"
    adapter_contract_ignore "$output/intelligence-sync/"
    adapter_contract_ignore "$output/extensions/intelligence-sync-rules.ts"
    adapter_contract_ignore "$output/prompts/intelligence-agent-*.md"
}

# Fork-free TS string escape: sets IS_PI_TS_ESCAPED.
pi_ts_escape_var() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\r'/}"
    s="${s//$'\n'/ }"
    IS_PI_TS_ESCAPED="$s"
}

pi_ts_escape() {
    pi_ts_escape_var "$1"
    printf '%s' "$IS_PI_TS_ESCAPED"
}

# pi_rule_paths_rows <file>... — batch form of the old per-file `paths:`
# reader: one row per file in argument order, the path then each pattern,
# \x1f-separated. Patterns come from the frontmatter `paths:` block only,
# with one leading/trailing quote character stripped, exactly like the
# per-file reader did.
pi_rule_paths_rows() {
    [ "$#" -gt 0 ] || return 0
    awk '
        BEGIN { US = sprintf("%c", 31) }
        function store() { if (cur != "") R[cur] = row }
        FNR == 1 { store(); cur = FILENAME; row = cur; done_f = 0; in_fm = 0; in_paths = 0 }
        { sub(/\r$/, "") }
        done_f { next }
        FNR == 1 && $0 != "---" { done_f = 1; next }
        FNR == 1 { in_fm = 1; next }
        in_fm && $0 == "---" { done_f = 1; next }
        !in_fm { next }
        /^paths:[[:space:]]*$/ { in_paths = 1; next }
        in_paths && /^  - / {
            val = $0
            sub(/^  - /, "", val)
            gsub(/^["\047]|["\047]$/, "", val)
            row = row US val
            next
        }
        in_paths && !/^  - / && !/^[[:space:]]*$/ { done_f = 1 }
        END {
            store()
            for (i = 1; i < ARGC; i++) {
                if (ARGV[i] in R) print R[ARGV[i]]
                else print ARGV[i]
            }
        }
    ' "$@"
}

sync_pi_rules() {
    local repo_root="$1"
    local config_file="$2"
    local output_dir="$3"

    local rules_root="$output_dir/intelligence-sync/rules"
    local extension_file="$output_dir/extensions/intelligence-sync-rules.ts"
    local output_rel="${output_dir#$repo_root/}"
    local manifest=""
    local count=0

    mkdir -p "$rules_root" "$(dirname "$extension_file")"

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
        finalize_copy_files "$rules_root" "${scoped[@]}"

        local -a row_arr
        local base rel_rule_path patterns_js display sep display_sep pat i
        while IFS=$'\x1f' read -r -a row_arr; do
            [ "${#row_arr[@]}" -gt 0 ] || continue
            base="${row_arr[0]##*/}"
            rel_rule_path="$output_rel/intelligence-sync/rules/$base"
            patterns_js=""
            display=""
            sep=""
            display_sep=""
            i=1
            while [ "$i" -lt "${#row_arr[@]}" ]; do
                pat="${row_arr[$i]}"
                i=$((i + 1))
                [ -z "$pat" ] && continue
                pi_ts_escape_var "$pat"
                patterns_js+="$sep\"$IS_PI_TS_ESCAPED\""
                display+="$display_sep$pat"
                sep=", "
                display_sep=", "
            done
            pi_ts_escape_var "$rel_rule_path"
            manifest+="    { path: \"$IS_PI_TS_ESCAPED\", patterns: [$patterns_js] },"$'\n'
            count=$((count + 1))
            echo "  rule: $base (scoped${display:+ — $display})"
        done < <(pi_rule_paths_rows "${scoped[@]}")
    fi

    if [ "$count" -gt 0 ]; then
        {
            cat <<'EOF'
/**
 * Generated by intelligence-sync. Do not edit manually.
 * Lists path-scoped project rules generated from intelligence/rules/.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const scopedRules: Array<{ path: string; patterns: string[] }> = [
EOF
            printf '%s' "$manifest"
            cat <<'EOF'
];

export default function intelligenceSyncRulesExtension(pi: ExtensionAPI) {
    pi.on("before_agent_start", async (event) => {
        if (scopedRules.length === 0) {
            return;
        }

        const rulesList = scopedRules
            .map((rule) => `- ${rule.path} — paths: ${rule.patterns.join(", ")}`)
            .join("\n");

        return {
            systemPrompt:
                event.systemPrompt +
                `

## Scoped Project Rules

AGENTS.md already carries the always-on project rules. Additional path-scoped rules are available on demand:

${rulesList}

When the task touches files that match one of these path patterns, use the read tool to load the relevant rule file before making changes.`,
        };
    });
}
EOF
        } > "$extension_file"
        finalize_output_file "$extension_file"
    fi

    echo "  -> Rules: $count scoped"
}

sync_pi_skills() {
    local repo_root="$1"
    local config_file="$2"
    local _output_dir="$3"

    # Skills -> .agents/skills/ (open standard; Pi reads it natively).
    # `sync_open_skill_dirs` owns clean + populate of this shared dir.
    local skills_dir="$repo_root/.agents/skills"
    sync_open_skill_dirs "$repo_root" "$config_file" "$skills_dir"
}

sync_pi_agents() {
    local repo_root="$1"
    local config_file="$2"
    local output_dir="$3"

    local prompts_dir="$output_dir/prompts"
    local count=0

    mkdir -p "$prompts_dir"

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

    if [ "${#files[@]}" -gt 0 ]; then
        local path desc access name template_desc spec="" report="" LS=$'\x1e'
        while IFS=$'\x1f' read -r path desc access; do
            [ -n "$path" ] || continue
            name="${path##*/}"; name="${name%.md}"
            repo_rel_link_var "$repo_root" "$path"

            template_desc="Use $name persona"
            [ -n "$desc" ] && template_desc="$template_desc — $desc"

            local header
            yaml_dq_escape_var "$template_desc"
            header="${LS}---"
            header+="${LS}description: \"$IS_YAML_ESCAPED\""
            header+="${LS}argument-hint: \"[task]\""
            header+="${LS}---"
            header+="${LS}"
            header+="${LS}<!-- Generated by intelligence-sync. Do not edit manually. -->"
            header+="${LS}"
            header+="${LS}Adopt the \`$name\` agent persona for this task."
            header+="${LS}"
            header+="${LS}Source: \`${IS_REPO_REL:-$name (remote pack)}\`"
            if [ -n "$desc" ]; then
                header+="${LS}Use this persona when: $desc"
                header+="${LS}"
            fi
            if [ "$access" = "readonly" ]; then
                header+="${LS}## Access Mode"
                header+="${LS}"
                header+="${LS}Default to read-only analysis. Do not change files or run mutating commands unless the user explicitly asks you to override this agent's normal restriction."
                header+="${LS}"
            fi
            header+="${LS}## Agent Instructions"
            header+="${LS}"

            local tail
            tail="${LS}"
            tail+="${LS}User task: \$@"

            spec+="$path"$'\x1f'"$prompts_dir/intelligence-agent-$name.md"$'\x1f'"strip"$'\x1f'"1"$'\x1f'"none"$'\x1f'"$header"$'\x1f'"$tail"$'\n'
            report+="  agent: intelligence-agent-$name.md"$'\n'
            count=$((count + 1))
        done < <(frontmatter_index "description,access" "${files[@]}")

        emit_wrapped_bodies "$spec"
        printf '%s' "$report"
    fi

    echo "  -> Agents: $count prompt template(s)"
}

sync_to_pi() {
    local repo_root="$1"
    local config_file="$2"
    local output_dir="$3"

    echo "=== Pi ==="

    local prompts_dir="$output_dir/prompts"
    local extensions_dir="$output_dir/extensions"

    rm -rf "$output_dir/intelligence-sync"
    mkdir -p "$prompts_dir" "$extensions_dir"
    find "$prompts_dir" -mindepth 1 -maxdepth 1 -type f -name 'intelligence-agent-*.md' -delete 2>/dev/null || true
    rm -f "$extensions_dir/intelligence-sync-rules.ts"

    sync_pi_rules "$repo_root" "$config_file" "$output_dir"
    sync_pi_skills "$repo_root" "$config_file" "$output_dir"
    sync_pi_agents "$repo_root" "$config_file" "$output_dir"
}
