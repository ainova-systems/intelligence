#!/bin/bash
# e2e: init on a fresh repo; conditionally migrate a vendored legacy project
# (with a mirrored pack); deep status; idempotent init and locked restore.
set -euo pipefail
REPO="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
REPO="$(cd "$REPO" && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
CLI="$REPO/cli/intelligence"
fail=0
chk() { if ! "$@" >/dev/null 2>&1; then echo "FAIL: $*"; fail=1; fi; }
chknot() { if "$@" >/dev/null 2>&1; then echo "FAIL(not): $*"; fail=1; fi; }

# stage_vendored <umbrella-dir> - build a v1 project fixture. v2 ships no v1
# engine (it is archived) and migrate no longer runs one, so the module is a
# STUB: detect_project only needs scripts/sync.sh + scripts/VERSION to classify
# the project as legacy. The content beside it is what the v1 sources point at.
stage_vendored() {
    mkdir -p "$1/sync/scripts"
    printf '#!/bin/bash\necho "archived v1 engine"\n' > "$1/sync/scripts/sync.sh"
    tr -d ' \t\r\n' < "$REPO/engine/VERSION" > "$1/sync/scripts/VERSION"
    cp -r "$REPO/packages/sync/rules" "$REPO/packages/sync/agents" \
        "$REPO/packages/sync/skills" "$1/sync/"
}

echo "== init on a fresh repo =="
FRESH="$OUT/fresh"
mkdir -p "$FRESH/.cursor" "$FRESH/.github/instructions"
printf "# Claude marker
" > "$FRESH/CLAUDE.md"
git -C "$FRESH" init --quiet
(cd "$FRESH" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" init)
chk test -f "$FRESH/intelligence.yaml"
chk grep -q 'cursor: { enabled: true' "$FRESH/intelligence.yaml"
chk grep -q 'copilot: { enabled: true, output: ".github"' "$FRESH/intelligence.yaml"
chk grep -q '^\.intelligence/' "$FRESH/.gitignore"
chk test -f "$FRESH/AGENTS.md"
chk test -d "$FRESH/.claude"
chk grep -q 'intelligence/\*\*' "$FRESH/.cursor/rules/intelligence-authoring.mdc"
chk grep -q '.intelligence/packages/@ainova-systems/sync/references/conventions.md' \
    "$FRESH/.claude/skills/intelligence-review-skills/SKILL.md"
chknot grep -R -E -q '<(content-dir|module|manifest|sync-cmd)>' \
    "$FRESH/AGENTS.md" "$FRESH/.claude" "$FRESH/.cursor" "$FRESH/.github"
(cd "$FRESH" && bash "$CLI" status --check)

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
# The mirror is what a v1 sync would have materialized: committed pack content
# plus its stamp. migrate must COPY it rather than refetch, so the fixture
# writes it directly - the v1 engine that used to produce it is archived.
mkdir -p "$LEG/intelligence/external/shared-intel"
cp -r "$PACK/rules" "$LEG/intelligence/external/shared-intel/"
printf 'url=file://%s\nref=v1.1.0\nsha=%s\n' "$PACK" "$(git -C "$PACK" rev-parse HEAD)" \
    > "$LEG/intelligence/external/shared-intel/.pack"
chk test -f "$LEG/intelligence/external/shared-intel/.pack"
git -C "$LEG" -c user.email=t@t -c user.name=t add -A
git -C "$LEG" -c user.email=t@t -c user.name=t commit --quiet -m base

echo "== init --preview (v1 migration) =="
(cd "$LEG" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" init --preview > "$OUT/dry.txt")
chknot test -f "$LEG/intelligence.yaml"
chk test -f "$LEG/intelligence/config.yaml"
chk grep -q 'packages/@' "$OUT/dry.txt"

echo "== init --apply (v1 migration) =="
(cd "$LEG" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" init --apply)
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

echo "== deep status after migrate =="
(cd "$LEG" && bash "$CLI" status --check)

echo "== idempotent init =="
(cd "$LEG" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" init | tail -2)

echo "== fresh clone of migrated project + sync =="
git -C "$LEG" -c user.email=t@t -c user.name=t add -A
git -C "$LEG" -c user.email=t@t -c user.name=t commit --quiet -m migrated
CLONE2="$OUT/clone2"
git clone --quiet "file://$LEG" "$CLONE2"
(cd "$CLONE2" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync)
chk grep -q 'LEGACY_PACK_MARKER' "$CLONE2/AGENTS.md"

[ "$fail" -eq 0 ] && echo "MIGRATE-E2E: ALL OK"
exit "$fail"
