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

echo "== read_yaml_list: a manifest without package references reads as before =="
# The list reader before package references (decision 0019): every entry as
# written. A manifest that names packages by store path must read identically.
oracle_yaml_list() {
    awk -v section="$2" '
        { sub(/\r$/, "") }
        /^[a-z]/ { current_section = ""; depth = 0 }
        /^  [a-z]/ { current_section = ""; depth = 0 }
        $0 ~ "^" section ":" { current_section = section; depth = 0; next }
        $0 ~ "^  " section ":" { current_section = section; depth = 2; next }
        current_section == section && depth == 0 && /^  - / {
            val = $0; sub(/^  - /, "", val); gsub(/["\047]/, "", val); print val
        }
        current_section == section && depth == 2 && /^    - / {
            val = $0; sub(/^    - /, "", val); gsub(/["\047]/, "", val); print val
        }
    ' "$1"
}
printf 'sources:\n  rules:\n    - ".intelligence/packages/@a/b/rules"\n    - "@a/b/rules"\n    - "a:rules"\n    - "intelligence/rules"\npackages:\n  "@a/b":\n    version: "1"\n' \
    > "$OUT/lists-store.yaml"
for file in "$Y" "$OUT/lists-crlf.yaml"; do
    for section in rules agents skills ignore submodules; do
        unset "IS_YL_${section}_FILE" "IS_YL_${section}_VAL"
        chk eq "$(read_yaml_list "$file" "$section")" "$(oracle_yaml_list "$file" "$section")"
        chk eq "$(read_yaml_list_raw "$file" "$section")" "$(oracle_yaml_list "$file" "$section")"
    done
done
# Raw is the old reader whatever the entries say; only the expanding reader
# resolves a reference.
chk eq "$(read_yaml_list_raw "$OUT/lists-store.yaml" rules)" "$(oracle_yaml_list "$OUT/lists-store.yaml" rules)"
chk eq "$(read_yaml_list "$OUT/lists-store.yaml" rules | paste -sd, -)" \
    ".intelligence/packages/@a/b/rules,.intelligence/packages/@a/b/rules,a:rules,intelligence/rules"

echo "== package references: each spelling renders as its store path =="
# list_is <label> <want, comma-joined> <reader...>
list_is() {
    local label="$1" want="$2" got
    shift 2
    got="$("$@" | paste -sd, -)"
    [ "$got" = "$want" ] || { echo "FAIL: $label — want [$want], got [$got]"; fail=1; }
}
R="$OUT/references.yaml"
cat > "$R" <<'EOF'
sources:
  rules:
    - ".intelligence/packages/@ainova-systems/sync/rules"
    - "@ainova-systems/sync/rules"
    - "sync:rules"
    - 'core:deep/rules'
    - "@acme/undeclared/rules"
    - "nope:rules"
    - "twin:rules"
    - "sync:../escape"
    - "sync:"
    - "sync:a//b"
    - "sync:/abs"
    - "sync:./rules"
    - "@ainova-systems/sync"
    - "@ainova-systems/sync/"
    - "C:/windows/path"
    - "x:rules"
    - "intelligence/rules"
  agents:
    - "sync:agents"
ignore:
  - "sync:rules"
packages:
  "@ainova-systems/sync":
    version: "0.19.0"
    alias: "sync"
  # a comment inside the block
  "@ainova-systems/core":
    version: "^1.0.0"
    alias: core    # unquoted, with a comment
  "@ainova-systems/sync":
    alias: "second — a duplicated key is one package, its first alias wins"

  "@a/one":
    alias: "twin"
  "@b/two":
    ref: "main"
    alias: "twin"
  "@c/bad":
    alias: "a/b"
  "not-a-package-name":
    alias: "nope"
  "@a/../escape":
    alias: "nope"
registries:
  - "@ainova-systems/sync/rules"
EOF
want_rows="\
.intelligence/packages/@ainova-systems/sync/rules|path|.intelligence/packages/@ainova-systems/sync/rules||
@ainova-systems/sync/rules|ok|.intelligence/packages/@ainova-systems/sync/rules||
sync:rules|ok|.intelligence/packages/@ainova-systems/sync/rules|sync|
core:deep/rules|ok|.intelligence/packages/@ainova-systems/core/deep/rules|core|
@acme/undeclared/rules|path|@acme/undeclared/rules||
nope:rules|unknown||nope|
twin:rules|ambiguous||twin|@a/one, @b/two
sync:../escape|invalid||sync|
sync:|invalid||sync|
sync:a//b|invalid||sync|
sync:/abs|invalid||sync|
sync:./rules|invalid||sync|
@ainova-systems/sync|invalid|||
@ainova-systems/sync/|invalid|||
C:/windows/path|path|C:/windows/path||
x:rules|path|x:rules||
intelligence/rules|path|intelligence/rules||"
got_rows="$(read_source_entries "$R" rules | tr '\037' '|')"
[ "$got_rows" = "$want_rows" ] || { echo "FAIL: read_source_entries states:"; diff <(printf '%s\n' "$want_rows") <(printf '%s\n' "$got_rows"); fail=1; }
for section in rules agents skills ignore submodules; do unset "IS_YL_${section}_FILE" "IS_YL_${section}_VAL"; done
# What renders is the store path; what renders nothing is left out entirely,
# so no reader can take it for a path.
list_is "rules as the engine renders them" "\
.intelligence/packages/@ainova-systems/sync/rules,\
.intelligence/packages/@ainova-systems/sync/rules,\
.intelligence/packages/@ainova-systems/sync/rules,\
.intelligence/packages/@ainova-systems/core/deep/rules,\
@acme/undeclared/rules,C:/windows/path,x:rules,intelligence/rules" read_yaml_list "$R" rules
want_rules="$(read_yaml_list "$R" rules)"
chk eq "$want_rules" "$(read_source_entries "$R" rules | awk -F'\037' '$2 == "path" || $2 == "ok" { print $3 }')"
list_is "a list that holds no sources is never expanded" "sync:rules" read_yaml_list "$R" ignore
list_is "raw keeps every spelling" "sync:agents" read_yaml_list_raw "$R" agents
# The cache the engine warms holds the same expansion, and the same pass names
# every reference that renders nothing, for sync's WARNING: lines.
load_yaml_lists "$R" rules agents skills ignore submodules
load_yaml_list "$R" rules
chk eq "$IS_YAML_LIST" "$want_rules"
load_yaml_list "$R" agents
chk eq "$IS_YAML_LIST" ".intelligence/packages/@ainova-systems/sync/agents"
want_unresolved="$(read_source_entries "$R" rules | awk -F'\037' '$2 != "path" && $2 != "ok" { print "rules\037" $0 }')"
chk eq "$(printf '%s' "$IS_YL_UNRESOLVED")" "$want_unresolved"
chk eq "$(printf '%s' "$IS_YL_UNRESOLVED" | wc -l | tr -d ' ')" "9"
# The raw reader never answers from the expanded cache the engine warms.
list_is "raw ignores the warmed cache" "sync:agents" read_yaml_list_raw "$R" agents
for section in rules agents skills ignore submodules; do unset "IS_YL_${section}_FILE" "IS_YL_${section}_VAL"; done
load_yaml_lists "$Y" rules agents skills ignore submodules
chk eq "$IS_YL_UNRESOLVED" ""
for section in rules agents skills ignore submodules; do unset "IS_YL_${section}_FILE" "IS_YL_${section}_VAL"; done

echo "== read_package_aliases: what packages: declares, judged once =="
want_aliases="\
@ainova-systems/sync|sync|ok
@ainova-systems/core|core|ok
@a/one|twin|ambiguous
@b/two|twin|ambiguous
@c/bad||invalid"
chk eq "$(read_package_aliases "$R" | tr '\037' '|')" "$want_aliases"
chk eq "$(read_package_aliases "$OUT/absent.yaml")" ""
for a in sync ab A1 a.b a_b a-b 0day; do chk pkg_alias_valid "$a"; done
for a in "" s a/b a:b @a "a b" "a\"b" -ab .ab "a\\b"; do
    if pkg_alias_valid "$a"; then echo "FAIL: pkg_alias_valid accepted [$a]"; fail=1; fi
done
# `packages:` may come first, last, or not at all; CRLF changes nothing; a
# commented-out block declares nothing.
printf 'packages:\r\n  "@ainova-systems/sync":\r\n    alias: "sync"\r\nsources:\r\n  rules:\r\n    - "sync:rules"\r\n    - "@ainova-systems/sync/agents"\r\n' > "$OUT/refs-crlf.yaml"
list_is "packages: before sources:, CRLF" \
    ".intelligence/packages/@ainova-systems/sync/rules,.intelligence/packages/@ainova-systems/sync/agents" \
    read_yaml_list "$OUT/refs-crlf.yaml" rules
printf 'sources:\n  rules:\n    - "sync:rules"\n    - "@ainova-systems/sync/rules"\n' > "$OUT/refs-bare.yaml"
list_is "no packages: block — a full name is a path, an alias names nothing" \
    "@ainova-systems/sync/rules" read_yaml_list "$OUT/refs-bare.yaml" rules
printf 'sources:\n  rules:\n    - "sync:rules"\n# packages:\n#   "@ainova-systems/sync":\n#     alias: "sync"\n' > "$OUT/refs-commented.yaml"
chk eq "$(read_source_entries "$OUT/refs-commented.yaml" rules | tr '\037' '|')" "sync:rules|unknown||sync|"
source_reference_problem_var unknown nope ""
chk eq "$IS_SOURCE_PROBLEM" "names alias 'nope', which no package in packages: declares"
source_reference_problem_var path "" ""
chk eq "$IS_SOURCE_PROBLEM" ""

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

echo "== built-in model defaults: an independent expected matrix =="
# Every other model assertion reads get_model_default as its oracle, so only
# this matrix catches a wrong entry in the engine's table itself. Columns are
# frontier, heavy, standard, light; a model bump updates this row with it.
while read -r ide frontier heavy standard light; do
    load_model_tiers "$OUT/absent-models.yaml" "$ide"
    chk eq "$ide: $IS_MODEL_FRONTIER $IS_MODEL_HEAVY $IS_MODEL_STANDARD $IS_MODEL_LIGHT" \
        "$ide: $frontier $heavy $standard $light"
done <<'EOF'
claude      fable                       opus                       sonnet                      sonnet
cursor      inherit                     inherit                    inherit                     inherit
copilot     gpt-6-astra                 gpt-6-astra                gpt-6.1-sol                 gpt-6-luna
codex       gpt-6-astra                 gpt-6-astra                gpt-6.1-sol                 gpt-6-luna
antigravity pro                         pro                        flash                       flash
opencode    anthropic/claude-fable-5-1  anthropic/claude-opus-5-5  anthropic/claude-sonnet-5-5 anthropic/claude-sonnet-5-5
EOF

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

echo "== effort: an independent expected matrix =="
# map_effort_var is the one mapping every adapter and the skill-copy pass
# render through (decision 0015), so this matrix pins the table itself.
# Columns follow the neutral scale; `-` means the tool receives no effort.
chk eq "$IS_EFFORT_LEVELS" "low medium high xhigh max ultra"
while read -r tool low medium high xhigh max ultra; do
    row="$tool:"
    for level in $IS_EFFORT_LEVELS; do
        map_effort_var "$tool" "$level"
        row+=" ${IS_EFFORT:--}"
    done
    chk eq "$row" "$tool: $low $medium $high $xhigh $max $ultra"
done <<'EOF'
claude      low medium high xhigh max max
codex       low medium high xhigh max ultra
open        low medium high xhigh max ultra
copilot     -   -      -    -     -   -
cursor      -   -      -    -     -   -
opencode    -   -      -    -     -   -
antigravity -   -      -    -     -   -
pi          -   -      -    -     -   -
EOF
# Off the scale is matched exactly, case and quotes included, and is absent.
for tool in claude codex open; do
    for value in "" hiigh High HIGH " high" "high " '"high"' "low medium" ultra-high; do
        map_effort_var "$tool" "$value"
        chk eq "$tool [$value] -> [$IS_EFFORT]" "$tool [$value] -> []"
    done
done
chk eq "$(map_effort claude ultra)" "max"
# The awk passes receive map_effort_var's own answers, never a second table.
effort_map_var claude
chk eq "$IS_EFFORT_MAP" $'low=low\nmedium=medium\nhigh=high\nxhigh=xhigh\nmax=max\nultra=max\n'
effort_map_var copilot
chk eq "$IS_EFFORT_MAP" ""

echo "== lint_frontmatter_files: an off-scale effort warns once, an empty one never =="
L="$OUT/lint-effort"
mkdir -p "$L"
printf '%s\n' '---' 'effort: hiigh' 'effort: high' '---' 'effort: a body line' > "$L/typo.md"
printf '%s\n' '---' 'effort: High' '---' > "$L/case.md"
printf '%s\n' '---' 'effort: high' 'effort: hiigh' '---' > "$L/second.md"
printf '%s\n' '---' 'effort:' '---' > "$L/bare.md"
printf '%s\n' '---' 'effort: ""' '---' > "$L/empty.md"
printf '%s\n' '---' 'effort: "xhigh"' '---' > "$L/quoted.md"
printf '%s\r\n' '---' 'effort: ultra' '---' > "$L/crlf.md"
printf '%s\n' 'effort: hiigh' > "$L/nofm.md"
warnings="$(lint_frontmatter_files "$L"/*.md 2>&1 >/dev/null)"
chk eq "$(printf '%s\n' "$warnings" | grep -c 'effort')" 2
chk eq "$(printf '%s\n' "$warnings" | grep -c "^WARNING: $L/typo.md:2 effort \"hiigh\" is not one of low, medium, high, xhigh, max, ultra")" 1
chk eq "$(printf '%s\n' "$warnings" | grep -c "^WARNING: $L/case.md:2 effort \"High\" is not one of")" 1

echo "== copy_skill_bundle_dirs_for: effort rendered for the tree's tool =="
K="$OUT/skill-effort"
mkdir -p "$K/src/up" "$K/src/typo" "$K/src/quoted" "$K/src/none/references"
printf '%s\n' '---' 'name: up' 'effort: ultra' 'effort: low' '---' 'effort: a body line' > "$K/src/up/SKILL.md"
printf '%s\n' '---' 'name: typo' 'effort: hiigh' '---' > "$K/src/typo/SKILL.md"
printf '%s\n' '---' 'name: quoted' "effort: 'high'" '---' > "$K/src/quoted/SKILL.md"
printf '%s\n' '---' 'name: none' '---' > "$K/src/none/SKILL.md"
printf '%s\n' '---' 'effort: ultra' '---' > "$K/src/none/references/notes.md"
skill_fm() { awk '/^---$/ { if (++n == 2) exit; next } /^effort:/' "$1"; }
for tool in claude open copilot; do
    copy_skill_bundle_dirs_for "$tool" "$K/$tool" "$K/src/up" "$K/src/typo" "$K/src/quoted" "$K/src/none"
    chk eq "$(skill_fm "$K/$tool/typo/SKILL.md")" ""
    chk eq "$(skill_fm "$K/$tool/none/SKILL.md")" ""
    # Only the top-level SKILL.md is a skill's frontmatter; the body and the
    # bundled references are the author's text.
    chk eq "$(tail -n 1 "$K/$tool/up/SKILL.md")" "effort: a body line"
    chk eq "$(skill_fm "$K/$tool/none/references/notes.md")" "effort: ultra"
done
chk eq "$(skill_fm "$K/claude/up/SKILL.md")" "effort: max"
chk eq "$(skill_fm "$K/claude/quoted/SKILL.md")" "effort: 'high'"
chk eq "$(skill_fm "$K/open/up/SKILL.md")" "effort: ultra"
chk eq "$(skill_fm "$K/open/quoted/SKILL.md")" "effort: 'high'"
chk eq "$(skill_fm "$K/copilot/up/SKILL.md")" ""
chk eq "$(skill_fm "$K/copilot/quoted/SKILL.md")" ""
# The plain form renders for the shared open-standard tree.
copy_skill_bundle_dirs "$K/plain" "$K/src/up" "$K/src/typo"
chk eq "$(skill_fm "$K/plain/up/SKILL.md")" "effort: ultra"
chk eq "$(skill_fm "$K/plain/typo/SKILL.md")" ""

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
