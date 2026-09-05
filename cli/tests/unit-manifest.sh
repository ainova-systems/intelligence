#!/bin/bash
# Unit suite for cli/lib/manifest.sh (the quoted-key qmap parser/editors) and
# cli/lib/lockfile.sh (top_scalar + the \x1f-separated lock round-trip).
set -euo pipefail
REPO="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
fail=0
chk() { if ! "$@" >/dev/null 2>&1; then echo "FAIL: $*"; fail=1; fi; }
chknot() { if "$@" >/dev/null 2>&1; then echo "FAIL(not): $*"; fail=1; fi; }

export CLI_DIR="$REPO/cli"
export IS_ENGINE_DIR="$REPO/engine"
# shellcheck source=/dev/null
source "$CLI_DIR/lib/cli-common.sh"

SEP=$'\x1f'
eq() { [ "$1" = "$2" ]; }
# die() exits, so every die-path runs in a subshell.
name_ok() { ( assert_valid_pkg_name "$1" ); }
has_key() { qmap_keys "$1" "$2" | grep -qxF -- "$3"; }
# row_is <lock> <name> <field-no> <want> — assert one column of one TSV row.
row_is() {
    lock_to_tsv "$1" | awk -F"$SEP" -v n="$2" -v f="$3" -v want="$4" \
        '$1 == n { if ($f == want) ok = 1 } END { exit !ok }'
}
tsv_fields_ok() { lock_to_tsv "$1" | awk -F"$SEP" 'NF != 6 { bad = 1 } END { exit bad }'; }
# section_has <file> <section> <text> — text appears inside sources.<section>.
section_has() {
    awk -v sec="$2" '
        { sub(/\r$/, "") }
        /^sources:[ \t]*$/ { ins = 1; next }
        ins && /^[^ #]/ { ins = 0; f = 0 }
        ins && $0 ~ "^  " sec ":[ \t]*$" { f = 1; next }
        ins && /^  [A-Za-z_]/ { f = 0 }
        f { print }
    ' "$1" | grep -qF -- "$3"
}

echo "== qmap_keys / qmap_field / qmap_value =="
M1="$OUT/m1.yaml"
cat > "$M1" <<'EOF'
# reader fixture
project:
  name: unit

packages:
  "@acme/one":
    version: "^1.0.0"
    url: "https://github.com/acme/one.git"
    path: skills # store subdir
  "@acme/two":
    url: "git+file:///tmp/pack.git"
    version: 2.0.0 # unquoted

registries:
  "@acme": "https://registry.example/acme/index.yaml"
  "@beta": beta-unquoted # comment

other:
  "@ghost": "nope"
EOF
chk eq "$(qmap_keys "$M1" packages | tr '\n' ',')" "@acme/one,@acme/two,"
chk eq "$(qmap_keys "$M1" registries | tr '\n' ',')" "@acme,@beta,"
chknot has_key "$M1" registries "@ghost"    # block ends at the next top-level key
chknot has_key "$M1" packages "@acme"       # other blocks are ignored
chk eq "$(qmap_keys "$M1" other | tr '\n' ',')" "@ghost,"
: > "$OUT/empty.yaml"
chk eq "$(qmap_keys "$OUT/empty.yaml" packages)" ""
chk qmap_keys "$OUT/absent.yaml" packages   # missing file: rc 0, no output
chk eq "$(qmap_keys "$OUT/absent.yaml" packages)" ""

chk eq "$(qmap_field "$M1" packages "@acme/one" version)" "^1.0.0"
chk eq "$(qmap_field "$M1" packages "@acme/one" url)" "https://github.com/acme/one.git"
chk eq "$(qmap_field "$M1" packages "@acme/one" path)" "skills"
chk eq "$(qmap_field "$M1" packages "@acme/two" url)" "git+file:///tmp/pack.git"
chk eq "$(qmap_field "$M1" packages "@acme/two" version)" "2.0.0"
chk eq "$(qmap_field "$M1" packages "@acme/one" sha)" ""
chk eq "$(qmap_field "$M1" packages "@acme/none" url)" ""

chk eq "$(qmap_value "$M1" registries "@acme")" "https://registry.example/acme/index.yaml"
chk eq "$(qmap_value "$M1" registries "@beta")" "beta-unquoted"
chk eq "$(qmap_value "$M1" registries "@none")" ""
chk eq "$(qmap_value "$M1" other "@ghost")" "nope"

echo "== qmap_set =="
M2A="$OUT/m2a.yaml"
cat > "$M2A" <<'EOF'
project:
  name: unit

packages:
  "@acme/one":
    version: "^1.0.0"

targets:
  agents: { enabled: true }
EOF
qmap_set "$M2A" packages "@acme/one" url "https://h/one.git"
chk eq "$(qmap_field "$M2A" packages "@acme/one" url)" "https://h/one.git"
chk eq "$(qmap_field "$M2A" packages "@acme/one" version)" "^1.0.0"
qmap_set "$M2A" packages "@acme/new" version "0.1.0"
chk eq "$(qmap_keys "$M2A" packages | tr '\n' ',')" "@acme/one,@acme/new,"
chk eq "$(qmap_field "$M2A" packages "@acme/new" version)" "0.1.0"
chk eq "$(qmap_field "$M2A" packages "@acme/one" version)" "^1.0.0"

M2C="$OUT/m2c.yaml"
printf 'project:\n  name: unit\n' > "$M2C"
qmap_set "$M2C" packages "@acme/one" url "file:///p"
chk eq "$(qmap_field "$M2C" packages "@acme/one" url)" "file:///p"
chk eq "$(grep -c '^packages:' "$M2C")" "1"

# Replace-in-place must preserve every untouched byte (comments, blank
# lines, siblings) — assert the full file, then assert idempotency.
M2B="$OUT/m2b.yaml"
cat > "$M2B" <<'EOF'
# header comment
project:
  name: unit  # inline comment

packages:
  "@acme/one":
    version: "^1.0.0"
    url: "https://h/one.git"
  "@acme/two":
    version: "3.3.3"

# trailing comment
end: "yes"
EOF
cat > "$OUT/m2b.expect" <<'EOF'
# header comment
project:
  name: unit  # inline comment

packages:
  "@acme/one":
    version: "^2.0.0"
    url: "https://h/one.git"
  "@acme/two":
    version: "3.3.3"

# trailing comment
end: "yes"
EOF
qmap_set "$M2B" packages "@acme/one" version "^2.0.0"
chk diff "$OUT/m2b.expect" "$M2B"
chk eq "$(qmap_field "$M2B" packages "@acme/two" version)" "3.3.3"
cp "$M2B" "$OUT/m2b.once"
qmap_set "$M2B" packages "@acme/one" version "^2.0.0"
chk diff "$OUT/m2b.once" "$M2B"

echo "== qmap_set_value =="
M3="$OUT/m3.yaml"
cat > "$M3" <<'EOF'
project:
  name: unit

registries:
  "@acme": "https://old.example/idx.yaml"
EOF
qmap_set_value "$M3" registries "@acme" "https://new.example/idx.yaml"
chk eq "$(qmap_value "$M3" registries "@acme")" "https://new.example/idx.yaml"
chk eq "$(grep -c '"@acme":' "$M3")" "1"
qmap_set_value "$M3" registries "@beta" "file:///b"
chk eq "$(qmap_value "$M3" registries "@beta")" "file:///b"
chk eq "$(qmap_value "$M3" registries "@acme")" "https://new.example/idx.yaml"

M3B="$OUT/m3b.yaml"
printf 'project:\n  name: unit\n' > "$M3B"
qmap_set_value "$M3B" registries "@acme" "https://x/idx.yaml"
chk eq "$(grep -c '^registries:' "$M3B")" "1"
chk eq "$(qmap_value "$M3B" registries "@acme")" "https://x/idx.yaml"

echo "== qmap_delete_key =="
M4="$OUT/m4.yaml"
cat > "$M4" <<'EOF'
packages:
  "@acme/one":
    version: "^1.0.0"
    url: "https://h/one.git"
  "@acme/two":
    version: "2.0.0"

registries:
  "@acme": "https://x/idx.yaml"
EOF
qmap_delete_key "$M4" packages "@acme/one"
chknot has_key "$M4" packages "@acme/one"
chknot grep -q 'https://h/one.git' "$M4"     # 4-indent fields went with the key
chk eq "$(qmap_field "$M4" packages "@acme/two" version)" "2.0.0"
chk eq "$(grep -c '^packages:' "$M4")" "1"   # block header stays
qmap_delete_key "$M4" registries "@acme"     # flat single-line form
chk eq "$(qmap_value "$M4" registries "@acme")" ""
chk eq "$(grep -c '^registries:' "$M4")" "1"
cp "$M4" "$OUT/m4.before"
qmap_delete_key "$M4" packages "@acme/none"  # nonexistent key: no-op
chk diff "$OUT/m4.before" "$M4"

echo "== qmap_delete_field =="
M4F="$OUT/m4-field.yaml"
cat > "$M4F" <<'EOF'
packages:
  "@acme/one":
    version: "^1.0.0"
    url: "https://h/one.git"
    path: "skills"
  "@acme/two":
    ref: "main"
EOF
qmap_delete_field "$M4F" packages "@acme/one" url
qmap_delete_field "$M4F" packages "@acme/one" path
chk eq "$(qmap_field "$M4F" packages "@acme/one" version)" "^1.0.0"
chk eq "$(qmap_field "$M4F" packages "@acme/one" url)" ""
chk eq "$(qmap_field "$M4F" packages "@acme/one" path)" ""
chk eq "$(qmap_field "$M4F" packages "@acme/two" ref)" "main"
cp "$M4F" "$OUT/m4-field.once"
qmap_delete_field "$M4F" packages "@acme/one" url
chk diff "$OUT/m4-field.once" "$M4F"

echo "== sources_remove_entry =="
M5="$OUT/m5.yaml"
cat > "$M5" <<'EOF'
project:
  name: unit

sources:
  rules:
    - "intelligence/rules"
    - ".intelligence/packages/@acme/x/rules"
  skills:
    - ".intelligence/packages/@acme/x/rules"
    - .intelligence/packages/@acme/x/skills

targets:
  agents: { enabled: true }
EOF
chk section_has "$M5" skills ".intelligence/packages/@acme/x/skills"
sources_remove_entry "$M5" rules ".intelligence/packages/@acme/x/rules"
chknot section_has "$M5" rules "@acme/x/rules"
chk section_has "$M5" skills "@acme/x/rules"   # identical entry elsewhere untouched
chk section_has "$M5" rules "intelligence/rules"
chk eq "$(grep -c '@acme/x/rules' "$M5")" "1"
sources_remove_entry "$M5" skills ".intelligence/packages/@acme/x/skills"
chknot section_has "$M5" skills "@acme/x/skills"   # unquoted entry form
chk section_has "$M5" skills "@acme/x/rules"

echo "== assert_valid_pkg_name =="
chk name_ok "@scope/name"
chk name_ok "@a.b/c-d_e"
chknot name_ok "scope/name"
chknot name_ok "@scopeonly"
chknot name_ok "@a/b/c"
chknot name_ok "@a/b c"
chknot name_ok "@a/b:c"

echo "== target manifest editors =="
target_name_ok() { ( assert_valid_target_name "$1" ); }
chk target_name_ok "myide"
chk target_name_ok "tool_2"
chknot target_name_ok "MyIDE"
chknot target_name_ok "my-ide"
chknot target_name_ok "../tool"

MT="$OUT/targets.yaml"
cat > "$MT" <<'EOF'
project:
  name: target-unit

targets:
  agents:
    enabled: true
    output: "AGENTS.md"
    header: |
      # Intelligence

      Keep this header paragraph after its blank line.
  claude:
    enabled: false
    # preserve this field while toggling enabled
    output: ".custom-claude"
  codex: { enabled: true, output: ".codex", warn_project_doc_limit: false }

# Package examples follow the generated target list.
# packages:
#   "@acme/core":
#     version: "^1.0.0"
models:
  claude:
    heavy: opus
EOF
chk target_exists "$MT" agents
chk target_exists "$MT" claude
chknot target_exists "$MT" cursor
target_set_enabled "$MT" agents false "AGENTS.md"
chk eq "$(is_target_enabled "$MT" agents)" "0"
chk eq "$(get_target_output "$MT" agents)" "AGENTS.md"
chk eq "$(agents_output_path "")" ".agents/AGENTS.md"
chk eq "$(agents_output_path "docs/")" "docs/AGENTS.md"
chk eq "$(agents_output_path "CUSTOM.md")" "CUSTOM.md"
target_set_enabled "$MT" claude true ".claude"
chk eq "$(is_target_enabled "$MT" claude)" "1"
chk eq "$(get_target_output "$MT" claude)" ".custom-claude"
chk grep -q 'output: ".custom-claude"' "$MT"
chk eq "$(get_target_field "$MT" codex warn_project_doc_limit)" "false"
chk eq "$(get_target_field "$MT" claude output)" ".custom-claude"
target_set_enabled "$MT" codex false ".codex"
chk grep -q '^  codex: { enabled: false, output: ".codex", warn_project_doc_limit: false }$' "$MT"
target_set_enabled "$MT" cursor true ".cursor"
chk target_exists "$MT" cursor
chk eq "$(is_target_enabled "$MT" cursor)" "1"
chk eq "$(get_target_output "$MT" cursor)" ".cursor"
chk eq "$(grep -c '^targets:' "$MT")" "1"
chk grep -q '^models:' "$MT"
if ! awk '
    /Keep this header paragraph/ { header=NR }
    /^  cursor:/ { target=NR }
    /^# Package examples/ { comment=NR }
    END { exit !(header && target > header && comment > target) }
' "$MT"; then
    echo "FAIL: missing target did not preserve the preceding block scalar"
    fail=1
fi

MT_DEFAULT="$OUT/targets-default.yaml"
cat > "$MT_DEFAULT" <<'EOF'
targets:
  agents: { enabled: true }
  codex: { enabled: true, output: ".codex" }
other:
  nested:
    output: "must-not-leak"
EOF
chk eq "$(get_target_output "$MT_DEFAULT" agents)" ""
load_targets_cache "$MT_DEFAULT"
target_output_var "$MT_DEFAULT" agents
chk eq "$IS_TGT_OUTPUT" ""
chk eq "$(agents_output_path "$IS_TGT_OUTPUT")" ".agents/AGENTS.md"
cp "$MT" "$OUT/targets.once"
target_set_enabled "$MT" cursor true ".cursor"
chk diff "$OUT/targets.once" "$MT"

MT2="$OUT/no-targets.yaml"
printf 'project:\n  name: none\n' > "$MT2"
target_set_enabled "$MT2" agents true "AGENTS.md"
chk target_exists "$MT2" agents
chk eq "$(is_target_enabled "$MT2" agents)" "1"
chk eq "$(get_target_output "$MT2" agents)" "AGENTS.md"

echo "== top_scalar =="
M6="$OUT/m6.yaml"
cat > "$M6" <<'EOF'
lockfile_version: 1
engine_version: "9.9.9"
note: hello world  # trailing
EOF
chk eq "$(top_scalar "$M6" engine_version)" "9.9.9"
chk eq "$(top_scalar "$M6" lockfile_version)" "1"
chk eq "$(top_scalar "$M6" note)" "hello world"
chk eq "$(top_scalar "$M6" absent)" ""

echo "== lockfile round-trip =="
LOCK="$OUT/intelligence.lock"
# @acme/one has an EMPTY path — the middle column must survive round-trips
# without shifting the columns after it.
lock_upsert "$LOCK" "@acme/one" "^1.0.0" "https://h/one.git" "" "v1.2.0" "aaa111"
lock_upsert "$LOCK" "@acme/two" "~2.0.0" "https://h/two.git" "skills" "v2.0.3" "bbb222"
chk test -f "$LOCK"
chk eq "$(top_scalar "$LOCK" lockfile_version)" "1"
chk eq "$(top_scalar "$LOCK" engine_version)" "$(bundled_engine_version)"
chk eq "$(lock_to_tsv "$LOCK" | grep -c .)" "2"
chk tsv_fields_ok "$LOCK"
chk row_is "$LOCK" "@acme/one" 4 ""
chk row_is "$LOCK" "@acme/one" 5 "v1.2.0"
chk row_is "$LOCK" "@acme/one" 6 "aaa111"
chk row_is "$LOCK" "@acme/two" 4 "skills"
chk eq "$(qmap_field "$LOCK" packages "@acme/one" url)" "https://h/one.git"
chk eq "$(qmap_field "$LOCK" packages "@acme/one" resolved)" "v1.2.0"
chk eq "$(qmap_field "$LOCK" packages "@acme/one" sha)" "aaa111"
chk eq "$(qmap_field "$LOCK" packages "@acme/one" path)" ""
chk eq "$(qmap_field "$LOCK" packages "@acme/two" sha)" "bbb222"

# Full write -> read cycle reproduces the row stream exactly.
lock_to_tsv "$LOCK" > "$OUT/rows1.tsv"
lock_write_from_tsv "$OUT/lock2" "$OUT/rows1.tsv"
lock_to_tsv "$OUT/lock2" > "$OUT/rows2.tsv"
chk diff "$OUT/rows1.tsv" "$OUT/rows2.tsv"

lock_upsert "$LOCK" "@acme/one" "^1.0.0" "https://h/one.git" "" "v1.3.0" "ccc333"
chk eq "$(grep -c '"@acme/one"' "$LOCK")" "1"   # replaced, not duplicated
chk eq "$(qmap_field "$LOCK" packages "@acme/one" sha)" "ccc333"
chk eq "$(lock_to_tsv "$LOCK" | grep -c .)" "2"

lock_remove "$LOCK" "@acme/one"
chk eq "$(qmap_keys "$LOCK" packages | tr '\n' ',')" "@acme/two,"
chk eq "$(qmap_field "$LOCK" packages "@acme/two" sha)" "bbb222"
lock_remove "$LOCK" "@acme/two"
chknot test -f "$LOCK"                          # last removal deletes the file
chk lock_remove "$OUT/absent.lock" "@x/y"       # missing lock: rc 0

echo "== lock validation: generated shape and complete identity =="
VALID_LOCK="$OUT/valid.lock"
SHA40=0123456789012345678901234567890123456789
SHA64="${SHA40}012345678901234567890123"
lock_upsert "$VALID_LOCK" "@acme/one" "^1.0.0" "https://h/one.git" "" "v1.2.0" "$SHA40"
lock_upsert "$VALID_LOCK" "@acme/two" "" "git@host:repo.git" "skills/team" "main" "$SHA64"
chk lock_validate "$VALID_LOCK"
chk lock_validate "$VALID_LOCK" --restore
cp "$VALID_LOCK" "$OUT/valid-before.lock"
chk lock_validate "$VALID_LOCK"
chk cmp -s "$VALID_LOCK" "$OUT/valid-before.lock"
# Accepted scalar metadata is additive; CRLF and comments do not change identity.
awk '{ print } /^    url:/ { print "    note: metadata # comment" } END { print "extension: \"informational\"" }' \
    "$VALID_LOCK" | awk '{ printf "%s\r\n", $0 }' > "$OUT/extended.lock"
chk lock_validate "$OUT/extended.lock"
awk '{ gsub(/"/, ""); if ($0 ~ /^  @/) sub(/^  /, "  \""); if ($0 ~ /^  "@/) sub(/:$/, "\":"); print }' \
    "$VALID_LOCK" > "$OUT/plain.lock"
chk lock_validate "$OUT/plain.lock"

# Each malformed document must be refused, including entries the forgiving
# field readers would otherwise skip or interpret using only the first value.
for defect in version missing-version engine missing-engine no-packages inline-map \
    unquoted-name empty-name duplicate-name duplicate-field duplicate-top \
    missing-url missing-ref bad-sha missing-sha absolute-path parent-path drive-path \
    backslash-path option-ref option-url missing-quote trailing-scalar list-scalar \
    block-scalar null-scalar orphan-field bad-indent control; do
    awk -v defect="$defect" '
        defect == "version" && /^lockfile_version:/ { print "lockfile_version: 2"; next }
        defect == "missing-version" && /^lockfile_version:/ { next }
        defect == "engine" && /^engine_version:/ { print "engine_version: \"banana\""; next }
        defect == "missing-engine" && /^engine_version:/ { next }
        defect == "no-packages" && /^packages:/ { next }
        defect == "inline-map" && /^packages:/ { print "packages: {}"; next }
        defect == "unquoted-name" && /^  "@acme\/one"/ { print "  @acme/one:"; next }
        defect == "empty-name" && /^  "@acme\/one"/ { print "  \"\":"; next }
        defect == "duplicate-name" && /^  "@acme\/two"/ { print "  \"@acme/one\":"; next }
        defect == "duplicate-field" && /^    url:/ { print }
        defect == "duplicate-top" && /^lockfile_version:/ { print }
        defect == "missing-url" && /^    url:/ { next }
        defect == "missing-ref" && /^    resolved:/ { next }
        defect == "bad-sha" && /^    sha:/ { print "    sha: \"not-a-commit\""; next }
        defect == "missing-sha" && /^    sha:/ { next }
        defect == "absolute-path" && /^    path:/ { print "    path: \"/tmp/outside\""; next }
        defect == "parent-path" && /^    path:/ { print "    path: \"../outside\""; next }
        defect == "drive-path" && /^    path:/ { print "    path: \"C:/outside\""; next }
        defect == "backslash-path" && /^    path:/ { print "    path: \"..\\outside\""; next }
        defect == "option-ref" && /^    resolved:/ { print "    resolved: \"--help\""; next }
        defect == "option-url" && /^    url:/ { print "    url: \"--help\""; next }
        defect == "missing-quote" && /^    resolved:/ { print "    resolved: \"main"; next }
        defect == "trailing-scalar" && /^    resolved:/ { print "    resolved: \"main\" other"; next }
        defect == "list-scalar" && /^    resolved:/ { print "    resolved: [main]"; next }
        defect == "block-scalar" && /^    resolved:/ { print "    resolved: |"; next }
        defect == "null-scalar" && /^    resolved:/ { print "    resolved: null"; next }
        defect == "orphan-field" && /^packages:/ { print; print "    url: \"https://host/repo\""; next }
        defect == "bad-indent" && /^    url:/ { sub(/^    /, "   ") }
        defect == "control" && /^    resolved:/ { printf "    resolved: \"main%cother\"\n", 31; next }
        { print }
    ' "$VALID_LOCK" > "$OUT/$defect.lock"
    chknot lock_validate "$OUT/$defect.lock"
done
chknot lock_validate "$OUT/no-such.lock"
mkdir "$OUT/directory.lock"
chknot lock_validate "$OUT/directory.lock"

echo "== bundle metadata exception does not authorize a cross-version restore =="
BUNDLE_LOCK="$OUT/bundle.lock"
lock_upsert "$BUNDLE_LOCK" "$SYNC_PKG_NAME" "$(bundled_engine_version)" \
    "$SYNC_PKG_URL" "$SYNC_PKG_PATH" "v$(bundled_engine_version)" ""
chk lock_validate "$BUNDLE_LOCK" --restore
awk '/^engine_version:/ { print "engine_version: \"0.0.1\""; next }
    /^    resolved:/ { print "    resolved: \"v0.0.1\""; next } { print }' \
    "$BUNDLE_LOCK" > "$OUT/older-bundle.lock"
chk lock_validate "$OUT/older-bundle.lock"
chknot lock_validate "$OUT/older-bundle.lock" --restore
awk '/^engine_version:/ { print "engine_version: \"0.0.2\""; next } { print }' \
    "$OUT/older-bundle.lock" > "$OUT/rewritten-bundle.lock"
chk lock_validate "$OUT/rewritten-bundle.lock"
chknot lock_validate "$OUT/rewritten-bundle.lock" --restore
for field in url path resolved; do
    awk -v field="$field" '$0 ~ "^    " field ":" { print "    " field ": \"wrong\""; next } { print }' \
        "$BUNDLE_LOCK" > "$OUT/mismatched-bundle.lock"
    chknot lock_validate "$OUT/mismatched-bundle.lock"
done

echo "== pkg-name segment guards (names become rm -rf paths) =="
for bad in "@scope/" "@/x" "@a/.." "@../x" "@a/." "@./x"; do
    if ( assert_valid_pkg_name "$bad" ) >/dev/null 2>&1; then
        echo "FAIL: accepted dangerous name '$bad'"; fail=1
    fi
done

echo "== sources_add_entry_first: package entries precede project entries =="
SRC="$OUT/src-order.yaml"
printf 'sources:\n  rules:\n    - "intelligence/rules"\n' > "$SRC"
sources_add_entry_first "$SRC" "rules" ".intelligence/packages/@a/p/rules"
chk grep -q '.intelligence/packages/@a/p/rules' "$SRC"
first_entry="$(grep -m1 '^    - ' "$SRC")"
[ "$first_entry" = '    - ".intelligence/packages/@a/p/rules"' ] || { echo "FAIL: package entry is not first: $first_entry"; fail=1; }
sources_add_entry_first "$SRC" "rules" ".intelligence/packages/@a/p/rules"
n="$(grep -c '@a/p/rules' "$SRC")"
[ "$n" = "1" ] || { echo "FAIL: sources_add_entry_first not idempotent ($n entries)"; fail=1; }
sources_add_entry_first "$SRC" "skills" ".intelligence/packages/@a/p/skills"
chk grep -q '  skills:' "$SRC"

[ "$fail" -eq 0 ] && echo "CLI-UNIT-MANIFEST: ALL OK"
exit "$fail"
