#!/bin/bash
# Unit suite for the engine readers that answer without spawning a process per
# question: each fast form must give exactly what the reader it replaces gave,
# so the previous implementations live here as the oracles they are compared to.
set -euo pipefail
REPO="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
fail=0
chk() { if ! "$@" >/dev/null 2>&1; then echo "FAIL: $*"; fail=1; fi; }

# shellcheck source=/dev/null
source "$REPO/engine/lib/common.sh"
# shellcheck source=/dev/null
source "$REPO/engine/lib/contract.sh"

eq() { [ "$1" = "$2" ]; }

# The awk reader read_schema_version_var replaced.
oracle_schema_version() {
    [ -f "$1" ] || return 0
    awk -v k="schema_version" '
        { sub(/\r$/, "") }
        $0 ~ "^" k ":" {
            v = $0; sub(/^[^:]*:[[:space:]]*/, "", v)
            gsub(/^["\047]|["\047][[:space:]]*$/, "", v)
            sub(/[[:space:]]+$/, "", v)
            print v; exit
        }
    ' "$1"
}

echo "== read_schema_version: same value as the awk reader =="
n=0
while IFS= read -r line; do
    n=$((n + 1))
    printf 'project:\n  name: x\n%s\nother: 1\n' "$line" > "$OUT/sv-$n.yaml"
    printf 'project:\r\n%s\r\n' "$line" > "$OUT/sv-crlf-$n.yaml"
    printf '%s' "$line" > "$OUT/sv-noeol-$n.yaml"
    for f in "$OUT/sv-$n.yaml" "$OUT/sv-crlf-$n.yaml" "$OUT/sv-noeol-$n.yaml"; do
        want="$(oracle_schema_version "$f")"
        read_schema_version_var "$f"
        eq "$IS_SCHEMA_VERSION" "$want" || { echo "FAIL: schema_version line [$line] in ${f##*/}: got [$IS_SCHEMA_VERSION] want [$want]"; fail=1; }
        eq "$(read_schema_version "$f")" "$want" || { echo "FAIL: read_schema_version [$line]"; fail=1; }
    done
done <<'EOF'
schema_version: "0.17.2"
schema_version: '0.17.2'
schema_version: 0.17.2
schema_version:   "0.17.2"
schema_version:"0.17.2"
schema_version: "0.17.2" # comment
schema_version: ""
schema_version:
schema_version: "
schema_version: "a: b"
schema_version: 0.17.2 '
 schema_version: "indented is not the key"
schema_versions: "other key"
EOF
# Trailing whitespace, written by printf so no editor can strip it.
for value in '"0.17.2"  ' "'0.17.2'"$'\t ' '0.17.2  ' '"0.17.2" x  '; do
    printf 'schema_version: %s\n' "$value" > "$OUT/sv-trailing.yaml"
    read_schema_version_var "$OUT/sv-trailing.yaml"
    chk eq "$IS_SCHEMA_VERSION" "$(oracle_schema_version "$OUT/sv-trailing.yaml")"
done
read_schema_version_var "$OUT/absent.yaml"
chk eq "$IS_SCHEMA_VERSION/$IS_SCHEMA_VERSION_FOUND" "/0"
printf 'schema_version: "1.0.0"\nschema_version: "2.0.0"\n' > "$OUT/sv-twice.yaml"
chk eq "$(read_schema_version "$OUT/sv-twice.yaml")" "1.0.0"

echo "== engine_version: VERSION beside the engine =="
chk eq "$(engine_version)" "$(tr -d ' \t\r\n' < "$REPO/engine/VERSION")"
engine_version_var
chk eq "$IS_ENGINE_VERSION_FOUND" "1"

echo "== load_yaml_lists: each section as read_yaml_list reads it =="
Y="$OUT/lists.yaml"
cat > "$Y" <<'EOF'
project:
  name: lists
sources:
  rules:
    - "intelligence/rules"
    - '.intelligence/packages/@a/b/rules'
  agents:
    - intelligence/agents
  skills:
    - "intelligence/skills"
    - ""
    - "second/skills"
ignore:
  - "node_modules"
  - "bin"
rules:
  - "top-level/rules"
targets:
  agents:
    enabled: true
    header: |
      text
    - not a list item at this depth
submodules:
EOF
printf 'sources:\r\n  rules:\r\n    - "crlf/rules"\r\n  skills:\r\n    - crlf/skills\r\n' > "$OUT/lists-crlf.yaml"
for file in "$Y" "$OUT/lists-crlf.yaml" "$OUT/absent-lists.yaml"; do
    [ -f "$file" ] || continue
    for section in rules agents skills ignore submodules; do
        unset "IS_YL_${section}_FILE" "IS_YL_${section}_VAL"
        want="$(read_yaml_list "$file" "$section")"
        load_yaml_lists "$file" "$section"
        load_yaml_list "$file" "$section"
        eq "$IS_YAML_LIST" "$want" || { echo "FAIL: load_yaml_lists $section in ${file##*/}: [$IS_YAML_LIST] want [$want]"; fail=1; }
    done
    for section in rules agents skills ignore submodules; do unset "IS_YL_${section}_FILE"; done
    load_yaml_lists "$file" rules agents skills ignore submodules
    for section in rules agents skills ignore submodules; do
        unset "IS_YL_${section}_FILE"
        want="$(read_yaml_list "$file" "$section")"
        load_yaml_lists "$file" rules agents skills ignore submodules
        load_yaml_list "$file" "$section"
        eq "$IS_YAML_LIST" "$want" || { echo "FAIL: load_yaml_lists (all) $section"; fail=1; }
    done
done
chk eq "$(load_yaml_lists "$Y" rules not-a-section; echo "$?")" "1"

echo "== _nested_yaml_values: every key as get_nested_yaml_value reads it =="
M="$OUT/models.yaml"
cat > "$M" <<'EOF'
models:
  claude:
    frontier: fable-z
    heavy: "claude-x" # quoted keeps # inside? no: comment after quote
    standard: sonnet-y # comment
    light: 'quoted light'
  copilot:
    heavy: ""
  claude:
    light: "second occurrence"
packs:
  a.b:
    url: https://host/repo.git
EOF
oracle_nested() {
    awk -v section="$2" -v subname="$3" -v key="$4" '
        { sub(/\r$/, "") }
        $0 ~ "^" section ":[[:space:]]*$" { in_section=1; in_sub=0; next }
        in_section && /^[a-zA-Z]/ && $0 !~ "^" section ":" { in_section=0; in_sub=0 }
        in_section && index($0, "  " subname ":") == 1 {
            if (substr($0, length(subname) + 4) ~ /^[[:space:]]*$/) { in_sub=1; next }
        }
        in_section && in_sub && /^  [A-Za-z0-9_]/ { in_sub=0 }
        in_section && in_sub && index($0, "    " key ":") == 1 {
            val = $0
            sub(/^[[:space:]]*[^:]*:[[:space:]]*/, "", val)
            if (val ~ /^"/ || val ~ /^\047/) {
                q = substr(val, 1, 1); val = substr(val, 2); i = index(val, q)
                if (i > 0) val = substr(val, 1, i - 1)
            } else { sub(/[[:space:]]+#.*$/, "", val); sub(/[[:space:]]+$/, "", val) }
            print val; exit
        }
    ' "$1"
}
for ide in claude copilot cursor; do
    for tier in frontier heavy standard light; do
        chk eq "$(get_nested_yaml_value "$M" models "$ide" "$tier")" "$(oracle_nested "$M" models "$ide" "$tier")"
        chk eq "$(get_model "$M" "$ide" "$tier")" "$(o="$(oracle_nested "$M" models "$ide" "$tier")"; [ -n "$o" ] && echo "$o" || get_model_default "$ide" "$tier")"
    done
    load_model_tiers "$M" "$ide"
    chk eq "$IS_MODEL_FRONTIER" "$(get_model "$M" "$ide" frontier)"
    chk eq "$IS_MODEL_HEAVY" "$(get_model "$M" "$ide" heavy)"
    chk eq "$IS_MODEL_STANDARD" "$(get_model "$M" "$ide" standard)"
    chk eq "$IS_MODEL_LIGHT" "$(get_model "$M" "$ide" light)"
done
chk eq "$(get_nested_yaml_value "$M" packs "a.b" url)" "https://host/repo.git"
chk eq "$(get_nested_yaml_value "$M" packs "axb" url)" ""
load_model_tiers "$OUT/absent-models.yaml" claude
chk eq "$IS_MODEL_FRONTIER/$IS_MODEL_HEAVY/$IS_MODEL_STANDARD/$IS_MODEL_LIGHT" "fable/opus/sonnet/sonnet"

echo "== every built-in agent target has a default for every standard tier =="
# An adapter writes whatever the tier resolves to, so a tier one tool has no
# default for renders an empty `model:` instead of failing.
for ide in claude cursor copilot codex antigravity opencode; do
    load_model_tiers "$OUT/absent-models.yaml" "$ide"
    for tier in frontier heavy standard light; do
        resolve_model_var "$tier"
        [ -n "$IS_MODEL" ] || { echo "FAIL: no $ide default for tier $tier"; fail=1; }
        chk eq "$IS_MODEL" "$(get_model_default "$ide" "$tier")"
    done
done

echo "== count_matching_files: what find | wc -l reports per directory =="
C="$OUT/counts"
mkdir -p "$C/rules/nested" "$C/skills/one/refs" "$C/skills/two" "$C/agents" "$C/empty"
touch "$C/rules/a.md" "$C/rules/b.md" "$C/rules/nested/c.md" "$C/rules/d.mdc" "$C/rules/.e.md" \
    "$C/skills/one/SKILL.md" "$C/skills/one/refs/x.md" "$C/skills/two/SKILL.md" "$C/agents/z.md"
oracle_count() { find "$1" -name "$2" 2>/dev/null | wc -l | tr -d ' '; }
count_matching_files "$C/rules" "*.md" "$C/skills" "SKILL.md" "$C/agents" "*.md" "$C/empty" "*.md"
chk eq "${IS_FILE_COUNTS[*]}" "$(oracle_count "$C/rules" "*.md") $(oracle_count "$C/skills" "SKILL.md") $(oracle_count "$C/agents" "*.md") 0"
count_matching_files "$C/rules" "*.mdc"
chk eq "${IS_FILE_COUNTS[*]}" "$(oracle_count "$C/rules" "*.mdc")"
chk eq "$(count_matching_files "$C/rules" "*.md" "$C/missing" "*.md"; echo "$?")" "1"

echo "== read_source_artifact_files: a memoized answer replays the first one =="
P="$OUT/project"
mkdir -p "$P/r" "$P/s/b" "$P/s/a" "$P/s/no-skill"
touch "$P/r/z.md" "$P/r/a.md" "$P/s/a/SKILL.md" "$P/s/b/SKILL.md"
printf 'sources:\n  rules:\n    - "r"\n  skills:\n    - "s"\n    - "missing"\n' > "$P/intelligence.yaml"
fresh() {
    IS_SOURCE_FILES_MEMO=0 read_source_artifact_files "$P" "$P/intelligence.yaml" "$1"
    printf '%s\n' "${IS_SOURCE_FILES[@]+"${IS_SOURCE_FILES[@]}"}"
}
for section in rules agents skills; do
    want="$(fresh "$section")"
    IS_SOURCE_FILES_MEMO=1
    read_source_artifact_files "$P" "$P/intelligence.yaml" "$section"
    first="$(printf '%s\n' "${IS_SOURCE_FILES[@]+"${IS_SOURCE_FILES[@]}"}")"
    read_source_artifact_files "$P" "$P/intelligence.yaml" "$section"
    replay="$(printf '%s\n' "${IS_SOURCE_FILES[@]+"${IS_SOURCE_FILES[@]}"}")"
    # shellcheck disable=SC2034  # read by read_source_artifact_files
    IS_SOURCE_FILES_MEMO=0
    chk eq "$first" "$want"
    chk eq "$replay" "$want"
done
# Without the engine's flag nothing is remembered: a CLI process that edits
# sources between two reads must see the second state.
touch "$P/r/m.md"
chk eq "$(fresh rules | tr '\n' ',')" "$P/r/a.md,$P/r/m.md,$P/r/z.md,"

echo "== report_context_source_sizes: one wc, the sums each group's own wc gave =="
R="$OUT/report"
mkdir -p "$R/rules" "$R/agents" "$R/skills/a" "$R/skills/b"
printf '%s\n' '---' 'description: always' '---' 'always-on body' > "$R/rules/always.md"
printf '%s\n' '---' 'description: always too' '---' 'second always-on rule, longer body' > "$R/rules/again.md"
printf '%s\n' '---' 'paths:' '  - "src/**"' '---' 'scoped body' > "$R/rules/scoped.md"
printf '%s\n' '---' 'description: agent' '---' 'agent body' > "$R/agents/one.md"
printf '%s\n' '---' 'name: a' '---' 'skill a' > "$R/skills/a/SKILL.md"
printf '%s\n' '---' 'name: b' '---' 'skill b, a little longer' > "$R/skills/b/SKILL.md"
printf '# AGENTS\nrendered\n' > "$R/AGENTS.md"
printf 'sources:\n  rules:\n    - rules\n  agents:\n    - agents\n  skills:\n    - skills\ntargets:\n  agents:\n    enabled: true\n    output: AGENTS.md\n' > "$R/intelligence.yaml"
bytes() { cat "$@" | wc -c | tr -d ' '; }
want="CONTEXT: always-on=$(bytes "$R/rules/again.md" "$R/rules/always.md") bytes (2 rules); custom=$(bytes "$R/rules/scoped.md" "$R/agents/one.md" "$R/skills/a/SKILL.md" "$R/skills/b/SKILL.md") bytes (1 scoped rules, 1 agents, 2 skills); agents-md=$(bytes "$R/AGENTS.md") bytes; agents-md-status=generated"
for section in rules agents skills ignore submodules; do unset "IS_YL_${section}_FILE"; done
unset IS_TGT_FILE
chk eq "$(report_context_source_sizes "$R" "$R/intelligence.yaml")" "$want"
# No always-on rules and no generated AGENTS.md: zero groups still report 0.
rm "$R/rules/always.md" "$R/rules/again.md" "$R/AGENTS.md"
want="CONTEXT: always-on=0 bytes (0 rules); custom=$(bytes "$R/rules/scoped.md" "$R/agents/one.md" "$R/skills/a/SKILL.md" "$R/skills/b/SKILL.md") bytes (1 scoped rules, 1 agents, 2 skills); agents-md=0 bytes; agents-md-status=not-generated"
chk eq "$(report_context_source_sizes "$R" "$R/intelligence.yaml")" "$want"

[ "$fail" -eq 0 ] && echo "ENGINE-UNIT: ALL OK"
exit "$fail"
