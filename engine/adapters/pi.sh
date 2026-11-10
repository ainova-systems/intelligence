#!/bin/bash
# intelligence-sync: Pi adapter
# Transforms source prompts to Pi's native resource model.
#
# Rules:
#   - Always-on (no `paths:`) -> SKIPPED here. Pi reads AGENTS.md natively.
#     An always-on rule AGENTS.md does not carry — a local one, or one whose
#     targets leave `agents` out — goes into the generated extension, which
#     adds its body to the system prompt (decision 0021).
#   - Path-scoped (with `paths:`) -> copied to .pi/intelligence-sync/rules/
#     and surfaced via a generated Pi extension that lists them in the system
#     prompt so the model can `read` the relevant rule on demand.
# Skills:
#   - Copied to .agents/skills/ (Agent Skills open standard, read by Pi)
# Agents:
#   - Converted to .pi/prompts/intelligence-agent-<name>.md prompt templates
#     so users can invoke a persona explicitly via `/intelligence-agent-<name>`.
#   - access (decision 0026): `readonly` and `runner` each add an "Access
#     Mode" instruction to the template — readonly forbids edits and mutating
#     commands, runner allows commands and forbids edits; `full` and any
#     other value add none. Source, checked 2026-11-10: Pi's prompt-templates
#     doc (github.com/earendil-works/pi, packages/coding-agent/docs/
#     prompt-templates.md) takes only `description` and `argument-hint`, so
#     access stays prose and is not enforced.
#
# Every per-file loop batches its work into one awk process (see the batched
# helpers in lib/common.sh): process spawns dominate sync time on Windows.

# The engine and the CLI load the shared library before any adapter. Only a
# standalone source of this file loads it here: that costs a dirname process.
declare -F finalize_output_file >/dev/null 2>&1 || source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

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
    local s
    token_keep_var "$1"
    s="${IS_TOKEN_KEPT//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\r'/}"
    s="${s//$'\n'/ }"
    IS_PI_TS_ESCAPED="$s"
}

pi_ts_escape() {
    pi_ts_escape_var "$1"
    printf '%s' "$IS_PI_TS_ESCAPED"
}

# pi_rule_body_rows <file>... — one line per file in argument order: its body,
# without the frontmatter and leading or trailing blank lines, escaped as the
# contents of a TypeScript double-quoted string (`\`, `"`, tabs and line breaks
# escaped), with a token that follows its artifact expanded for the shared
# extension file (fin_own).
pi_rule_body_rows() {
    [ "$#" -gt 0 ] || return 0
    awk "$IS_AWK_LIB"'
        function store(   j, first, last, s) {
            if (cur == "") return
            first = 0; last = 0
            for (j = 1; j <= n; j++) if (B[j] != "") { if (!first) first = j; last = j }
            s = ""
            for (j = first; first && j <= last; j++) s = s (j > first ? "\\n" : "") B[j]
            R[cur] = s
        }
        FNR == 1 { store(); cur = FILENAME; n = 0; in_fm = 0; past_fm = 0 }
        { sub(/\r$/, "") }
        FNR == 1 && $0 != "---" { past_fm = 1 }
        /^---$/ && !past_fm { in_fm = !in_fm; if (!in_fm) past_fm = 1; next }
        !past_fm { next }
        {
            line = is_repl(fin_keep(fin_own($0)), "\\", "\\\\")
            line = is_repl(line, "\"", "\\\"")
            line = is_repl(line, "\t", "\\t")
            B[++n] = line
        }
        END {
            store()
            for (i = 1; i < ARGC; i++) print (ARGV[i] in R) ? R[ARGV[i]] : ""
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

    local -a scoped=() scoped_names=() always=() always_names=()
    local k=0 always_rules=""
    output_rel_var "$repo_root" "$rules_root"
    source_artifacts_var "$repo_root" "$config_file" rules pi "$IS_OUTPUT_REL/{}.md"
    while [ "$k" -lt "${#IS_SOURCE_FILES[@]}" ]; do
        if [ "${IS_SOURCE_SCOPED[k]}" = 1 ]; then
            scoped+=("${IS_SOURCE_FILES[k]}")
            scoped_names+=("${IS_SOURCE_NAMES[k]}")
        elif [ "${IS_SOURCE_IN_AGENTS[k]}" = 0 ]; then
            # An always-on rule AGENTS.md does not carry: the extension adds
            # its body to the system prompt (decision 0021).
            always+=("${IS_SOURCE_FILES[k]}")
            always_names+=("${IS_SOURCE_NAMES[k]}")
        fi
        k=$((k + 1))
    done

    if [ "${#always[@]}" -gt 0 ]; then
        local body
        k=0
        while IFS= read -r body; do
            pi_ts_escape_var "${always_names[k]}"
            always_rules+="    { name: \"$IS_PI_TS_ESCAPED\", body: \"$body\" },"$'\n'
            echo "  rule: ${always_names[k]} (always-on, in the extension)"
            k=$((k + 1))
        done < <(pi_rule_body_rows "${always[@]}")
    fi

    if [ "${#scoped[@]}" -gt 0 ]; then
        finalize_copy_named "$rules_root" "$IS_SOURCE_NAME_MAP" "${scoped[@]}"

        local path patterns rest base rel_rule_path patterns_js display sep pat gs=$'\x1d'
        k=0
        # The rule's patterns as every tool reads them (frontmatter_index
        # `paths*`), \x1d-separated. They land in the one extension file every
        # rule shares, so a token that follows its artifact arrives expanded.
        while IFS=$'\x1f' read -r path patterns; do
            [ -n "$path" ] || continue
            base="${scoped_names[k]}.md"
            k=$((k + 1))
            rel_rule_path="$output_rel/intelligence-sync/rules/$base"
            patterns_js=""
            display=""
            sep=""
            rest="$patterns"
            while [ -n "$rest" ]; do
                pat="${rest%%"$gs"*}"
                if [ "$pat" = "$rest" ]; then rest=""; else rest="${rest#*"$gs"}"; fi
                [ -n "$pat" ] || continue
                pi_ts_escape_var "$pat"
                patterns_js+="$sep\"$IS_PI_TS_ESCAPED\""
                display+="$sep$pat"
                sep=", "
            done
            pi_ts_escape_var "$rel_rule_path"
            manifest+="    { path: \"$IS_PI_TS_ESCAPED\", patterns: [$patterns_js] },"$'\n'
            count=$((count + 1))
            echo "  rule: $base (scoped${display:+ — $display})"
        done < <(frontmatter_index 'paths*' "${scoped[@]}")
    fi

    if [ "${#always[@]}" -gt 0 ]; then
        {
            cat <<'EOF'
/**
 * Generated by intelligence-sync. Do not edit manually.
 * Adds the always-on project rules AGENTS.md does not carry to the system
 * prompt, and lists path-scoped project rules generated from intelligence/rules/.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const projectRules: Array<{ name: string; body: string }> = [
EOF
            printf '%s' "$always_rules"
            cat <<'EOF'
];

const scopedRules: Array<{ path: string; patterns: string[] }> = [
EOF
            printf '%s' "$manifest"
            cat <<'EOF'
];

export default function intelligenceSyncRulesExtension(pi: ExtensionAPI) {
    pi.on("before_agent_start", async (event) => {
        let systemPrompt = event.systemPrompt;

        if (projectRules.length > 0) {
            systemPrompt += `

## Project Rules

${projectRules.map((rule) => rule.body).join("\n\n")}`;
        }

        if (scopedRules.length > 0) {
            const rulesList = scopedRules
                .map((rule) => `- ${rule.path} — paths: ${rule.patterns.join(", ")}`)
                .join("\n");

            systemPrompt += `

## Scoped Project Rules

AGENTS.md already carries the always-on project rules. Additional path-scoped rules are available on demand:

${rulesList}

When the task touches files that match one of these path patterns, use the read tool to load the relevant rule file before making changes.`;
        }

        return { systemPrompt };
    });
}
EOF
        } > "$extension_file"
        finalize_output_file "$extension_file"
    elif [ "$count" -gt 0 ]; then
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

    if [ "${#always[@]}" -gt 0 ]; then
        echo "  -> Rules: $count scoped, ${#always[@]} always-on"
    else
        echo "  -> Rules: $count scoped"
    fi
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

    local -a files=() names=()
    output_rel_var "$repo_root" "$prompts_dir"
    source_artifacts_var "$repo_root" "$config_file" agents pi "$IS_OUTPUT_REL/intelligence-agent-{}.md"
    if [ "${#IS_SOURCE_FILES[@]}" -gt 0 ]; then
        files=("${IS_SOURCE_FILES[@]}")
        names=("${IS_SOURCE_NAMES[@]}")
    fi

    if [ "${#files[@]}" -gt 0 ]; then
        local path desc access name template_desc spec="" report="" LS=$'\x1e'
        while IFS=$'\x1f' read -r path desc access; do
            name="${names[count]}"
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
            elif [ "$access" = "runner" ]; then
                header+="${LS}## Access Mode"
                header+="${LS}"
                header+="${LS}Read, search and run commands, such as builds and tests, as the task needs. Do not create, edit or delete files unless the user explicitly asks you to override this agent's normal restriction."
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
