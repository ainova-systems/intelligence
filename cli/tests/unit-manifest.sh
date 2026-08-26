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
