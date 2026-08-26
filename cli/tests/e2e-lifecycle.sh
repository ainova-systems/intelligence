#!/bin/bash
# e2e: init on a fresh repo; migrate a vendored legacy project (with a
# mirrored pack) to v2; doctor; upgrade.
set -euo pipefail
REPO="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
CLI="$REPO/cli/intelligence"
fail=0
chk() { if ! "$@" >/dev/null 2>&1; then echo "FAIL: $*"; fail=1; fi; }
chknot() { if "$@" >/dev/null 2>&1; then echo "FAIL(not): $*"; fail=1; fi; }

# stage_vendored <umbrella-dir> — rebuild a v1 module from the v2 tree: the
# engine becomes scripts/, the sync package's content sits beside it. The repo
# no longer ships that layout, so a v1 fixture has to be assembled.
stage_vendored() {
    mkdir -p "$1/sync"
    cp -r "$REPO/engine" "$1/sync/scripts"
    cp -r "$REPO/packages/sync/rules" "$REPO/packages/sync/agents" \
        "$REPO/packages/sync/skills" "$REPO/packages/sync/docs" "$1/sync/"
}

echo "== init on a fresh repo =="
FRESH="$OUT/fresh"
mkdir -p "$FRESH/.cursor"
printf "# Claude marker
" > "$FRESH/CLAUDE.md"
git -C "$FRESH" init --quiet
(cd "$FRESH" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" init)
chk test -f "$FRESH/intelligence.yaml"
chk grep -q 'cursor: { enabled: true' "$FRESH/intelligence.yaml"
chk grep -q '^\.intelligence/' "$FRESH/.gitignore"
chk test -f "$FRESH/AGENTS.md"
chk test -d "$FRESH/.claude"
(cd "$FRESH" && bash "$CLI" doctor)

echo "== legacy project with a mirrored pack =="
PACK="$OUT/shared-intel"
mkdir -p "$PACK/rules"
printf '# Pack rule\n\nLEGACY_PACK_MARKER\n' > "$PACK/rules/pack-rule.md"
git -C "$PACK" init --quiet
git -C "$PACK" -c user.email=t@t -c user.name=t add -A
git -C "$PACK" -c user.email=t@t -c user.name=t commit --quiet -m v1
git -C "$PACK" tag v1.1.0

LEG="$OUT/legacy"
mkdir -p "$LEG"
stage_vendored "$LEG/intelligence"
ENGINE_VER="$(tr -d ' \t\r\n' < "$REPO/engine/VERSION")"
cat > "$LEG/intelligence/config.yaml" <<EOF
# Legacy project config
project:
  name: legacy-fixture

sync_version: "$ENGINE_VER"

packs:
  shared-intel:
    url: file://$PACK
    ref: v1.1.0
    mirror: "intelligence/external/shared-intel"

sources:
  rules:
    - "intelligence/rules"
    - "intelligence/sync/rules"
    - "@shared-intel/rules"
  agents:
    - "intelligence/sync/agents"
  skills:
    - "intelligence/sync/skills"

targets:
  agents: { enabled: true, output: "AGENTS.md" }
  claude: { enabled: true, output: ".claude" }
EOF
mkdir -p "$LEG/intelligence/rules"
printf '# Ctx\n\nlegacy project context\n' > "$LEG/intelligence/rules/context.md"
git -C "$LEG" init --quiet
(cd "$LEG" && IS_SUPPRESS_CLI_NOTE=1 bash intelligence/sync/scripts/sync.sh >/dev/null)
chk test -f "$LEG/intelligence/external/shared-intel/.pack"
git -C "$LEG" -c user.email=t@t -c user.name=t add -A
git -C "$LEG" -c user.email=t@t -c user.name=t commit --quiet -m base

echo "== migrate --dry-run =="
(cd "$LEG" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" migrate --dry-run > "$OUT/dry.txt")
chknot test -f "$LEG/intelligence.yaml"
chk test -f "$LEG/intelligence/config.yaml"
chk grep -q 'packages/@' "$OUT/dry.txt"

echo "== migrate =="
(cd "$LEG" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" migrate)
chk test -f "$LEG/intelligence.yaml"
chk test -f "$LEG/intelligence.lock"
chknot test -f "$LEG/intelligence/config.yaml"
chknot test -d "$LEG/intelligence/sync"
chknot test -d "$LEG/intelligence/external"
chk test -f "$LEG/.intelligence/backup/config.yaml"
chk grep -q 'LEGACY_PACK_MARKER' "$LEG/AGENTS.md"
chk grep -q 'intelligence sync' "$LEG/AGENTS.md"
chk grep -rq 'shared-intel' "$LEG/intelligence.lock"
chk grep -q 'ref: "v1.1.0"' "$LEG/intelligence.yaml"
chknot grep -q '^packs:' "$LEG/intelligence.yaml"
chknot grep -q 'sync_version' <(git -C "$LEG" status --porcelain --ignored | grep '\.intelligence/')  # store must be ignored
git -C "$LEG" status --porcelain | grep -q . || { echo "FAIL: migrate produced no diff"; fail=1; }

echo "== doctor after migrate =="
(cd "$LEG" && bash "$CLI" doctor)

echo "== upgrade =="
(cd "$LEG" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" upgrade | tail -2)

echo "== fresh clone of migrated project + install =="
git -C "$LEG" -c user.email=t@t -c user.name=t add -A
git -C "$LEG" -c user.email=t@t -c user.name=t commit --quiet -m migrated
CLONE2="$OUT/clone2"
git clone --quiet "file://$LEG" "$CLONE2"
(cd "$CLONE2" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" install --frozen)
chk grep -q 'LEGACY_PACK_MARKER' "$CLONE2/AGENTS.md"

[ "$fail" -eq 0 ] && echo "MIGRATE-E2E: ALL OK"
exit "$fail"
