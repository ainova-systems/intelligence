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

echo "== load_manifest_view: one pass, each reader's own answer =="
# The field reader before it shared its program with the combined pass.
oracle_yaml_field() {
    awk -v section="$2" -v key="$3" '
        { sub(/\r$/, "") }
        $0 ~ "^" section ":" { in_section = 1; next }
        in_section && /^[a-zA-Z]/ { exit }
        in_section && $0 ~ "^  " key ":" {
            val = $0
            sub(/.*:[[:space:]]*["\047]?/, "", val)
            sub(/["\047]?[[:space:]]*$/, "", val)
            print val
            exit
        }
    ' "$1"
}
V="$OUT/view.yaml"
cat > "$V" <<'EOF'
project:
  name: "view"
  intelligence_dir: 'content'
project:
  intelligence_dir: second
sources:
  rules:
    - "intelligence/rules"
  skills:
    - a/skills
targets:
  agents: { enabled: true, output: "AGENTS.md" }
  claude:
    enabled: false
    output: .claude
  codex:
    output: ".codex"
EOF
printf 'project:\r\n  intelligence_dir: crlf\r\ntargets:\r\n  agents:\r\n    enabled: true\r\n' > "$OUT/view-crlf.yaml"
printf 'sources:\n  rules:\n    - r\n' > "$OUT/view-bare.yaml"
for file in "$V" "$OUT/view-crlf.yaml" "$OUT/view-bare.yaml" "$Y"; do
    manifest_view_reset
    load_targets_cache "$file"
    want_targets="$IS_TGT_TSV"
    manifest_view_reset
    want_lists="$(read_yaml_list "$file" rules)|$(read_yaml_list "$file" agents)|$(read_yaml_list "$file" skills)"
    want_field="$(oracle_yaml_field "$file" project intelligence_dir)"
    load_manifest_view "$file" project intelligence_dir rules agents skills
    eq "$IS_TGT_TSV" "$want_targets" || { echo "FAIL: load_manifest_view targets in ${file##*/}"; fail=1; }
    # shellcheck disable=SC2154  # assigned through printf -v by the reader
    eq "$IS_YL_rules_VAL|$IS_YL_agents_VAL|$IS_YL_skills_VAL" "$want_lists" \
        || { echo "FAIL: load_manifest_view lists in ${file##*/}"; fail=1; }
    get_yaml_field_var "$file" project intelligence_dir
    eq "$IS_YAML_FIELD" "$want_field" || { echo "FAIL: load_manifest_view field in ${file##*/}"; fail=1; }
    chk eq "$(get_yaml_field "$file" project intelligence_dir)" "$want_field"
    manifest_view_reset
    chk eq "$(get_yaml_field "$file" project intelligence_dir)" "$want_field"
    chk eq "$(get_yaml_field "$file" project name)" "$(oracle_yaml_field "$file" project name)"
done
chk eq "$(load_manifest_view "$V" project intelligence_dir rules not-a-section; echo "$?")" "1"
manifest_view_reset

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

echo "== list entries: a trailing comment is not part of the value =="
# Every list read_yaml_list and load_yaml_list(s) serve read `- "x"  # c` as
# `x  # c`, so a commented source named a directory that does not exist and was
# skipped in silence. A comment starts at a `#` after whitespace outside quotes.
C="$OUT/comments.yaml"
cat > "$C" <<'EOF'
sources:
  rules:
    - "intelligence/rules"  # project rules
    - 'single'	# a tab before the comment
    - plain # unquoted
    - "a #b"
    - plain#hash
    - "#quoted"
    -   "spaced"
    - intelligence/extra
  agents:
    - "intelligence/agents" # agents
ignore:
  - "node_modules"  # dependencies
  - "bin"
submodules:
  - "libs/shared" # a submodule
EOF
# Whitespace after the closing quote is no part of the value either; written
# here because an editor would strip it from the fixture above.
awk '{ if ($0 == "    -   \"spaced\"") $0 = $0 "  "; print }' "$C" > "$C.tmp" && mv "$C.tmp" "$C"
chk grep -qx '    -   "spaced"  ' "$C"
want_rules='intelligence/rules,single,plain,a #b,plain#hash,#quoted,spaced,intelligence/extra'
for section in rules agents skills ignore submodules; do unset "IS_YL_${section}_FILE" "IS_YL_${section}_VAL"; done
chk eq "$(read_yaml_list "$C" rules | paste -sd, -)" "$want_rules"
chk eq "$(read_yaml_list_raw "$C" rules | paste -sd, -)" "$want_rules"
chk eq "$(read_source_entries "$C" rules | awk -F'\037' '{ print $1 }' | paste -sd, -)" "$want_rules"
chk eq "$(read_yaml_list "$C" agents)" "intelligence/agents"
chk eq "$(read_yaml_list "$C" ignore | paste -sd, -)" "node_modules,bin"
chk eq "$(read_yaml_list "$C" submodules)" "libs/shared"
# The cache the engine warms reads them the same way.
load_yaml_lists "$C" rules agents skills ignore submodules
load_yaml_list "$C" rules
chk eq "$(printf '%s\n' "$IS_YAML_LIST" | paste -sd, -)" "$want_rules"
load_yaml_list "$C" ignore
chk eq "$(printf '%s\n' "$IS_YAML_LIST" | paste -sd, -)" "node_modules,bin"
load_yaml_list "$C" submodules
chk eq "$IS_YAML_LIST" "libs/shared"
for section in rules agents skills ignore submodules; do unset "IS_YL_${section}_FILE" "IS_YL_${section}_VAL"; done
# A reference behind a comment resolves like any other entry.
printf 'sources:\n  rules:\n    - "sync:rules"  # by alias\n    - "@a/sync/rules" # by name\npackages:\n  "@a/sync":\n    alias: "sync"\n' > "$OUT/comments-refs.yaml"
chk eq "$(read_yaml_list "$OUT/comments-refs.yaml" rules | paste -sd, -)" \
    ".intelligence/packages/@a/sync/rules,.intelligence/packages/@a/sync/rules"

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
# The CLI's preload answers from one combined pass (load_manifest_view): it
# expands each spelling to the same store path, with `packages:` after
# `sources:`, and names the same unresolved references. sync derives the paths
# its cache fingerprints from this answer.
manifest_view_reset
load_manifest_view "$R" project intelligence_dir rules agents skills
load_yaml_list "$R" rules
chk eq "$IS_YAML_LIST" "$want_rules"
load_yaml_list "$R" agents
chk eq "$IS_YAML_LIST" ".intelligence/packages/@ainova-systems/sync/agents"
chk eq "$(printf '%s' "$IS_YL_UNRESOLVED")" "$want_unresolved"
chk eq "$IS_TGT_FILE" "$R"
manifest_view_reset
chk eq "${IS_YL_UNRESOLVED-unset}" "unset"
printf 'packages:\r\n  "@a/b":\r\n    alias: "ab"\r\nsources:\r\n  rules:\r\n    - "ab:rules"\r\n    - "@a/b/agents"\r\n' > "$OUT/view-refs-crlf.yaml"
load_manifest_view "$OUT/view-refs-crlf.yaml" project intelligence_dir rules agents skills
load_yaml_list "$OUT/view-refs-crlf.yaml" rules
chk eq "$(printf '%s\n' "$IS_YAML_LIST" | paste -sd, -)" ".intelligence/packages/@a/b/rules,.intelligence/packages/@a/b/agents"
chk eq "$IS_YL_UNRESOLVED" ""
manifest_view_reset

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
claude      fable                       opus                       sonnet                      haiku
cursor      inherit                     inherit                    inherit                     inherit
copilot     gpt-6-astra                 gpt-6-astra                gpt-6.1-sol                 gpt-6-luna
codex       gpt-6-astra                 gpt-6-astra                gpt-6.1-sol                 gpt-6-luna
antigravity pro                         pro                        flash                       flash
opencode    anthropic/claude-fable-5-2  anthropic/claude-opus-5-5  anthropic/claude-sonnet-5-5 anthropic/claude-haiku-5-5
EOF
# A project keeps the earlier light model with one override, and sync's drift
# report names it against the new default. The earlier OpenCode frontier model
# is kept the same way.
printf '%s\n' 'models:' '  claude:' '    light: sonnet' '  opencode:' '    light: "anthropic/claude-sonnet-5-5"' \
    '    frontier: "anthropic/claude-fable-5-1"' > "$OUT/light-pin.yaml"
load_model_tiers "$OUT/light-pin.yaml" claude
chk eq "$IS_MODEL_LIGHT" "sonnet"
load_model_tiers "$OUT/light-pin.yaml" opencode
chk eq "$IS_MODEL_LIGHT" "anthropic/claude-sonnet-5-5"
chk eq "$IS_MODEL_FRONTIER" "anthropic/claude-fable-5-1"
drift="$(report_model_drift "$OUT/light-pin.yaml")"
chk grep -Eq '^  claude +light +config="sonnet" +default="haiku"$' <<< "$drift"
chk grep -Eq '^  opencode +light +config="anthropic/claude-sonnet-5-5" +default="anthropic/claude-haiku-5-5"$' <<< "$drift"
chk grep -Eq '^  opencode +frontier +config="anthropic/claude-fable-5-1" +default="anthropic/claude-fable-5-2"$' <<< "$drift"

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

echo "== layout tokens: a project source's token that reads as text warns, an escaped one stays literal =="
TK="$OUT/tokens"
mkdir -p "$TK/intelligence/rules" "$TK/.intelligence/packages/@a/b/rules"
printf -- '---\ndescription: "deploy/<module>_update_N"\n---\nRead `<module>/references/x.md` in `<content-dir>/`.\nKeep `\\<module>_schema()` and `<module>.info.yml`.\n<manifest></manifest>\n' > "$TK/intelligence/rules/r.md"
cp "$TK/intelligence/rules/r.md" "$TK/.intelligence/packages/@a/b/rules/r.md"
# The package copy is never read: packages use tokens by design.
warnings="$(source_frontmatter_scan "$TK" "$TK/intelligence/rules/r.md" "$TK/.intelligence/packages/@a/b/rules/r.md" 2>&1 >/dev/null)"
chk eq "$(printf '%s\n' "$warnings" | sed 's/ is part of the text.*//')" \
    "$(printf 'WARNING: intelligence/rules/r.md:%s\n' '2 <module>' '5 <module>' '6 <manifest>')"
chk eq "$(printf '%s\n' "$warnings" | tail -n 1)" \
    'WARNING: intelligence/rules/r.md:6 <manifest> is part of the text around it, but sync renders this layout token as intelligence.yaml; write \<manifest> to keep it as written'
chk eq "$(source_frontmatter_scan "" "$TK/intelligence/rules/r.md" 2>&1 >/dev/null)" ""
cp "$TK/intelligence/rules/r.md" "$OUT/tokens-out.md"
IS_MODULE_REL=.intelligence/packages/@s/sync IS_CONTENT_REL=brain finalize_output_file "$OUT/tokens-out.md"
chk grep -Fqx 'Read `.intelligence/packages/@s/sync/references/x.md` in `brain/`.' "$OUT/tokens-out.md"
chk grep -Fqx 'Keep `<module>_schema()` and `.intelligence/packages/@s/sync.info.yml`.' "$OUT/tokens-out.md"
# A quoted value decodes to what the plain text renders as: the escape is
# resolved before the escaper doubles the backslash.
yaml_dq_escape_var 'Keep \<module>, \\<module> and <module>'
printf 'description: "%s"\n' "$IS_YAML_ESCAPED" > "$OUT/tokens-yaml.md"
IS_MODULE_REL=m finalize_output_file "$OUT/tokens-yaml.md"
chk grep -Fqx 'description: "Keep <module>, \\<module> and m"' "$OUT/tokens-yaml.md"
# A value renders as written: a backslash in it is not an escape sequence.
printf '%s\n' 'see <content-dir>/x' > "$OUT/tokens-backslash.md"
IS_CONTENT_REL='we\ird\new\\dir' finalize_output_file "$OUT/tokens-backslash.md" 2>/dev/null
chk grep -Fqx 'see we\ird\new\\dir/x' "$OUT/tokens-backslash.md"
# Each value reaches awk on its own: one holding the unit separator stays one
# value, and the token after it keeps its own.
printf '%s\n' '<content-dir> <module>' > "$OUT/tokens-separator.md"
IS_CONTENT_REL=$'brain\x1fnotes' IS_MODULE_REL=m finalize_output_file "$OUT/tokens-separator.md"
chk eq "$(cat "$OUT/tokens-separator.md")" $'brain\x1fnotes m'

echo "== source lint: every warning names its source relative to the root =="
LR="$OUT/lint-root"
mkdir -p "$LR/intelligence/agents" "$LR/.intelligence/packages/@a/b/agents" "$OUT/lint-shared"
printf '%s\n' '---' 'description: a: b' 'effort: hiigh' '---' 'Body <module>_x' > "$LR/intelligence/agents/fm.md"
cp "$LR/intelligence/agents/fm.md" "$LR/.intelligence/packages/@a/b/agents/fm.md"
cp "$LR/intelligence/agents/fm.md" "$OUT/lint-shared/fm.md"
warnings="$(source_frontmatter_scan "$LR" "$LR/intelligence/agents/fm.md" \
    "$LR/.intelligence/packages/@a/b/agents/fm.md" "$LR/../lint-shared/fm.md" 2>&1 >/dev/null)"
chk eq "$(printf '%s\n' "$warnings" | cut -d ' ' -f 1-3)" "$(printf 'WARNING: %s\n' \
    'intelligence/agents/fm.md:2 unquoted' 'intelligence/agents/fm.md:3 effort' \
    'intelligence/agents/fm.md:5 <module>' \
    '.intelligence/packages/@a/b/agents/fm.md:2 unquoted' '.intelligence/packages/@a/b/agents/fm.md:3 effort' \
    '../lint-shared/fm.md:2 unquoted' '../lint-shared/fm.md:3 effort' '../lint-shared/fm.md:5 <module>')"
chk eq "$(printf '%s\n' "$warnings" | head -n 1)" \
    'WARNING: intelligence/agents/fm.md:2 unquoted colon in value at column 15 — wrap value in quotes'

echo "== source lint: skill and agent keys that do something other than they read =="
# One warning per file and key, from the pass every sync runs over every
# source, packages included; the engine says which sources are agents.
SL="$OUT/lint-keys"
mkdir -p "$SL/intelligence/rules" "$SL/intelligence/agents" "$SL/.intelligence/packages/@a/b/skills/pkg"
for skill in inline dead forked plain; do mkdir -p "$SL/intelligence/skills/$skill"; done
printf 'sources:\n  rules:\n    - "intelligence/rules"\n  agents:\n    - "intelligence/agents"\n  skills:\n    - ".intelligence/packages/@a/b/skills"\n    - "intelligence/skills"\ntargets:\n  claude: { enabled: true, output: ".claude" }\n  cursor: { enabled: true, output: ".cursor" }\n' > "$SL/intelligence.yaml"
printf '%s\n' '---' 'name: inline' 'model: fable' 'tier: frontier' '---' 'model: a body line' 'agent: a body line' > "$SL/intelligence/skills/inline/SKILL.md"
printf '%s\r\n' '---' 'name: dead' 'agent: reviewer' 'context: inline' '---' > "$SL/intelligence/skills/dead/SKILL.md"
printf '%s\n' '---' 'name: forked' 'context: "fork"' 'agent: reviewer' 'model: haiku' '---' > "$SL/intelligence/skills/forked/SKILL.md"
printf '%s\n' '---' 'name: plain' 'model:' '---' > "$SL/intelligence/skills/plain/SKILL.md"
printf '%s\n' '---' 'name: pkg' 'agent: reviewer' '---' > "$SL/.intelligence/packages/@a/b/skills/pkg/SKILL.md"
printf '%s\n' '---' 'description: a rule' 'model: haiku' 'tier: light' '---' > "$SL/intelligence/rules/r.md"
printf '%s\n' '---' 'name: pinned' 'description: x' 'tier: standard' 'model: haiku' 'access: readonly' \
    'tools: Read, Grep' 'disallowedTools: Write' '---' '' '# Pinned' '' '```yaml' 'tier: heavy' 'access: readonly' \
    'tools: Read' 'model: x' '```' > "$SL/intelligence/agents/pinned.md"
printf '%s\n' '---' 'name: listed' 'description: y' 'access: readonly' 'tools:' '  - Read' '  - Grep' 'readonly: true' \
    '---' 'Body' > "$SL/intelligence/agents/listed.md"
printf '%s\n' '---' 'name: open' 'description: z' 'access: full' 'tools: Read' '---' 'Body' > "$SL/intelligence/agents/open.md"
printf '%s\n' '---' 'name: bare' 'description: w' 'tier: light' '---' 'Body' > "$SL/intelligence/agents/bare.md"
# A key a tool replaces warns only where that tool renders the agent.
printf '%s\n' '---' 'name: elsewhere' 'access: readonly' 'tools: Read' 'readonly: true' 'targets: [codex]' '---' 'Body' \
    > "$SL/intelligence/agents/elsewhere.md"
printf '%s\n' '---' 'name: nocursor' 'access: readonly' 'readonly: true' 'tools: Read' 'exclude_targets:' '  - cursor' \
    '---' 'Body' > "$SL/intelligence/agents/nocursor.md"
IS_SOURCE_FILES_MEMO=0 source_catalog_build "$SL" "$SL/intelligence.yaml" lint 2> "$OUT/lint-keys.err"
chk eq "$(cat "$OUT/lint-keys.err")" "$(printf 'WARNING: %s\n' \
    'intelligence/agents/listed.md:5 tools: is replaced in Claude Code by the tools access: readonly grants — set access: instead' \
    'intelligence/agents/listed.md:8 readonly: is replaced in Cursor by what access: readonly sets — set access: instead' \
    'intelligence/agents/nocursor.md:5 tools: is replaced in Claude Code by the tools access: readonly grants — set access: instead' \
    'intelligence/agents/pinned.md:5 model: on an agent is not read — tier: selects its model in every tool; pin one under models.<tool>.<tier>' \
    'intelligence/agents/pinned.md:7 tools: is replaced in Claude Code by the tools access: readonly grants — set access: instead' \
    'intelligence/agents/pinned.md:8 disallowedTools: is replaced in Claude Code by what access: readonly disallows — set access: instead' \
    '.intelligence/packages/@a/b/skills/pkg/SKILL.md:3 agent: selects nothing without context: fork — fork the skill or remove the field' \
    'intelligence/skills/dead/SKILL.md:3 agent: selects nothing without context: fork — fork the skill or remove the field' \
    'intelligence/skills/inline/SKILL.md:3 model: without context: fork switches the session model for the rest of the turn and drops the prompt cache — fork the skill or remove the field' \
    'intelligence/skills/inline/SKILL.md:4 tier: is read on agents only — on a skill every tool receives it as written')"

echo "== agent transforms: a key the adapter writes is not copied, and the body keeps every line =="
mkdir -p "$SL/.claude/agents" "$SL/.cursor/agents"
# shellcheck source=/dev/null
source "$REPO/engine/adapters/claude.sh"
# shellcheck source=/dev/null
source "$REPO/engine/adapters/cursor.sh"
sync_claude_agents "$SL" "$SL/intelligence.yaml" "$SL/.claude" > /dev/null 2>&1
sync_cursor_agents "$SL" "$SL/intelligence.yaml" "$SL/.cursor" > /dev/null 2>&1
body_lines=('' '# Pinned' '' '```yaml' 'tier: heavy' 'access: readonly' 'tools: Read' 'model: x' '```')
chk eq "$(cat "$SL/.claude/agents/pinned.md")" "$(printf '%s\n' '---' 'name: pinned' 'description: x' \
    'tools: Read, Grep, Glob, Bash' 'disallowedTools: Write, Edit' 'model: sonnet' '---' "${body_lines[@]}")"
chk eq "$(cat "$SL/.cursor/agents/pinned.md")" "$(printf '%s\n' '---' 'name: pinned' 'description: x' \
    'model: inherit' 'readonly: true' '---' "${body_lines[@]}")"
# A block list goes with its key; a key access does not write passes through.
chk eq "$(cat "$SL/.claude/agents/listed.md")" "$(printf '%s\n' '---' 'name: listed' 'description: y' 'readonly: true' \
    'tools: Read, Grep, Glob, Bash' 'disallowedTools: Write, Edit' 'model: opus' '---' 'Body')"
chk eq "$(cat "$SL/.cursor/agents/listed.md")" "$(printf '%s\n' '---' 'name: listed' 'description: y' \
    'model: inherit' 'readonly: true' '---' 'Body')"
chk eq "$(cat "$SL/.claude/agents/open.md")" "$(printf '%s\n' '---' 'name: open' 'description: z' 'tools: Read' \
    'model: opus' '---' 'Body')"
chk eq "$(cat "$SL/.claude/agents/bare.md")" "$(printf '%s\n' '---' 'name: bare' 'description: w' 'model: haiku' '---' 'Body')"
chk eq "$(cat "$SL/.cursor/agents/bare.md")" "$(printf '%s\n' '---' 'name: bare' 'description: w' 'model: inherit' '---' 'Body')"

echo "== agent transforms: a block list at the key's own indent goes with it, and an agent without frontmatter is all body =="
# YAML lets a block list sit at its key's indentation; the items of a key the
# transform drops go with it. Only a --- on line 1 opens frontmatter, so an
# agent without one keeps every line, a later --- pair included, and gains no
# key the adapter writes.
FT="$OUT/transform-edges"
mkdir -p "$FT/intelligence/agents" "$FT/.claude/agents" "$FT/.cursor/agents"
printf 'sources:\n  agents:\n    - "intelligence/agents"\ntargets:\n  claude: { enabled: true, output: ".claude" }\n  cursor: { enabled: true, output: ".cursor" }\n' \
    > "$FT/intelligence.yaml"
printf '%s\n' '---' 'name: flat' 'description: f' 'access: readonly' 'tools:' '- Read' '- Grep' 'model:' '- x' \
    'readonly:' '- true' 'exclude_targets:' '- codex' '---' 'Body' '- a body item' > "$FT/intelligence/agents/flat.md"
printf '%s\n' 'No frontmatter' '' '---' 'key: value' '---' '' 'after the pair' > "$FT/intelligence/agents/nofm.md"
sync_claude_agents "$FT" "$FT/intelligence.yaml" "$FT/.claude" > /dev/null 2>&1
sync_cursor_agents "$FT" "$FT/intelligence.yaml" "$FT/.cursor" > /dev/null 2>&1
chk eq "$(cat "$FT/.claude/agents/flat.md")" "$(printf '%s\n' '---' 'name: flat' 'description: f' 'readonly:' '- true' \
    'tools: Read, Grep, Glob, Bash' 'disallowedTools: Write, Edit' 'model: opus' '---' 'Body' '- a body item')"
chk eq "$(cat "$FT/.cursor/agents/flat.md")" "$(printf '%s\n' '---' 'name: flat' 'description: f' \
    'model: inherit' 'readonly: true' '---' 'Body' '- a body item')"
chk eq "$(cat "$FT/.claude/agents/nofm.md")" "$(cat "$FT/intelligence/agents/nofm.md")"
chk eq "$(cat "$FT/.cursor/agents/nofm.md")" "$(cat "$FT/intelligence/agents/nofm.md")"

echo "== source lint: an access value outside full, readonly and runner =="
# One warning per file, naming the value and the vocabulary (decision 0026).
# The value is matched exactly, as the adapters match it; runner is in the
# vocabulary, so it is the tools: that Claude Code replaces under it, and the
# readonly: that Cursor replaces, that warn; a full agent's readonly: passes
# through; an empty value is absent.
SA="$OUT/lint-access"
mkdir -p "$SA/intelligence/agents"
printf 'sources:\n  agents:\n    - "intelligence/agents"\ntargets:\n  claude: { enabled: true, output: ".claude" }\n  cursor: { enabled: true, output: ".cursor" }\n' \
    > "$SA/intelligence.yaml"
printf '%s\n' '---' 'name: typo' 'access: read-only' '---' 'access: also-bad in the body' > "$SA/intelligence/agents/typo.md"
printf '%s\n' '---' 'name: cased' 'description: c' 'access: "Runner"' '---' > "$SA/intelligence/agents/cased.md"
printf '%s\n' '---' 'name: run' 'access: runner' 'tools: Read' 'readonly: false' '---' > "$SA/intelligence/agents/run.md"
printf '%s\n' '---' 'name: ro' 'access: readonly' '---' > "$SA/intelligence/agents/ro.md"
printf '%s\n' '---' 'name: all' 'access: full' 'readonly: true' '---' > "$SA/intelligence/agents/all.md"
printf '%s\n' '---' 'name: blank' 'access:' '---' > "$SA/intelligence/agents/blank.md"
IS_SOURCE_FILES_MEMO=0 source_catalog_build "$SA" "$SA/intelligence.yaml" lint 2> "$OUT/lint-access.err"
chk eq "$(cat "$OUT/lint-access.err")" "$(printf 'WARNING: %s\n' \
    'intelligence/agents/cased.md:4 access "Runner" is not one of full, readonly, runner — every tool renders it as full access' \
    'intelligence/agents/run.md:4 tools: is replaced in Claude Code by the tools access: runner grants — set access: instead' \
    'intelligence/agents/run.md:5 readonly: is replaced in Cursor by what access: runner sets — set access: instead' \
    'intelligence/agents/typo.md:3 access "read-only" is not one of full, readonly, runner — every tool renders it as full access')"
# With neither Claude Code nor Cursor enabled, no tool replaces those keys.
printf 'sources:\n  agents:\n    - "intelligence/agents"\ntargets:\n  claude: { enabled: false, output: ".claude" }\n  copilot: { enabled: true, output: ".github" }\n' \
    > "$SA/off.yaml"
IS_SOURCE_FILES_MEMO=0 source_catalog_build "$SA" "$SA/off.yaml" lint 2> "$OUT/lint-access-off.err"
chk eq "$(cat "$OUT/lint-access-off.err")" "$(printf 'WARNING: %s\n' \
    'intelligence/agents/cased.md:4 access "Runner" is not one of full, readonly, runner — every tool renders it as full access' \
    'intelligence/agents/typo.md:3 access "read-only" is not one of full, readonly, runner — every tool renders it as full access')"

echo "== a comment after a keyword value is no part of it, for the readers and the lint alike =="
# tier, access and effort are keywords to every renderer, context, agent and
# model to the lint as well, and disable-model-invocation to the Codex skill
# policy: a YAML comment after one (a # after
# whitespace, outside quotes) is not read, a # inside quotes is the value's,
# and a free-text key such as description keeps every character.
KC="$OUT/keyword-comment"
mkdir -p "$KC/intelligence/agents" "$KC/intelligence/skills/cfork" "$KC/intelligence/skills/eff"
printf 'sources:\n  agents:\n    - "intelligence/agents"\n  skills:\n    - "intelligence/skills"\ntargets:\n  claude: { enabled: true, output: ".claude" }\n' \
    > "$KC/intelligence.yaml"
printf '%s\n' '---' 'name: noted' 'description: Noted # kept' 'tier: light # cheap' 'access: runner # note' \
    $'effort: high\t# deep' '---' 'Body' > "$KC/intelligence/agents/noted.md"
printf '%s\n' '---' 'name: quoted' 'access: "runner # not a comment"' '---' > "$KC/intelligence/agents/quoted.md"
printf '%s\n' '---' 'name: closed' 'access: "runner" # note' "tier: 'light' # x" 'effort: run#1' '---' \
    > "$KC/intelligence/agents/closed.md"
printf '%s\r\n' '---' 'name: bare' 'access: # to be decided' '---' > "$KC/intelligence/agents/bare.md"
printf '%s\n' '---' 'name: cfork' 'context: fork # runs alone' 'agent: noted' 'model: haiku # cheap' '---' \
    > "$KC/intelligence/skills/cfork/SKILL.md"
printf '%s\n' '---' 'name: eff' 'effort: hiigh # a typo' 'tier: # none' '---' > "$KC/intelligence/skills/eff/SKILL.md"
IS_SOURCE_FILES_MEMO=0 source_catalog_build "$KC" "$KC/intelligence.yaml" lint 2> "$OUT/keyword-comment.err"
chk eq "$(cat "$OUT/keyword-comment.err")" "$(printf 'WARNING: %s\n' \
    'intelligence/agents/closed.md:5 effort "run#1" is not one of low, medium, high, xhigh, max, ultra — ignored, so no tool receives an effort from this file' \
    'intelligence/agents/quoted.md:3 access "runner # not a comment" is not one of full, readonly, runner — every tool renders it as full access' \
    'intelligence/skills/eff/SKILL.md:3 effort "hiigh" is not one of low, medium, high, xhigh, max, ultra — ignored, so no tool receives an effort from this file')"
KA="$KC/intelligence/agents"
chk eq "$(frontmatter_index 'tier,access,effort,description' "$KA/noted.md" "$KA/quoted.md" "$KA/closed.md" "$KA/bare.md")" \
    "$(printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$KA/noted.md" light runner high 'Noted # kept' \
        "$KA/quoted.md" '' 'runner # not a comment' '' '' "$KA/closed.md" light runner 'run#1' '' "$KA/bare.md" '' '' '' '')"
chk eq "$(get_frontmatter_value access "$KA/noted.md")|$(get_frontmatter_value tier "$KA/closed.md")" "runner|light"
chk eq "$(get_frontmatter_value description "$KA/noted.md")" "Noted # kept"
# disable-model-invocation is a keyword too: a skill whose `true` carries a
# comment still gets the Codex policy that keeps the model from selecting it.
mkdir -p "$KC/open/owner"
printf '%s\n' '---' 'name: owner' 'disable-model-invocation: true # owner only' '---' 'Body' > "$KC/open/owner/SKILL.md"
chk eq "$(frontmatter_index 'disable-model-invocation' "$KC/open/owner/SKILL.md")" "$KC/open/owner/SKILL.md"$'\x1f'"true"
open_skill_invocation_policies "$KC/open"
chk grep -Fqx '  allow_implicit_invocation: false' "$KC/open/owner/agents/openai.yaml"

echo "== word budgets: the authoring rule and the audit name the numbers the engine holds =="
budget() { local k; for k in $IS_WORD_BUDGETS; do [ "${k%%=*}" != "$1" ] || printf '%s' "${k#*=}"; done; }
AUTH="$REPO/packages/sync/rules/intelligence-authoring.md"
AUDIT="$REPO/packages/sync/skills/intelligence-review-context/references/audit-checks.md"
# The Size table, one `<label> <words>` line per row.
size_table="$(awk -F'|' '/^\| Type \| Budget \|/ { t = 1; next } t && !/^\|/ { exit }
    t && !/^\|---/ { l = $2; v = $3; gsub(/^ +| +$/, "", l); gsub(/[^0-9]/, "", v); print l " " v }' "$AUTH")"
chk eq "$size_table" "$(printf '%s\n' "Rule $(budget rule)" "Agent $(budget agent)" "\`SKILL.md\` $(budget skill)" \
    "Paragraph, list item or table row $(budget paragraph)")"
r7_row="$(grep -F '(`R7`)' "$AUDIT" | tr -d ',')"
for want in "\`SKILL.md\` over $(budget skill) words" "rule over $(budget rule)" "agent over $(budget agent)" \
    "table row over $(budget paragraph)"; do
    chk grep -Fq "$want" <<< "$r7_row"
done

echo "== word budgets: sync counts a project source as the audit does, never a package one =="
WB="$OUT/word-budgets"
words() { local i out=""; for ((i = $1; i <= $2; i++)); do out+="w$i "; done; printf '%s' "${out% }"; }
for dir in intelligence .intelligence/packages/@a/b; do
    mkdir -p "$WB/$dir/rules" "$WB/$dir/agents" "$WB/$dir/skills/long"
    # 2,001 words in paragraphs of 100.
    { printf -- '---\ndescription: Long\n---\n'
      for ((p = 0; p < 20; p++)); do printf '%s\n\n' "$(words $((p * 100 + 1)) $((p * 100 + 100)))"; done
      printf 'one\n'; } > "$WB/$dir/rules/long.md"
    # Exactly 2,000 words, and a paragraph of exactly 150: a heading starts one.
    { printf -- '# Even\n%s\n\n' "$(words 1 148)"
      for ((p = 0; p < 18; p++)); do printf '%s\n\n' "$(words 1 100)"; done
      printf '%s\n' "$(words 1 50)"; } > "$WB/$dir/rules/even.md"
    # 501 words, 200 of them in a code block, which belongs to no paragraph.
    { printf -- '---\nname: long\ndescription: Long\n---\n'
      printf '%s\n\n%s\n\n%s\n\n```text\n%s\n```\n' "$(words 1 100)" "$(words 1 100)" "$(words 1 101)" "$(words 1 198)"; } \
        > "$WB/$dir/agents/long.md"
    # A list item of 151 words, its marker included, continued on a second line.
    printf -- '---\nname: long\ndescription: Long item\n---\n\nIntro.\n\n- %s\n  %s\n- short item\n' \
        "$(words 1 100)" "$(words 101 150)" > "$WB/$dir/skills/long/SKILL.md"
done
while IFS= read -r line; do printf '%s\r\n' "$line"; done < "$WB/intelligence/rules/long.md" > "$WB/intelligence/rules/long-crlf.md"
printf 'sources:\n  rules:\n    - ".intelligence/packages/@a/b/rules"\n    - "intelligence/rules"\n  agents:\n    - ".intelligence/packages/@a/b/agents"\n    - "intelligence/agents"\n  skills:\n    - ".intelligence/packages/@a/b/skills"\n    - "intelligence/skills"\n' \
    > "$WB/intelligence.yaml"
IS_SOURCE_FILES_MEMO=0 source_catalog_build "$WB" "$WB/intelligence.yaml" lint 2> "$OUT/word-budgets.err"
chk eq "$(cat "$OUT/word-budgets.err")" "$(printf 'WARNING: %s\n' \
    'intelligence/rules/long-crlf.md is 2001 words, over the rule budget of 2000' \
    'intelligence/rules/long.md is 2001 words, over the rule budget of 2000' \
    'intelligence/agents/long.md is 501 words, over the agent budget of 500' \
    'intelligence/skills/long/SKILL.md:8 has a 151-word paragraph, over the budget of 150')"
# The numbers are the audit's own count, run as the audit runs it.
r7_prog="$(awk -v start="awk -v f=\"\$f\" '" -v stop="' \"\$f\"" '
    !p && (i = index($0, start)) { p = 1; $0 = substr($0, i + length(start)) }
    p && (i = index($0, stop)) { print substr($0, 1, i - 1); exit }
    p { print }' "$AUDIT")"
r7() { awk -v f="$1" "$r7_prog" "$1" | awk '{ print $1 " " $2 }'; }
chk eq "$(r7 "$WB/intelligence/rules/long.md")" "2001 100"
chk eq "$(r7 "$WB/intelligence/rules/even.md")" "2000 150"
chk eq "$(r7 "$WB/intelligence/agents/long.md")" "501 101"
chk eq "$(r7 "$WB/intelligence/skills/long/SKILL.md")" "155 151"
# The audit counts a CRLF file as the engine does: a blank line ends a paragraph.
sed 's/$/\r/' "$WB/intelligence/rules/long.md" > "$OUT/long-crlf.md"
chk eq "$(r7 "$OUT/long-crlf.md")" "2001 100"
# The form without a repository root lints no file as a project source.
chk eq "$(lint_frontmatter_files "$WB/intelligence/rules/long.md" "$WB/intelligence/skills/long/SKILL.md" 2>&1)" ""

echo "== layout tokens: one row in IS_LAYOUT_TOKENS reaches expansion, every escape and the lint =="
# A copy of the library whose only change is a probe row in the declaration:
# whatever still names the tokens itself leaves <probe> behind somewhere.
P="$OUT/probe-token"
mkdir -p "$P/lib" "$P/intelligence/rules"
awk -v row="    'probe IS_PROBE PROBE_VALUE'" '
    $0 == "IS_LAYOUT_TOKENS=(" { decl = 1 }
    decl && $0 == ")" { print row; decl = 0 }
    { print }
' "$REPO/engine/lib/common.sh" > "$P/lib/common.sh"
chk eq "$(diff "$REPO/engine/lib/common.sh" "$P/lib/common.sh" | grep '^[<>]' || :)" \
    ">     'probe IS_PROBE PROBE_VALUE'"
printf '%s\n' 'see <probe>, \<probe> and <probe>_x in <content-dir>' > "$P/intelligence/rules/probe.md"
printf '%s\n' '---' 'description: uses \<probe> and <probe>' '---' > "$P/quoted-src.md"
(
    # shellcheck source=/dev/null
    source "$P/lib/common.sh"
    unset IS_PROBE IS_CONTENT_REL
    cp "$P/intelligence/rules/probe.md" "$P/plain.md"
    finalize_output_file "$P/plain.md"
    printf '%s\n' '<probe>' > "$P/env.md"
    IS_PROBE=elsewhere finalize_output_file "$P/env.md"
    yaml_dq_escape_var 'uses \<probe>, \\<probe> and <probe>'
    printf 'description: "%s"\n' "$IS_YAML_ESCAPED" > "$P/yaml.md"
    toml_escape_var 'uses \<probe> and <probe>'
    printf 'description = "%s"\n' "$IS_TOML_ESCAPED" > "$P/toml.md"
    copy_md_with_quoted_frontmatter "$P/quoted-src.md" "$P/quoted.md"
    finalize_output_files "$P/yaml.md" "$P/toml.md" "$P/quoted.md"
    source_frontmatter_scan "$P" "$P/intelligence/rules/probe.md" 2> "$P/warnings" >/dev/null
)
chk grep -Fqx 'see PROBE_VALUE, <probe> and PROBE_VALUE_x in intelligence' "$P/plain.md"
chk grep -Fqx 'elsewhere' "$P/env.md"
chk grep -Fqx 'description: "uses <probe>, \\<probe> and PROBE_VALUE"' "$P/yaml.md"
chk grep -Fqx 'description = "uses <probe> and PROBE_VALUE"' "$P/toml.md"
chk grep -Fqx 'description: "uses <probe> and PROBE_VALUE"' "$P/quoted.md"
chk eq "$(cat "$P/warnings")" \
    'WARNING: intelligence/rules/probe.md:1 <probe> is part of the text around it, but sync renders this layout token as PROBE_VALUE; write \<probe> to keep it as written'

echo "== layout tokens: <package-dir> renders as the root of the package an artifact came from =="
# A package artifact gets its own package root, a project artifact the content
# directory, in every helper that renders an artifact: copied rules, skill
# bundles with their bundled files, rule bodies inlined into one shared file
# and the frontmatter values read for one.
PD="$OUT/package-dir"
PKG="$PD/.intelligence/packages/@acme/core"
ROOT=.intelligence/packages/@acme/core
mkdir -p "$PKG/rules" "$PKG/skills/do/references" "$PD/intelligence/rules" \
    "$PD/intelligence/skills/mine/references" "$PD/out/rules"
printf -- '---\ndescription: "Read <package-dir>/references/a.md"\n---\nSee <package-dir>/references/a.md, \\<package-dir> and <module>.\n' \
    > "$PKG/rules/pkg.md"
printf -- '---\ndescription: "Read <package-dir>/a.md"\n---\nSee <package-dir>/a.md, \\<package-dir> and <module>.\n' \
    > "$PD/intelligence/rules/own.md"
printf 'Old <module>, <content-dir>, \\<module>, <manifest> and <sync-cmd>.\n' > "$PKG/rules/old.md"
printf -- '---\nname: do\ndescription: Uses <package-dir>/x\n---\nBody <package-dir>/references/r.md\n' > "$PKG/skills/do/SKILL.md"
printf 'Ref <package-dir>/y and \\<package-dir>\n' > "$PKG/skills/do/references/r.md"
printf -- '---\nname: mine\n---\nMine <package-dir>\n' > "$PD/intelligence/skills/mine/SKILL.md"
printf 'Mine ref <package-dir>\n' > "$PD/intelligence/skills/mine/references/n.md"
(
    export IS_CONTENT_REL=brain IS_MODULE_REL=.intelligence/packages/@s/sync
    finalize_copy_named "$PD/out/rules" "" "$PKG/rules/pkg.md" "$PD/intelligence/rules/own.md" "$PKG/rules/old.md"
    copy_skill_bundle_dirs_for open "$PD/out/skills" "$PKG/skills/do" "$PD/intelligence/skills/mine"
    copy_skill_bundle "$PKG/skills/do" "$PD/out/single/do"
    emit_rule_bodies "$PKG/rules/pkg.md" "$PD/intelligence/rules/own.md" > "$PD/out/shared.md"
    finalize_output_file "$PD/out/shared.md"
    frontmatter_index description "$PKG/rules/pkg.md" "$PD/intelligence/rules/own.md" > "$PD/out/index"
    # Each wrapped file is written once the next source has started, and an
    # empty source only at the end.
    : > "$PKG/rules/empty.md"
    printf 'Second <package-dir>\n' > "$PD/intelligence/rules/second.md"
    emit_wrapped_bodies "$(printf '%s\x1f%s\x1fstrip\x1f0\x1fnone\x1f\x1eHEAD <package-dir>\x1f\n' \
        "$PKG/rules/pkg.md" "$PD/out/w1.md" "$PD/intelligence/rules/own.md" "$PD/out/w2.md" \
        "$PKG/rules/old.md" "$PD/out/w3.md" "$PD/intelligence/rules/second.md" "$PD/out/w4.md" \
        "$PKG/rules/empty.md" "$PD/out/w5.md")"
    # The single-file readers a project adapter renders with.
    get_frontmatter_value description "$PKG/rules/pkg.md" > "$PD/out/value"
    strip_frontmatter "$PKG/rules/pkg.md" > "$PD/out/body"
    copy_md_with_quoted_frontmatter "$PKG/skills/do/SKILL.md" "$PD/out/quoted.md"
    finalize_output_file "$PD/out/quoted.md"
)
chk eq "$(cat "$PD/out/rules/pkg.md")" "$(printf '%s\n' '---' "description: \"Read $ROOT/references/a.md\"" '---' \
    "See $ROOT/references/a.md, <package-dir> and .intelligence/packages/@s/sync.")"
chk eq "$(cat "$PD/out/rules/own.md")" "$(printf '%s\n' '---' 'description: "Read brain/a.md"' '---' \
    'See brain/a.md, <package-dir> and .intelligence/packages/@s/sync.')"
# The other tokens render as they always did, wherever the artifact lives.
chk eq "$(cat "$PD/out/rules/old.md")" 'Old .intelligence/packages/@s/sync, brain, <module>, intelligence.yaml and intelligence sync.'
for tree in skills single; do
    chk grep -Fqx "description: \"Uses $ROOT/x\"" "$PD/out/$tree/do/SKILL.md"
    chk grep -Fqx "Body $ROOT/references/r.md" "$PD/out/$tree/do/SKILL.md"
    chk eq "$(cat "$PD/out/$tree/do/references/r.md")" "Ref $ROOT/y and <package-dir>"
done
chk grep -Fqx 'Mine brain' "$PD/out/skills/mine/SKILL.md"
chk eq "$(cat "$PD/out/skills/mine/references/n.md")" 'Mine ref brain'
chk grep -Fqx "See $ROOT/references/a.md, <package-dir> and .intelligence/packages/@s/sync." "$PD/out/shared.md"
chk grep -Fqx 'See brain/a.md, <package-dir> and .intelligence/packages/@s/sync.' "$PD/out/shared.md"
# A value read for a file several artifacts share arrives expanded for a
# package artifact, and keeps the token for the content directory otherwise.
chk eq "$(cat "$PD/out/index")" "$(printf '%s\x1f%s\n' "$PKG/rules/pkg.md" "Read $ROOT/references/a.md" \
    "$PD/intelligence/rules/own.md" 'Read <package-dir>/a.md')"
chk eq "$(cat "$PD/out/w1.md")" "$(printf '%s\n' "HEAD $ROOT" "See $ROOT/references/a.md, <package-dir> and .intelligence/packages/@s/sync.")"
chk eq "$(cat "$PD/out/w2.md")" "$(printf '%s\n' 'HEAD brain' 'See brain/a.md, <package-dir> and .intelligence/packages/@s/sync.')"
chk grep -Fqx "HEAD $ROOT" "$PD/out/w3.md"
chk eq "$(cat "$PD/out/w4.md")" "$(printf '%s\n' 'HEAD brain' 'Second brain')"
chk eq "$(cat "$PD/out/w5.md")" "HEAD $ROOT"
chk eq "$(cat "$PD/out/value")" "Read $ROOT/references/a.md"
chk eq "$(cat "$PD/out/body")" "See $ROOT/references/a.md, \\<package-dir> and <module>."
chk grep -Fqx "description: \"Uses $ROOT/x\"" "$PD/out/quoted.md"
# Joined to the text around it in a project source, it warns like the others,
# naming the value it renders as there; a package source is never read.
printf 'Joined x<package-dir> and <package-dir>/ok and \\<package-dir>_kept\n' > "$PD/intelligence/rules/joined.md"
cp "$PD/intelligence/rules/joined.md" "$PKG/rules/joined.md"
warnings="$(IS_CONTENT_REL=brain source_frontmatter_scan "$PD" "$PD/intelligence/rules/joined.md" "$PKG/rules/joined.md" 2>&1 >/dev/null)"
chk eq "$warnings" \
    'WARNING: intelligence/rules/joined.md:1 <package-dir> is part of the text around it, but sync renders this layout token as brain; write \<package-dir> to keep it as written'

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
# A comment after the level is no part of it: the copy reads as the level alone.
mkdir -p "$K/src/noted"
printf '%s\n' '---' 'name: noted' 'effort: ultra # the deepest' '---' > "$K/src/noted/SKILL.md"
for tool in claude open copilot; do copy_skill_bundle_dirs_for "$tool" "$K/noted-$tool" "$K/src/noted"; done
chk eq "$(skill_fm "$K/noted-claude/noted/SKILL.md")" "effort: max"
chk eq "$(skill_fm "$K/noted-open/noted/SKILL.md")" "effort: ultra"
chk eq "$(skill_fm "$K/noted-copilot/noted/SKILL.md")" ""

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

echo "== skill_source_inventory: links inside the source render, loops end, failures stop =="
# Decision 0017. Two directories linked into each other must copy once and stop;
# a linked SKILL.md renders as a regular file; a link that cannot be resolved
# stops the run instead of shortening the list. Probed, like every symlink case.
K="$OUT/links"
mkdir -p "$K/s/_shared/cyc-a" "$K/s/_shared/cyc-b" "$K/s/real" "$K/bin"
printf 'sources:\n  skills:\n    - "s/"\n' > "$K/intelligence.yaml"
if ln -s ../cyc-b "$K/s/_shared/cyc-a/x" 2>/dev/null && [ -L "$K/s/_shared/cyc-a/x" ]; then
    ln -s ../cyc-a "$K/s/_shared/cyc-b/y"
    printf -- '---\nname: cyc\n---\n' > "$K/s/_shared/cyc-a/SKILL.md"
    printf 'B_MARKER\n' > "$K/s/_shared/cyc-b/b.txt"
    ln -s _shared/cyc-a "$K/s/cyc"
    printf -- '---\nname: real\ndescription: Real: colon\n---\n' > "$K/s/_shared/real.md"
    ln -s ../_shared/real.md "$K/s/real/SKILL.md"
    IS_SOURCE_FILES_MEMO=0 read_source_artifact_files "$K" "$K/intelligence.yaml" skills 2> "$K/warnings"
    chk eq "${IS_SOURCE_FILES[*]}" "$K/s/cyc/SKILL.md $K/s/real/SKILL.md"
    chk eq "$(cat "$K/warnings")" "WARNING: skill 'cyc' renders without x/y: s/_shared/cyc-b/y is a symlink to a directory that encloses it"
    chk skill_source_rendered "$K/s//cyc/"
    chk eval '! skill_source_rendered "$K/s/_shared"'
    copy_skill_bundle_dirs "$K/out" "$K/s/cyc/" "$K/s/real" 2> "$K/copy-warnings"
    chk eq "$(find "$K/out" -type l)" ""
    chk eq "$(cat "$K/copy-warnings")" ""
    chk grep -Fqx 'B_MARKER' "$K/out/cyc/x/b.txt"
    chk eq "$(find "$K/out/cyc" | LC_ALL=C sort | sed "s#^$K/out/##" | tr '\n' ' ')" "cyc cyc/SKILL.md cyc/x cyc/x/b.txt "
    chk grep -Fqx 'description: "Real: colon"' "$K/out/real/SKILL.md"
    chk eq "$(find "$K/s" -type l | wc -l | tr -d ' ')" 4
    # A readlink that fails, or answers with more lines than links, refuses.
    for fake in 'exit 1' 'printf "a\nb\n"'; do
        printf '#!/bin/sh\n%s\n' "$fake" > "$K/bin/readlink"
        chmod +x "$K/bin/readlink"
        rc=0
        (PATH="$K/bin:$PATH"; IS_SOURCE_FILES_MEMO=0 read_source_artifact_files "$K" "$K/intelligence.yaml" skills) \
            > /dev/null 2> "$K/refusal" || rc=$?
        chk eq "$rc" 1
        chk grep -Fq "cannot resolve the symlinks under '$K/s'" "$K/refusal"
    done
else
    echo "  NOTE: this host cannot create a symlink — skill source links not exercised"
fi

echo "== source_artifact_name_var: the name rule and locality (decision 0021) =="
while IFS=' ' read -r section entry name local; do
    source_artifact_name_var "$section" "$entry"
    eq "$IS_ART_NAME/$IS_ART_LOCAL" "$name/$local" \
        || { echo "FAIL: $section $entry: got $IS_ART_NAME/$IS_ART_LOCAL want $name/$local"; fail=1; }
done <<'EOF'
rules team.md team 0
rules .draft.md draft 0
rules environment.local.md environment 1
rules .environment.local.md environment 1
rules .local.md local 1
rules local.md local 0
rules x.local.local.md x.local 1
agents helper.local.md helper 1
agents .helper.md helper 0
skills deploy deploy 0
skills deploy.local deploy 1
skills .deploy deploy 0
skills .local local 1
skills notes.md notes.md 0
EOF

echo "== policy_pattern_covers: contract ignore patterns as Git reads them =="
while IFS=' ' read -r pattern path want; do
    got=0
    policy_pattern_covers "$pattern" "$path" || got=1
    eq "$got" "$want" || { echo "FAIL: $pattern covers $path: got $got want $want"; fail=1; }
done <<'EOF'
.claude/* .claude/rules/x.md 0
.claude/* .claude 1
.agents/skills/ .agents/skills/deploy 0
.agents/skills/ .agents/skillset/x 1
.codex/agents/ .codex/agents/helper.toml 0
.pi/prompts/intelligence-agent-*.md .pi/prompts/intelligence-agent-helper.md 0
.pi/prompts/intelligence-agent-*.md .pi/prompts/mine.md 1
./.github/agents/ .github/agents/helper.agent.md 0
CLAUDE.md CLAUDE.md 0
.claude/settings.json .claude/settings.json 0
EOF

echo "== source catalog: overrides, refusals and local membership =="
chknot() { if "$@" >/dev/null 2>&1; then echo "FAIL(not): $*"; fail=1; fi; }
S="$OUT/catalog"
mkdir -p "$S/a/rules" "$S/b/rules" "$S/b/agents" "$S/b/skills/deploy.local" "$S/b/skills/review"
printf 'sources:\n  rules:\n    - "a/rules"\n    - "b/rules"\n  agents:\n    - "b/agents"\n  skills:\n    - "b/skills"\n' > "$S/intelligence.yaml"
printf 'shared style\n' > "$S/a/rules/style.md"
printf 'project style\n' > "$S/b/rules/style.md"
printf -- '---\npaths:\n  - "src/**"\n---\n' > "$S/b/rules/.scoped.md"
printf 'mine\n' > "$S/b/rules/me.local.md"
printf -- '---\nname: x\n---\n' > "$S/b/agents/x.local.md"
printf -- '---\nname: deploy\n---\n' > "$S/b/skills/deploy.local/SKILL.md"
printf -- '---\nname: review\n---\n' > "$S/b/skills/review/SKILL.md"
IS_SOURCE_FILES_MEMO=0 source_catalog_build "$S" "$S/intelligence.yaml" 2> "$OUT/catalog.err"
chk eq "$(cat "$OUT/catalog.err")" ""
chk eq "$IS_CAT_NEED_COMMITTED" 1
# The later style hides the earlier one, but both are the project's own: a
# project directory overriding another is reported nowhere.
IS_SOURCE_FILES_MEMO=0 source_catalog_overrides_var "$S" "$S/intelligence.yaml"
chk eq "$IS_CAT_OVERRIDE_N" 0
chk eq "$IS_CAT_OVERRIDES" ""
# A copy in the package store is reported, whichever source hides it, and the
# row names only the store copies: style hides one package's copy and a project
# one, lint one package's under another's. A package hiding a project copy
# (edge) is not reported. A skill is named by its directory.
K=".intelligence/packages/@acme"
mkdir -p "$S/$K/one/rules" "$S/$K/two/rules" "$S/$K/one/skills/review"
printf 'package style\n' > "$S/$K/one/rules/style.md"
printf 'package lint\n' > "$S/$K/one/rules/lint.md"
printf 'later package lint\n' > "$S/$K/two/rules/lint.md"
printf 'package edge\n' > "$S/$K/two/rules/edge.md"
printf 'project edge\n' > "$S/a/rules/edge.md"
printf -- '---\nname: review\n---\n' > "$S/$K/one/skills/review/SKILL.md"
printf 'sources:\n  rules:\n    - "%s/one/rules"\n    - "a/rules"\n    - "%s/two/rules"\n    - "b/rules"\n  skills:\n    - "%s/one/skills"\n    - "b/skills"\n' \
    "$K" "$K" "$K" > "$S/store.yaml"
IS_SOURCE_FILES_MEMO=0 source_catalog_overrides_var "$S" "$S/store.yaml"
chk eq "$IS_CAT_OVERRIDE_N" 3
US=$'\x1f'
chk eq "$IS_CAT_OVERRIDES" "rule${US}lint${US}$K/two/rules/lint.md${US}$K/one/rules/lint.md"$'\n'"rule${US}style${US}b/rules/style.md${US}$K/one/rules/style.md"$'\n'"skill${US}review${US}b/skills/review${US}$K/one/skills/review"$'\n'
# One store directory listed again hides nothing of its own.
printf 'sources:\n  rules:\n    - "%s/one/rules"\n    - "%s/one/rules/"\n' "$K" "$K" > "$S/store-twice.yaml"
IS_SOURCE_FILES_MEMO=0 source_catalog_overrides_var "$S" "$S/store-twice.yaml"
chk eq "$IS_CAT_OVERRIDE_N" 0
chk eq "$IS_CAT_OVERRIDES" ""
# The count is of hidden store copies, not of names: lint hides two.
printf 'project lint\n' > "$S/b/rules/lint.md"
printf 'sources:\n  rules:\n    - "%s/one/rules"\n    - "%s/two/rules"\n    - "b/rules"\n' "$K" "$K" > "$S/store-chain.yaml"
IS_SOURCE_FILES_MEMO=0 source_catalog_overrides_var "$S" "$S/store-chain.yaml"
chk eq "$IS_CAT_OVERRIDE_N" 3
chk eq "$IS_CAT_OVERRIDES" "rule${US}lint${US}b/rules/lint.md${US}$K/one/rules/lint.md${US}$K/two/rules/lint.md"$'\n'"rule${US}style${US}b/rules/style.md${US}$K/one/rules/style.md"$'\n'
# A store path that sources: spells with a leading ./ is still the store.
printf 'sources:\n  rules:\n    - "./%s/one/rules"\n    - "./b/rules"\n' "$K" > "$S/store-dot.yaml"
IS_SOURCE_FILES_MEMO=0 source_catalog_overrides_var "$S" "$S/store-dot.yaml"
chk eq "$IS_CAT_OVERRIDE_N" 2
chk eq "$IS_CAT_OVERRIDES" "rule${US}lint${US}b/rules/lint.md${US}$K/one/rules/lint.md"$'\n'"rule${US}style${US}b/rules/style.md${US}$K/one/rules/style.md"$'\n'
rm -r "$S/.intelligence" "$S/a/rules/edge.md" "$S/b/rules/lint.md"
# A render that would need Git policy without the engine having read it stops.
rc=0
(IS_SOURCE_FILES_MEMO=0 source_artifacts_var "$S" "$S/intelligence.yaml" rules claude ".claude/rules/{}.md") \
    > /dev/null 2>&1 || rc=$?
chk eq "$rc" 1
# shellcheck disable=SC2034  # read by output_committed
IS_COMMIT_POLICY=$'claude\tignore\t.claude/*\nclaude\tinclude\t.claude/settings.json\ncodex\tignore\t.codex/agents/\n'
# shellcheck disable=SC2034
IS_COMMIT_POLICY_SET=1
# Sources in manifest order, entries in byte order; the later style wins.
IS_SOURCE_FILES_MEMO=0 source_artifacts_var "$S" "$S/intelligence.yaml" rules claude ".claude/rules/{}.md"
chk eq "${IS_SOURCE_NAMES[*]}" "scoped me style"
chk eq "${IS_SOURCE_FILES[*]}" "$S/b/rules/.scoped.md $S/b/rules/me.local.md $S/b/rules/style.md"
chk eq "${IS_SOURCE_SCOPED[*]}" "1 0 0"
chk eq "${IS_SOURCE_IN_AGENTS[*]}" "1 0 1"
source_name_map_var "$IS_SOURCE_NAME_MAP" "$S/b/rules/me.local.md"
chk eq "$IS_MAPPED_NAME" "me"
# AGENTS.md is always committed; an output no contract ignores is too.
IS_SOURCE_FILES_MEMO=0 source_artifacts_var "$S" "$S/intelligence.yaml" rules agents "AGENTS.md"
chk eq "${IS_SOURCE_NAMES[*]}" "scoped style"
IS_SOURCE_FILES_MEMO=0 source_artifacts_var "$S" "$S/intelligence.yaml" agents opencode ".opencode/commands/{}.md"
chk eq "${#IS_SOURCE_FILES[@]}" 0
IS_SOURCE_FILES_MEMO=0 source_artifacts_var "$S" "$S/intelligence.yaml" agents codex ".codex/agents/{}.toml"
chk eq "${IS_SOURCE_NAMES[*]}" "x"
# One of several readers is enough; a skill is keyed by its directory.
IS_SOURCE_FILES_MEMO=0 source_artifacts_var "$S" "$S/intelligence.yaml" skills "opencode codex" ".codex/agents/{}"
chk eq "${IS_SOURCE_NAMES[*]}" "deploy review"
source_name_map_var "$IS_SOURCE_NAME_MAP" "$S/b/skills/deploy.local"
chk eq "$IS_MAPPED_NAME" "deploy"
copy_skill_bundle_dirs_named open "$OUT/catalog-out" "$IS_SOURCE_NAME_MAP" "$S/b/skills/deploy.local/" "$S/b/skills/review"
chk test -f "$OUT/catalog-out/deploy/SKILL.md"
chk test -f "$OUT/catalog-out/review/SKILL.md"
chknot test -e "$OUT/catalog-out/deploy.local"
finalize_copy_named "$OUT/catalog-out" $'\n'"$S/b/rules/me.local.md"$'\x1f'"me"$'\n' "$S/b/rules/me.local.md" "$S/b/rules/style.md"
chk test -f "$OUT/catalog-out/me.md"
chk test -f "$OUT/catalog-out/style.md"
unset IS_COMMIT_POLICY IS_COMMIT_POLICY_SET
# Two of one name in one directory, and a local beside a committed one,
# refuse and name both files.
printf 'dot style\n' > "$S/b/rules/.style.md"
rc=0
(IS_SOURCE_FILES_MEMO=0 source_catalog_build "$S" "$S/intelligence.yaml") > /dev/null 2> "$OUT/catalog.err" || rc=$?
chk eq "$rc" 1
chk grep -Fq "b/rules/.style.md and b/rules/style.md are both the rule 'style' in one directory" "$OUT/catalog.err"
rm "$S/b/rules/.style.md"
printf 'local style\n' > "$S/b/rules/style.local.md"
rm "$S/b/rules/style.md"
rc=0
(IS_SOURCE_FILES_MEMO=0 source_catalog_build "$S" "$S/intelligence.yaml") > /dev/null 2> "$OUT/catalog.err" || rc=$?
chk eq "$rc" 1
chk grep -Fq "a/rules/style.md and b/rules/style.local.md are both the rule 'style', one local and one not" "$OUT/catalog.err"
rm "$S/b/rules/style.local.md"
# One directory listed twice is one artifact, not a conflict.
printf 'sources:\n  rules:\n    - "a/rules"\n    - "a/rules/"\n' > "$S/twice.yaml"
IS_SOURCE_FILES_MEMO=0 source_catalog_winners_var "$S" "$S/twice.yaml" rules
chk eq "${#IS_SOURCE_FILES[@]}" 1
IS_SOURCE_FILES_MEMO=0 source_catalog_overrides_var "$S" "$S/twice.yaml"
chk eq "$IS_CAT_OVERRIDE_N" 0
chk eq "$IS_CAT_OVERRIDES" ""

echo "== source_frontmatter_scan: targets and exclude_targets in the list syntax paths: takes =="
T="$OUT/targets"
mkdir -p "$T"
# <name> <frontmatter lines, \n-separated> <expected: has_t|t|has_x|x>
tcase() {
    printf -- '---\n%b\n---\ntargets: [body-is-not-frontmatter]\n' "$2" > "$T/$1.md"
    printf '%s\n' "$1|$3" >> "$T/want"
}
: > "$T/want"
tcase flow 'targets: [claude, cursor]' '1|claude cursor|0|'
tcase quoted 'targets: ["claude", '"'"'codex'"'"']' '1|claude codex|0|'
tcase block 'targets:\n  - claude\n  - "pi"\ndescription: x' '1|claude pi|0|'
tcase unindented 'targets:\n- claude\n- "pi"\nexclude_targets:\n- codex\ndescription: x' '1|claude pi|1|codex'
tcase empty 'targets: []' '1||0|'
tcase null 'targets:\ndescription: x' '0||0|'
tcase scalar 'targets: claude # only Claude' '1|claude|0|'
tcase multiline 'targets: [claude,\n  cursor]\nexclude_targets: [committed]' '1|claude cursor|1|committed'
tcase first 'exclude_targets: [pi]\nexclude_targets: [codex]' '0||1|pi'
tcase indented 'meta:\n  targets: [claude]' '0||0|'
printf -- '---\r\ntargets:\r\n  - codex\r\npaths:\r\n  - "src/**"\r\n---\r\n' > "$T/crlf.md"
printf '%s\n' 'crlf|1|codex|0|' >> "$T/want"
printf 'targets: [claude]\n' > "$T/nofm.md"
printf '%s\n' 'nofm|0||0|' >> "$T/want"
while IFS='|' read -r name has_t t has_x x; do
    row="$(source_frontmatter_scan "" "$T/$name.md")"
    IFS=$'\x1f' read -r _path _scoped got_ht got_t got_hx got_x <<< "$row"
    eq "$got_ht|$got_t|$got_hx|$got_x" "$has_t|$t|$has_x|$x" \
        || { echo "FAIL: targets scan $name: got [$got_ht|$got_t|$got_hx|$got_x] want [$has_t|$t|$has_x|$x]"; fail=1; }
done < "$T/want"
IFS=$'\x1f' read -r _path scoped _rest <<< "$(source_frontmatter_scan "" "$T/crlf.md")"
chk eq "$scoped" 1

echo "== rendered copies drop targets and exclude_targets, from the frontmatter only =="
printf -- '---\ndescription: x\ntargets:\n  - claude\n  - cursor\nexclude_targets: [pi,\n  codex]\npaths:\n  - "src/**"\n---\ntargets: [kept in the body]\n' > "$T/strip.md"
finalize_copy_named "$OUT" "" "$T/strip.md"
chk eq "$(cat "$OUT/strip.md")" "$(printf -- '---\ndescription: x\npaths:\n  - "src/**"\n---\ntargets: [kept in the body]')"
# A block list at its key's own indent goes with the key too.
printf -- '---\ntargets:\n- claude\n- cursor\npaths:\n- "src/**"\n---\n- a body item\n' > "$T/strip-flat.md"
finalize_copy_named "$OUT" "" "$T/strip-flat.md"
chk eq "$(cat "$OUT/strip-flat.md")" "$(printf -- '---\npaths:\n- "src/**"\n---\n- a body item')"

echo "== rule bodies: only a --- on line 1 opens frontmatter =="
# A rule without frontmatter that shows a YAML header in a code fence keeps
# every line in AGENTS.md, Codex's override and Copilot's always-on channel.
RB="$OUT/rule-bodies"
mkdir -p "$RB"
printf '%s\n' '# Wiki pages' '' '```yaml' '---' 'concern: wiki-page' '---' '```' 'After the block' > "$RB/nofm.md"
printf '%s\n' '---' 'description: x' '---' 'Body' '---' 'kept' '---' > "$RB/fm.md"
printf '%s\n' 'Agent text' '---' 'between' '---' 'after the pair' > "$RB/agent.md"
chk eq "$(emit_rule_bodies "$RB/nofm.md" "$RB/fm.md")" \
    "$(printf '%s\n' '# Wiki pages' '' '```yaml' '---' 'concern: wiki-page' '---' '```' 'After the block' '' 'Body' '---' 'kept' '---')"
wrap_rec() { printf '%s\x1f%s\x1f%s\x1f0\x1fnone\x1f%s\x1f\n' "$RB/$1.md" "$RB/$1.out" "$2" "${3:-}"; }
emit_wrapped_bodies "$(wrap_rec nofm fence_nofm)"$'\n'"$(wrap_rec fm fence_nofm)"$'\n'"$(wrap_rec agent fence $'\x1e'HEAD)"
chk eq "$(cat "$RB/nofm.out")" "$(cat "$RB/nofm.md")"
chk eq "$(cat "$RB/fm.out")" "$(printf '%s\n' 'Body' '---' 'kept' '---')"
# A `fence` source (an agent) without frontmatter still yields only its wrapper.
chk eq "$(cat "$RB/agent.out")" "HEAD"

echo "== source catalog: targets, exclusions and the committed group =="
G="$OUT/grouped"
mkdir -p "$G/rules"
printf 'sources:\n  rules:\n    - "rules"\n' > "$G/intelligence.yaml"
printf -- '---\ntargets: [claude]\n---\n' > "$G/rules/only-claude.md"
printf -- '---\nexclude_targets: [agents]\n---\n' > "$G/rules/not-agents.md"
printf -- '---\ntargets: [committed]\n---\n' > "$G/rules/tracked.md"
printf -- '---\nexclude_targets: [committed]\n---\n' > "$G/rules/ignored.md"
printf -- '---\ntargets: []\n---\n' > "$G/rules/nowhere.md"
printf 'plain\n' > "$G/rules/plain.md"
IS_SOURCE_FILES_MEMO=0 source_catalog_build "$G" "$G/intelligence.yaml"
chk eq "$IS_CAT_NEED_COMMITTED" 1
# shellcheck disable=SC2034  # read by output_committed
IS_COMMIT_POLICY=$'claude\tignore\t.claude/*\nopencode\tignore\t.opencode/agents/\n'
# shellcheck disable=SC2034
IS_COMMIT_POLICY_SET=1
names_for() {
    IS_SOURCE_FILES_MEMO=0 source_artifacts_var "$G" "$G/intelligence.yaml" rules "$1" "$2"
    printf '%s' "${IS_SOURCE_NAMES[*]}"
}
chk eq "$(names_for claude '.claude/rules/{}.md')" "ignored not-agents only-claude plain"
chk eq "$(names_for agents 'AGENTS.md')" "plain tracked"
chk eq "$(names_for opencode '.opencode/commands/{}.md')" "not-agents plain tracked"
chk eq "$(names_for opencode '.opencode/agents/{}.md')" "ignored not-agents plain"
IS_SOURCE_FILES_MEMO=0 source_artifacts_var "$G" "$G/intelligence.yaml" rules claude '.claude/rules/{}.md'
chk eq "${IS_SOURCE_IN_AGENTS[*]}" "0 0 0 1"
# An id no adapter has refuses; `committed` is always known.
printf -- '---\ntargets: [cursr, committed]\n---\n' > "$G/rules/typo.md"
IS_SOURCE_FILES_MEMO=0 source_catalog_build "$G" "$G/intelligence.yaml"
rc=0
source_catalog_check_ids "$G" "agents claude cursor" 2> "$OUT/ids.err" || rc=$?
chk eq "$rc" 1
chk eq "$(cat "$OUT/ids.err")" "ERROR: rules/typo.md: targets names 'cursr', which is no adapter — use one of: agents, claude, cursor, or the group committed"
rm "$G/rules/typo.md"
# A local artifact may not name a committed output in its targets.
printf -- '---\ntargets: [claude]\n---\n' > "$G/rules/fine.local.md"
printf -- '---\ntargets: [agents]\n---\n' > "$G/rules/bad.local.md"
IS_SOURCE_FILES_MEMO=0 source_catalog_build "$G" "$G/intelligence.yaml"
# shellcheck disable=SC2034  # read by source_catalog_check_local
IS_ENABLED_ADAPTERS="agents claude"
# shellcheck disable=SC2034
IS_ADAPTER_CLAIMS=$'agents\towned\tAGENTS.md\nclaude\towned\t.claude/rules\n'
rc=0
source_catalog_check_local "$G" 2> "$OUT/local.err" || rc=$?
chk eq "$rc" 1
chk grep -Fq "rules/bad.local.md is local, but its targets name agents, whose output Git tracks" "$OUT/local.err"
chknot grep -Fq "fine.local.md" "$OUT/local.err"
unset IS_COMMIT_POLICY IS_COMMIT_POLICY_SET IS_ENABLED_ADAPTERS IS_ADAPTER_CLAIMS

echo "== compact paths display preserves scope syntax, never rule bodies =="
F="$OUT/paths-display"
mkdir -p "$F"
printf -- '---\npaths:\n  - "src with spaces/**"\n  - "src/{one,two}/**"\ndescription: scope\n---\npaths: [body-only]\n' > "$F/block.md"
printf -- '---\npaths:\n- "src/**"\n- "tests/**"\ndescription: scope\n---\n' > "$F/indentless.md"
printf -- '---\r\npaths: ["*.ts", "src/{one,two}/**"]\r\ndescription: scope\r\n---\r\n' > "$F/inline.md"
printf -- '---\npaths: [\n  "one/**",\n  "two/**"\n]\npaths: [ignored-duplicate]\n---\n' > "$F/multiline.md"
printf -- '---\npaths: []\n---\n' > "$F/empty.md"
printf 'paths: [body-only]\n' > "$F/body.md"
rows="$(frontmatter_index 'paths[],description' "$F/block.md" "$F/inline.md" "$F/multiline.md" "$F/empty.md" "$F/body.md")"
chk eq "$(frontmatter_index 'paths[]' "$F/block.md")" "$F/block.md"$'\x1f''"src with spaces/**" "src/{one,two}/**"'
chk eq "$(frontmatter_index 'paths[],description' "$F/indentless.md")" "$F/indentless.md"$'\x1f''"src/**" "tests/**"'$'\x1f''scope'
chk eq "$(frontmatter_index 'paths[]' "$F/inline.md")" "$F/inline.md"$'\x1f''["*.ts", "src/{one,two}/**"]'
chk eq "$(frontmatter_index 'paths[]' "$F/multiline.md")" "$F/multiline.md"$'\x1f''[ "one/**", "two/**" ]'
chk eq "$(frontmatter_index 'paths[]' "$F/empty.md")" "$F/empty.md"$'\x1f''[]'
chk eq "$(frontmatter_index 'paths[]' "$F/body.md")" "$F/body.md"$'\x1f'
chknot grep -Fq body-only <<< "$rows"
chknot grep -Fq ignored-duplicate <<< "$rows"

echo "== a scoped rule's patterns: one reader for every paths: shape =="
# `paths*` is every pattern of the first paths list, unquoted and
# \x1d-separated, read in the same pass as the display above: a block list at
# either indent, one holding a comment line or a trailing comment, a flow list
# on one line or several, and a single value.
GS=$'\x1d'
printf -- '---\npaths:\n  - "a/**"\n  # a note\n  - b/** # trailing\n  - '"'"'c d/**'"'"'\n---\n' > "$F/commented.md"
printf -- '---\npaths: [\n  "x,y/**",  # one\n  z/**\n] # done\n---\n' > "$F/flow-comment.md"
printf -- '---\npaths: "solo/**" # one\n---\n' > "$F/scalar.md"
chk eq "$(frontmatter_index 'paths*' "$F/block.md")" "$F/block.md"$'\x1f'"src with spaces/**${GS}src/{one,two}/**"
chk eq "$(frontmatter_index 'paths*,description' "$F/indentless.md")" "$F/indentless.md"$'\x1f'"src/**${GS}tests/**"$'\x1f''scope'
chk eq "$(frontmatter_index 'paths*' "$F/inline.md")" "$F/inline.md"$'\x1f'"*.ts${GS}src/{one,two}/**"
chk eq "$(frontmatter_index 'paths*' "$F/multiline.md")" "$F/multiline.md"$'\x1f'"one/**${GS}two/**"
chk eq "$(frontmatter_index 'paths*' "$F/commented.md")" "$F/commented.md"$'\x1f'"a/**${GS}b/**${GS}c d/**"
chk eq "$(frontmatter_index 'paths*' "$F/flow-comment.md")" "$F/flow-comment.md"$'\x1f'"x,y/**${GS}z/**"
chk eq "$(frontmatter_index 'paths*' "$F/scalar.md")" "$F/scalar.md"$'\x1f'"solo/**"
chk eq "$(frontmatter_index 'paths*' "$F/empty.md")" "$F/empty.md"$'\x1f'
chk eq "$(frontmatter_index 'paths*' "$F/body.md")" "$F/body.md"$'\x1f'
chk eq "$(frontmatter_index 'paths[],paths*' "$F/inline.md")" "$F/inline.md"$'\x1f''["*.ts", "src/{one,two}/**"]'$'\x1f'"*.ts${GS}src/{one,two}/**"
# The display Codex routes with drops each comment and keeps the quotes.
chk eq "$(frontmatter_index 'paths[]' "$F/commented.md")" "$F/commented.md"$'\x1f'"\"a/**\" b/** 'c d/**'"
chk eq "$(frontmatter_index 'paths[]' "$F/flow-comment.md")" "$F/flow-comment.md"$'\x1f''[ "x,y/**", z/** ]'
chk eq "$(frontmatter_index 'paths[]' "$F/scalar.md")" "$F/scalar.md"$'\x1f''"solo/**"'

echo "== the unwired-source walk never enters what ignore: and submodules: list =="
# A working temp folder can hold a whole checkout of the project: the walk has
# to leave it out, not walk it and drop the results.
W="$OUT/walk"
for d in intelligence/rules docs/intelligence/rules Temp/copy/intelligence/rules \
    apps/tmp/intelligence/rules .tmp/intelligence/rules apps/web/build/intelligence/agents \
    libs/sdk/intelligence/rules keep/build/intelligence/rules; do
    mkdir -p "$W/$d"
    printf 'x\n' > "$W/$d/r.md"
done
cat > "$W/intelligence.yaml" <<'EOF'
sources:
  rules:
    - "intelligence/rules"
ignore:
  - "Temp/**"
  - "tmp"
  - "./.tmp/"
  - "apps/web/build"
submodules:
  - "libs/sdk"
EOF
mkdir -p "$OUT/walk-bin"
REAL_FIND="$(command -v find)"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s"\nexec "%s" "$@"\n' "$OUT/walk-find.args" "$REAL_FIND" > "$OUT/walk-bin/find"
chmod +x "$OUT/walk-bin/find"
walk_out="$(PATH="$OUT/walk-bin:$PATH" IS_CLI=1 IS_CONTENT_REL=intelligence warn_unsynced "$W" "$W/intelligence.yaml" 2>&1 >/dev/null)"
chk eq "$(grep 'NOT SYNCED' <<< "$walk_out" | sort | paste -sd, -)" \
    "WARNING: NOT SYNCED: docs/intelligence/rules,WARNING: NOT SYNCED: keep/build/intelligence/rules"
# Each entry reaches find as a prune: a name as -name, a path as a suffix.
for want in Temp tmp .tmp '*/apps/web/build' '*/libs/sdk'; do
    chk grep -Fxq -- "$want" "$OUT/walk-find.args"
done
chknot_walk() { ! grep -Fxq -- "$1" "$OUT/walk-find.args"; }
chk chknot_walk 'Temp/**'

echo "== source name map: one split per batch, the names the pattern lookup gave =="
# The lookup source_name_map_names_var replaced: right for any map, but each
# path cost time quadratic in the map's length.
oracle_name_map() {
    local rest
    case "$1" in *$'\n'"$2"$'\x1f'*) ;; *) return 1 ;; esac
    rest="${1#*$'\n'"$2"$'\x1f'}"
    printf '%s' "${rest%%$'\n'*}"
}
nm_map=$'\n'
for entry in "/r/a b/skills/x"$'\x1f'x "/r/[x]*/skills/y?"$'\x1f'y \
    "/r/skills/deploy.local"$'\x1f'deploy "/r/é/skills/ü"$'\x1f'ü \
    "/r/skills/x"$'\x1f'x "/r/skills/x2"$'\x1f'x2; do
    nm_map+="$entry"$'\n'
done
nm_paths=("/r/a b/skills/x" "/r/[x]*/skills/y?" "/r/skills/deploy.local" "/r/é/skills/ü"
    "/r/skills/x" "/r/skills/x2" "/r/skills/deploy.local" "/r/skills" "/r/skills/x2/" "/r/a b/skills/x")
source_name_map_names_var "$nm_map" "${nm_paths[@]}"
chk eq "${#IS_MAPPED_NAMES[@]}" "${#nm_paths[@]}"
for ((i = 0; i < ${#nm_paths[@]}; i++)); do
    want="$(oracle_name_map "$nm_map" "${nm_paths[i]}" || true)"
    chk eq "${IS_MAPPED_NAMES[i]}" "$want"
done
chk source_name_map_var "$nm_map" "/r/skills/deploy.local"
chk eq "$IS_MAPPED_NAME" deploy
chknot source_name_map_var "$nm_map" "/r/skills"
source_name_map_names_var "" "/r/skills/x"
chk eq "${#IS_MAPPED_NAMES[@]}:${IS_MAPPED_NAMES[0]}" "1:"
# A map of 600 skills used to take minutes; a split costs one pass.
nm_map=$'\n'
nm_paths=()
for ((i = 0; i < 600; i++)); do
    nm_paths+=("/repo/.intelligence/packages/@scope/pack-$i/skills/skill-$i")
    nm_map+="${nm_paths[i]}"$'\x1f'"skill-$i"$'\n'
done
SECONDS=0
source_name_map_names_var "$nm_map" "${nm_paths[@]}"
chk test "$SECONDS" -le 10
chk eq "${IS_MAPPED_NAMES[0]}:${IS_MAPPED_NAMES[599]}" "skill-0:skill-599"

[ "$fail" -eq 0 ] && echo "ENGINE-UNIT: ALL OK"
exit "$fail"
