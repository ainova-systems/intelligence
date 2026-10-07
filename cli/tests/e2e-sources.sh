#!/bin/bash
# Hermetic e2e for `intelligence source add|remove|list`: placement inside the
# ordered sources: block, the refusals the engine cannot report, and the render
# that proves a wired directory actually reaches the output.
set -euo pipefail
unset CI
REPO="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
REPO="$(cd "$REPO" && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
CLI="$REPO/cli/intelligence"
fail=0
chk() { if ! "$@" >/dev/null 2>&1; then echo "FAIL: $*"; fail=1; fi; }
chknot() { if "$@" >/dev/null 2>&1; then echo "FAIL(not): $*"; fail=1; fi; }
# is <label> <want> <got>
is() { [ "$2" = "$3" ] || { echo "FAIL: $1 — want '$2', got '$3'"; fail=1; }; }

PROJ="$OUT/proj"
mkdir -p "$PROJ/intelligence/rules" "$PROJ/backend/intelligence/rules" \
    "$PROJ/packs/local/rules" "$PROJ/shared/prompts"
ENGINE_VER="$(tr -d ' \t\r\n' < "$REPO/engine/VERSION")"
cat > "$PROJ/intelligence.yaml" <<EOF
project:
  name: e2e-sources

schema_version: "$ENGINE_VER"

sources:
  rules:
    - "intelligence/rules"
  agents:
  skills:

targets:
  agents: { enabled: true, output: "AGENTS.md" }
EOF
printf '# Root\n\nROOT_MARKER\n' > "$PROJ/intelligence/rules/root.md"
printf '# Backend\n\nBACKEND_MARKER\n' > "$PROJ/backend/intelligence/rules/backend.md"
printf '# Local pack\n\nPACK_MARKER\n' > "$PROJ/packs/local/rules/pack.md"
printf '# Shared\n\nSHARED_MARKER\n' > "$PROJ/shared/prompts/shared.md"
git -C "$PROJ" init --quiet

run() { (cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" "$@"); }
# entries <section> — the section's entries, one per line, as the engine reads them.
entries() {
    awk -v sec="$1" '
        { sub(/\r$/, "") }
        /^sources:[ \t]*$/ { ins = 1; next }
        ins && /^[^ #]/ { ins = 0; f = 0 }
        ins && $0 ~ "^  " sec ":[ \t]*$" { f = 1; next }
        ins && /^  [A-Za-z_]/ { f = 0 }
        f && /^[ \t]*-/ { v = $0; sub(/^[ \t]*-[ \t]*/, "", v); gsub(/["\047]/, "", v); print v }
    ' "$PROJ/intelligence.yaml"
}
joined() { entries "$1" | paste -sd, -; }

echo "== list on an untouched project =="
out="$(run source list)"
grep -q 'sources.rules' <<< "$out" || { echo "FAIL: list omits sources.rules"; fail=1; }
grep -q 'intelligence/rules' <<< "$out" || { echo "FAIL: list omits the project source"; fail=1; }
grep -q '(none)' <<< "$out" || { echo "FAIL: list does not report an empty section"; fail=1; }

echo "== add defaults to the end of the section =="
chk run source add rules backend/intelligence/rules
is "default position" "intelligence/rules,backend/intelligence/rules" "$(joined rules)"

echo "== --before places package-like content ahead of project content =="
chk run source add rules packs/local/rules --before intelligence/rules
is "--before" "packs/local/rules,intelligence/rules,backend/intelligence/rules" "$(joined rules)"

echo "== --after and --first =="
chk run source add rules shared/prompts --after intelligence/rules
is "--after" "packs/local/rules,intelligence/rules,shared/prompts,backend/intelligence/rules" "$(joined rules)"
chk run source add agents intelligence/agents --first
is "--first into a declared but empty section" "intelligence/agents" "$(joined agents)"

echo "== one directory may serve two sections =="
chk run source add agents shared/prompts
is "same directory, second section" "intelligence/agents,shared/prompts" "$(joined agents)"

echo "== re-adding is idempotent and leaves the file byte-identical =="
cp "$PROJ/intelligence.yaml" "$OUT/before-readd.yaml"
chk run source add rules backend/intelligence/rules
chk diff -q "$OUT/before-readd.yaml" "$PROJ/intelligence.yaml"

echo "== an explicit position on a listed entry moves it =="
chk run source add rules packs/local/rules --last
is "move to last" "intelligence/rules,shared/prompts,backend/intelligence/rules,packs/local/rules" "$(joined rules)"
chk run source add rules packs/local/rules --before intelligence/rules
is "move back" "packs/local/rules,intelligence/rules,shared/prompts,backend/intelligence/rules" "$(joined rules)"

echo "== refusals the engine cannot report =="
cp "$PROJ/intelligence.yaml" "$OUT/before-refusals.yaml"
chknot run source add rules /abs/rules
chknot run source add rules 'C:/abs/rules'
chknot run source add rules ../outside/rules
# The repository root is a directory, so it does not fail silently — it renders
# every top-level *.md as an artifact of the section. `sub/..` names the root
# too, but is refused one step earlier, as any entry carrying `..` is.
chknot run source add rules .
chknot run source add rules ./
chknot run source add rules 'sub/..'
chknot run source add rules deep/../../outside/rules
chknot run source add rules .intelligence/packages/@acme/x/rules
chknot run source add rules 'backend\intelligence\rules'
# The refusal names the corrected spelling, which is itself a substitution the
# shell has to get right on every supported Bash.
err="$(run source add rules 'backend\intelligence\rules' 2>&1 || true)"
grep -q 'backend/intelligence/rules' <<< "$err" || { echo "FAIL: the backslash refusal does not name the corrected path: $err"; fail=1; }
chknot run source add rules 'quoted"/rules'
chknot run source add rules 'commented#/rules'
chknot run source add prompts intelligence/rules
chknot run source add rules
chknot run source add rules x/rules --before nowhere/rules
chknot run source add rules x/rules --before
chknot run source add rules x/rules --first --last
chknot run source remove rules .intelligence/packages/@acme/x/rules
chk diff -q "$OUT/before-refusals.yaml" "$PROJ/intelligence.yaml"
chknot ls "$PROJ/intelligence.yaml.cli.tmp"

echo "== a spelling of a listed directory is that directory =="
cp "$PROJ/intelligence.yaml" "$OUT/before-spelling.yaml"
chk run source add rules ./intelligence/rules/
chk run source add rules intelligence/./rules
chk diff -q "$OUT/before-spelling.yaml" "$PROJ/intelligence.yaml"

echo "== status --check reports an entry a hand edit already placed =="
cp "$PROJ/intelligence.yaml" "$OUT/before-check.yaml"
awk '{ print } /^  rules:$/ { print "    - \"/etc/rules\""; print "    - \"../outside/rules\""; print "    - \".\"" }' \
    "$OUT/before-check.yaml" > "$PROJ/intelligence.yaml"
out="$( (cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" status --check) 2>&1 || true)"
grep -q "'/etc/rules' is an absolute path" <<< "$out" || { echo "FAIL: --check accepts an absolute source"; fail=1; }
grep -q "'../outside/rules' leaves the repository" <<< "$out" || { echo "FAIL: --check accepts a source outside the repository"; fail=1; }
grep -q "'\.' is the repository root" <<< "$out" || { echo "FAIL: --check accepts the repository root as a source"; fail=1; }
cp "$OUT/before-check.yaml" "$PROJ/intelligence.yaml"

echo "== a missing directory is a warning, not a refusal =="
err="$(run source add skills intelligence/skills 2>&1 >/dev/null)"
grep -q 'WARN' <<< "$err" || { echo "FAIL: no warning for a missing directory"; fail=1; }
is "missing directory still listed" "intelligence/skills" "$(joined skills)"
chk run source remove skills intelligence/skills

echo "== remove =="
chk run source remove rules shared/prompts
is "after remove" "packs/local/rules,intelligence/rules,backend/intelligence/rules" "$(joined rules)"
is "other section untouched" "intelligence/agents,shared/prompts" "$(joined agents)"
out="$(run source remove rules shared/prompts)"
grep -q 'not listed' <<< "$out" || { echo "FAIL: removing an absent entry is not reported"; fail=1; }

echo "== the wired directories reach the render, in list order =="
chk run source remove agents shared/prompts
chk run source remove agents intelligence/agents
out="$(run sync)"
grep -q '^IS_STATUS=ok' <<< "$out" || { echo "FAIL: sync not ok"; fail=1; }
for marker in PACK_MARKER ROOT_MARKER BACKEND_MARKER; do
    grep -q "$marker" "$PROJ/AGENTS.md" || { echo "FAIL: $marker missing from AGENTS.md"; fail=1; }
done
order="$(awk '/PACK_MARKER/ { print "pack" } /ROOT_MARKER/ { print "root" } /BACKEND_MARKER/ { print "backend" }' "$PROJ/AGENTS.md" | paste -sd, -)"
is "render order follows the source list" "pack,root,backend" "$order"

echo "== a removed source leaves the output at the next sync =="
chk run source remove rules backend/intelligence/rules
out="$(run sync)"
grep -q '^IS_STATUS=ok' <<< "$out" || { echo "FAIL: sync after remove not ok"; fail=1; }
chknot grep -q BACKEND_MARKER "$PROJ/AGENTS.md"
chk test -f "$PROJ/backend/intelligence/rules/backend.md"

# --- package references (decision 0019) -------------------------------------
# One project walked through the owner's acceptance criteria for #48, in their
# order; each heading names the criterion it proves.
REF="$OUT/references"
mkdir -p "$REF"
git -C "$REF" init --quiet
rrun() { (cd "$REF" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" "$@"); }
# ref_joined <section> — that section of the project's sources:, comma-joined.
ref_joined() {
    awk -v sec="$1" '
        { sub(/\r$/, "") }
        /^sources:[ \t]*$/ { ins = 1; next }
        ins && /^[^ #]/ { ins = 0; f = 0 }
        ins && $0 ~ "^  " sec ":[ \t]*$" { f = 1; next }
        ins && /^  [A-Za-z_]/ { f = 0 }
        f && /^[ \t]*-/ { v = $0; sub(/^[ \t]*-[ \t]*/, "", v); gsub(/["\047]/, "", v); print v }
    ' "$REF/intelligence.yaml" | paste -sd, -
}
# sources_block — the sources: block exactly as written.
sources_block() { sed -n '/^sources:/,/^[a-z]/p' "$REF/intelligence.yaml"; }
# package_entry <@scope/name> — that package's packages: entry, lines joined by |.
package_entry() {
    awk -v key="  \"$1\":" '
        { sub(/\r$/, "") }
        /^packages:[ \t]*$/ { p = 1; next }
        p && /^[^ #]/ { p = 0 }
        p && /^  "/ { k = ($0 == key) }
        p && k { print }
    ' "$REF/intelligence.yaml" | paste -sd'|' -
}
# rendered_hashes — every file sync wrote under .claude, hashed.
rendered_hashes() {
    (cd "$REF" && find .claude -type f | LC_ALL=C sort | while IFS= read -r f; do
        printf '%s %s\n' "$(git hash-object --no-filters "$f")" "$f"
    done)
}
# respell <from> <to> — the AC's sed: the first quoted "<from>… on each line
# becomes "<to>…; nothing else moves.
respell() {
    awk -v from="\"$1" -v to="\"$2" '
        { i = index($0, from); if (i) $0 = substr($0, 1, i - 1) to substr($0, i + length(from)); print }
    ' "$REF/intelligence.yaml" > "$REF/intelligence.yaml.tmp"
    mv "$REF/intelligence.yaml.tmp" "$REF/intelligence.yaml"
}
STORE_SYNC=".intelligence/packages/@ainova-systems/sync"

echo "== package references: init writes store paths, exactly as before (AC1) =="
chk rrun init --targets claude
for s in rules agents skills; do
    is "sources.$s after init" "$STORE_SYNC/$s,intelligence/$s" "$(ref_joined "$s")"
done
chk test -f "$REF/.claude/skills/intelligence-sync/SKILL.md"
chk rrun status --check
rendered_hashes > "$OUT/ref.hashes"
chk test -s "$OUT/ref.hashes"
cp "$REF/intelligence.yaml" "$OUT/ref-ac1.yaml"

echo "== package references: the full name renders the same bytes (AC2) =="
respell "$STORE_SYNC/" "@ainova-systems/sync/"
is "rules spelled by full name" "@ainova-systems/sync/rules,intelligence/rules" "$(ref_joined rules)"
sources_block > "$OUT/ref-ac2.sources"
chk rrun sync
rendered_hashes > "$OUT/ref-ac2.hashes"
chk cmp -s "$OUT/ref.hashes" "$OUT/ref-ac2.hashes"
sources_block > "$OUT/ref-ac2.after"
chk cmp -s "$OUT/ref-ac2.sources" "$OUT/ref-ac2.after"
chk rrun status --check

echo "== package references: an alias renders the same bytes (AC3) =="
cp "$OUT/ref-ac1.yaml" "$REF/intelligence.yaml"
sources_block > "$OUT/ref-ac3.before"
chk rrun package alias @ainova-systems/sync sync
ENGINE_VERSION_LINE="    version: \"$ENGINE_VER\""
is "the package's entry gains the alias" "  \"@ainova-systems/sync\":|$ENGINE_VERSION_LINE|    alias: \"sync\"" \
    "$(package_entry @ainova-systems/sync)"
sources_block > "$OUT/ref-ac3.after"
chk cmp -s "$OUT/ref-ac3.before" "$OUT/ref-ac3.after"
respell "$STORE_SYNC/" "sync:"
is "rules spelled by alias" "sync:rules,intelligence/rules" "$(ref_joined rules)"
chk rrun sync
rendered_hashes > "$OUT/ref-ac3.hashes"
chk cmp -s "$OUT/ref.hashes" "$OUT/ref-ac3.hashes"
is "no vendor scope in sources:" "0" "$(sources_block | grep -c @ainova-systems || true)"
chk rrun status --check
out="$(rrun package list)"
grep -q '^@ainova-systems/sync  .*  alias:sync$' <<< "$out" || { echo "FAIL: package list hides the alias: $out"; fail=1; }
out="$(rrun source list)"
grep -q '1\. sync:rules  package$' <<< "$out" || { echo "FAIL: source list does not show the alias as package content: $out"; fail=1; }
cp "$REF/intelligence.yaml" "$OUT/ref-ac3.yaml"

echo "== package references: an alias sources: uses cannot be taken away =="
err="$(rrun package alias @ainova-systems/sync --remove 2>&1)" \
    && { echo "FAIL: removing an alias in use was accepted"; fail=1; }
grep -q "sources.rules 'sync:rules'" <<< "$err" || { echo "FAIL: the refusal does not name the entries: $err"; fail=1; }
err="$(rrun package alias @ainova-systems/sync other 2>&1)" \
    && { echo "FAIL: replacing an alias in use was accepted"; fail=1; }
grep -q "sources.skills 'sync:skills'" <<< "$err" || { echo "FAIL: the refusal does not name the entries: $err"; fail=1; }
err="$(rrun package alias @acme/absent other 2>&1)" \
    && { echo "FAIL: an alias for an undeclared package was accepted"; fail=1; }
chk cmp -s "$OUT/ref-ac3.yaml" "$REF/intelligence.yaml"
out="$(rrun package alias @ainova-systems/sync sync)"
grep -q 'unchanged' <<< "$out" || { echo "FAIL: setting the same alias again is not a no-op: $out"; fail=1; }
chk cmp -s "$OUT/ref-ac3.yaml" "$REF/intelligence.yaml"

echo "== package references: nothing writes the store path back (AC4) =="
sources_block > "$OUT/ref-ac4.sources"
rm -rf "$REF/.intelligence/packages"
chk rrun sync
chk test -f "$REF/.claude/skills/intelligence-sync/SKILL.md"
sources_block > "$OUT/ref-ac4.restored"
chk cmp -s "$OUT/ref-ac4.sources" "$OUT/ref-ac4.restored"
awk '{ if ($0 ~ /^schema_version:/) print "schema_version: \"0.18.1\""; else print }' \
    "$REF/intelligence.yaml" > "$REF/intelligence.yaml.tmp"
mv "$REF/intelligence.yaml.tmp" "$REF/intelligence.yaml"
out="$(rrun sync 2>&1)" || { echo "FAIL: sync of a 0.18.1 stamp: $out"; fail=1; }
grep -q 'project alignment: stamp 0.18.1' <<< "$out" || { echo "FAIL: alignment did not run: $out"; fail=1; }
is "schema_version after alignment" "schema_version: \"$ENGINE_VER\"" "$(grep '^schema_version:' "$REF/intelligence.yaml")"
sources_block > "$OUT/ref-ac4.aligned"
chk cmp -s "$OUT/ref-ac4.sources" "$OUT/ref-ac4.aligned"
rendered_hashes > "$OUT/ref-ac4.hashes"
chk cmp -s "$OUT/ref.hashes" "$OUT/ref-ac4.hashes"

echo "== package references: an alias no package declares (AC6) =="
cp "$OUT/ref-ac3.yaml" "$REF/intelligence.yaml"
awk '{ print } /^  rules:$/ { print "    - \"nope:rules\"" }' "$OUT/ref-ac3.yaml" > "$REF/intelligence.yaml"
out="$(rrun sync 2>&1)" || { echo "FAIL: sync with an unknown alias failed: $out"; fail=1; }
grep -q '^IS_STATUS=ok' <<< "$out" || { echo "FAIL: sync with an unknown alias not ok"; fail=1; }
grep -q "^WARNING: sources.rules 'nope:rules' " <<< "$out" || { echo "FAIL: sync did not warn about nope:rules: $out"; fail=1; }
rc=0
out="$(rrun status --check 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL: status --check accepted nope:rules"; fail=1; }
grep -q "✗ sources.rules 'nope:rules' names alias 'nope'" <<< "$out" \
    || { echo "FAIL: status --check does not name nope:rules: $out"; fail=1; }
out="$(rrun source list)"
grep -q 'nope:rules  UNRESOLVED' <<< "$out" || { echo "FAIL: source list does not flag nope:rules: $out"; fail=1; }
awk '{ if ($0 == "    - \"nope:rules\"") print "    - \"@acme/missing/rules\""; else print }' \
    "$REF/intelligence.yaml" > "$REF/intelligence.yaml.tmp"
mv "$REF/intelligence.yaml.tmp" "$REF/intelligence.yaml"
rc=0
out="$(rrun status --check 2>&1)" || rc=$?
is "status --check with an @ path no package matches" "0" "$rc"
grep -q "✓ sources.rules '@acme/missing/rules' — not created yet (optional)" <<< "$out" \
    || { echo "FAIL: @acme/missing/rules is not an ordinary project path: $out"; fail=1; }

echo "== package references: one directory under two spellings is reported =="
awk '{ print } $0 == "    - \"sync:rules\"" { print "    - \"@ainova-systems/sync/rules\"" }' \
    "$OUT/ref-ac3.yaml" > "$REF/intelligence.yaml"
rc=0
out="$(rrun status --check 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL: status --check accepted a package directory listed twice"; fail=1; }
grep -qF "sources.rules names $STORE_SYNC/rules twice, as 'sync:rules' and as '@ainova-systems/sync/rules'" <<< "$out" \
    || { echo "FAIL: status --check does not name both spellings: $out"; fail=1; }

echo "== package references: the source command leaves them to package (AC8) =="
cp "$OUT/ref-ac3.yaml" "$REF/intelligence.yaml"
mkdir -p "$REF/docs/rules"
printf '# Docs\n\nDOCS_MARKER\n' > "$REF/docs/rules/docs.md"
chk rrun source add rules docs/rules --after sync:rules
is "--after an alias" "sync:rules,docs/rules,intelligence/rules" "$(ref_joined rules)"
cp "$REF/intelligence.yaml" "$OUT/ref-ac8.yaml"
err="$(rrun source add rules @ainova-systems/sync/rules 2>&1)" \
    && { echo "FAIL: source add accepted a full-name reference"; fail=1; }
grep -q 'intelligence package' <<< "$err" || { echo "FAIL: source add does not name intelligence package: $err"; fail=1; }
err="$(rrun source remove rules sync:rules 2>&1)" \
    && { echo "FAIL: source remove accepted an alias reference"; fail=1; }
grep -q 'intelligence package' <<< "$err" || { echo "FAIL: source remove does not name intelligence package: $err"; fail=1; }
err="$(rrun source add rules nope:rules 2>&1)" \
    && { echo "FAIL: source add accepted an alias no package declares"; fail=1; }
grep -q 'intelligence package' <<< "$err" || { echo "FAIL: an unknown alias is not refused as a reference: $err"; fail=1; }
chk cmp -s "$OUT/ref-ac8.yaml" "$REF/intelligence.yaml"
# Every spelling of the anchor finds the entry as written.
chk rrun source add rules docs/rules --before "$STORE_SYNC/rules"
is "--before the store path of an alias entry" "docs/rules,sync:rules,intelligence/rules" "$(ref_joined rules)"
chk rrun source add rules docs/rules --after @ainova-systems/sync/rules
is "--after the full name of an alias entry" "sync:rules,docs/rules,intelligence/rules" "$(ref_joined rules)"
chk rrun sync
chk grep -q DOCS_MARKER "$REF/.claude/rules/docs.md"

echo "== package references: --alias at add, held by one package only (AC5) =="
cp "$OUT/ref-ac3.yaml" "$REF/intelligence.yaml"
chk rrun sync
ACME="$OUT/acme-tools"
mkdir -p "$ACME/rules"
printf '# Acme\n\nACME_MARKER\n' > "$ACME/rules/acme.md"
git -C "$ACME" init --quiet
git -C "$ACME" -c user.email=t@t -c user.name=t add -A
git -C "$ACME" -c user.email=t@t -c user.name=t commit --quiet -m acme
cp "$REF/intelligence.yaml" "$OUT/ref-ac5.yaml"
cp "$REF/intelligence.lock" "$OUT/ref-ac5.lock"
err="$(rrun package add "git+file://$ACME" --name @acme/tools --alias sync 2>&1)" \
    && { echo "FAIL: an alias another package holds was accepted"; fail=1; }
grep -q "alias 'sync' already names @ainova-systems/sync" <<< "$err" \
    || { echo "FAIL: the refusal does not name the holder: $err"; fail=1; }
chk cmp -s "$OUT/ref-ac5.yaml" "$REF/intelligence.yaml"
chk cmp -s "$OUT/ref-ac5.lock" "$REF/intelligence.lock"
chknot test -e "$REF/.intelligence/packages/@acme"
err="$(rrun package add "git+file://$ACME" --name @acme/tools --alias 'a/b' 2>&1)" \
    && { echo "FAIL: alias a/b was accepted"; fail=1; }
grep -q "invalid alias 'a/b'" <<< "$err" || { echo "FAIL: the refusal does not name a/b: $err"; fail=1; }
chk cmp -s "$OUT/ref-ac5.yaml" "$REF/intelligence.yaml"
chk cmp -s "$OUT/ref-ac5.lock" "$REF/intelligence.lock"
chk rrun package add "git+file://$ACME" --name @acme/tools --alias acme
is "the new package's entry" '  "@acme/tools":|    ref: "HEAD"|    alias: "acme"' "$(package_entry @acme/tools)"
chk test -f "$REF/.claude/rules/acme.md"
is "store path wired first, as before" ".intelligence/packages/@acme/tools/rules,sync:rules,intelligence/rules" "$(ref_joined rules)"
# Re-adding keeps the alias it declares.
chk rrun package add "git+file://$ACME" --name @acme/tools --no-sync
is "a re-added package keeps its alias" '  "@acme/tools":|    ref: "HEAD"|    alias: "acme"' "$(package_entry @acme/tools)"

echo "== package references: removing a package removes them, in every spelling (AC7) =="
respell ".intelligence/packages/@acme/tools/rules" "acme:rules"
is "rules before the remove" "acme:rules,sync:rules,intelligence/rules" "$(ref_joined rules)"
chk rrun package remove @acme/tools
chknot grep -q 'acme:' "$REF/intelligence.yaml"
chknot grep -q '@acme/tools' "$REF/intelligence.yaml"
chknot grep -q 'alias: "acme"' "$REF/intelligence.yaml"
chknot test -e "$REF/.claude/rules/acme.md"
is "rules after the remove" "sync:rules,intelligence/rules" "$(ref_joined rules)"
chk rrun status --check

[ "$fail" -eq 0 ] && echo "CLI-E2E-SOURCES: ALL OK"
exit "$fail"
