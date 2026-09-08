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
chknot run source add rules deep/../../outside/rules
chknot run source add rules .intelligence/packages/@acme/x/rules
chknot run source add rules 'backend\intelligence\rules'
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

echo "== status --check reports an entry a hand edit already placed =="
cp "$PROJ/intelligence.yaml" "$OUT/before-check.yaml"
awk '{ print } /^  rules:$/ { print "    - \"/etc/rules\""; print "    - \"../outside/rules\"" }' \
    "$OUT/before-check.yaml" > "$PROJ/intelligence.yaml"
out="$( (cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" status --check) 2>&1 || true)"
grep -q "'/etc/rules' is an absolute path" <<< "$out" || { echo "FAIL: --check accepts an absolute source"; fail=1; }
grep -q "'../outside/rules' leaves the repository" <<< "$out" || { echo "FAIL: --check accepts a source outside the repository"; fail=1; }
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

[ "$fail" -eq 0 ] && echo "CLI-E2E-SOURCES: ALL OK"
exit "$fail"
