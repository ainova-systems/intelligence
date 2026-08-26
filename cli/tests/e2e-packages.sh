#!/bin/bash
# Hermetic e2e for the resolver stack: package add/list/remove, locked restore,
# planned updates and registries against file:// fixture repos.
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

# --- fixture pack repo with tags ---
PACK="$OUT/shared-intel"
mkdir -p "$PACK/rules" "$PACK/skills/pack-do-thing"
printf '# Pack rule v1\n\nPACK_RULE_MARKER\n' > "$PACK/rules/pack-rule.md"
printf -- '---\nname: pack-do-thing\ndescription: Do the pack thing\n---\nBody v1.\n' > "$PACK/skills/pack-do-thing/SKILL.md"
git -C "$PACK" init --quiet
git -C "$PACK" -c user.email=t@t -c user.name=t add -A
git -C "$PACK" -c user.email=t@t -c user.name=t commit --quiet -m v1
git -C "$PACK" tag v1.0.0
printf '# Pack rule v1.1\n\nPACK_RULE_MARKER_11\n' > "$PACK/rules/pack-rule.md"
git -C "$PACK" -c user.email=t@t -c user.name=t commit --quiet -am v11
git -C "$PACK" tag v1.1.0
PACK_URL="file://$PACK"

# --- v2 project ---
PROJ="$OUT/proj"
mkdir -p "$PROJ/intelligence/rules"
ENGINE_VER="$(tr -d ' \t\r\n' < "$REPO/engine/VERSION")"
cat > "$PROJ/intelligence.yaml" <<EOF
project:
  name: e2e

schema_version: "$ENGINE_VER"

sources:
  rules:
    - "intelligence/rules"
  agents:
  skills:

targets:
  agents: { enabled: true, output: "AGENTS.md" }
  claude: { enabled: true, output: ".claude" }
EOF
printf '# Ctx\n\nproject context\n' > "$PROJ/intelligence/rules/context.md"
git -C "$PROJ" init --quiet

echo "== package add =="
(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" package add "git+$PACK_URL" --name @acme/shared)
chk test -d "$PROJ/.intelligence/packages/@acme/shared/rules"
chk grep -q '"@acme/shared"' "$PROJ/intelligence.yaml"
chk grep -q 'version: "\^1.1.0"' "$PROJ/intelligence.yaml"
chk grep -q '\.intelligence/packages/@acme/shared/rules' "$PROJ/intelligence.yaml"
chk grep -q '\.intelligence/packages/@acme/shared/skills' "$PROJ/intelligence.yaml"
chk test -f "$PROJ/intelligence.lock"
chk grep -q 'resolved: "v1.1.0"' "$PROJ/intelligence.lock"
chk grep -q 'sha: "' "$PROJ/intelligence.lock"
chk grep -q 'PACK_RULE_MARKER_11' "$PROJ/AGENTS.md"
chk grep -q 'pack-do-thing' "$PROJ/AGENTS.md"

echo "== package list =="
(cd "$PROJ" && bash "$CLI" package list)

echo "== fresh clone + sync restores the locked store =="
CLONE="$OUT/clone"
mkdir -p "$CLONE"
cp -r "$PROJ/intelligence" "$CLONE/intelligence"
cp "$PROJ/intelligence.yaml" "$PROJ/intelligence.lock" "$CLONE/"
git -C "$CLONE" init --quiet
(cd "$CLONE" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync)
chk test -d "$CLONE/.intelligence/packages/@acme/shared/rules"
chk grep -q 'PACK_RULE_MARKER_11' "$CLONE/AGENTS.md"
sha_a="$(grep 'sha:' "$PROJ/intelligence.lock")"; sha_b="$(grep 'sha:' "$CLONE/intelligence.lock")"
[ "$sha_a" = "$sha_b" ] || { echo "FAIL: locked restore changed the lock sha"; fail=1; }

echo "== update (new tag) =="
printf '# Pack rule v1.2\n\nPACK_RULE_MARKER_12\n' > "$PACK/rules/pack-rule.md"
git -C "$PACK" -c user.email=t@t -c user.name=t commit --quiet -am v12
git -C "$PACK" tag v1.2.0
git -C "$PACK" tag v2.0.0   # out of ^1.1.0 range — must NOT be picked
(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" update --preview) | grep -q 'v1.1.0 -> v1.2.0' || { echo "FAIL: preview omitted the available update"; fail=1; }
if (cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" update) >/dev/null 2>&1; then
    echo "FAIL: non-interactive update applied without --apply"; fail=1
fi
chk grep -q 'resolved: "v1.1.0"' "$PROJ/intelligence.lock"
(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" update --apply)
chk grep -q 'resolved: "v1.2.0"' "$PROJ/intelligence.lock"
chknot grep -q 'resolved: "v2.0.0"' "$PROJ/intelligence.lock"
chk grep -q 'PACK_RULE_MARKER_12' "$PROJ/AGENTS.md"

echo "== update to a version that DROPPED a section dir =="
git -C "$PACK" rm -rq skills
git -C "$PACK" -c user.email=t@t -c user.name=t commit --quiet -m drop-skills
git -C "$PACK" tag v1.3.0
(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" update --apply)
chk grep -q 'resolved: "v1.3.0"' "$PROJ/intelligence.lock"
chknot grep -q '\.intelligence/packages/@acme/shared/skills' "$PROJ/intelligence.yaml"
out13="$(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync)"
echo "$out13" | grep -q '^IS_STATUS=ok' || { echo "FAIL: sync after shape-changing update"; fail=1; }

echo "== project file overrides a same-named package file =="
printf '# Project override\n\nPROJECT_WINS\n' > "$PROJ/intelligence/rules/pack-rule.md"
(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync >/dev/null)
chk grep -q 'PROJECT_WINS' "$PROJ/.claude/rules/pack-rule.md"
chknot grep -q 'PACK_RULE_MARKER' "$PROJ/.claude/rules/pack-rule.md"
rm -f "$PROJ/intelligence/rules/pack-rule.md"

echo "== registry binding =="
REG="$OUT/registry"
mkdir -p "$REG"
cat > "$REG/index.yaml" <<EOF
packages:
  "@acme/via-registry":
    url: "$PACK_URL"
    path: "skills"
EOF
git -C "$REG" init --quiet
git -C "$REG" -c user.email=t@t -c user.name=t add -A
git -C "$REG" -c user.email=t@t -c user.name=t commit --quiet -m idx
(cd "$PROJ" && bash "$CLI" registry add "file://$REG")
chk grep -q -- "- \"file://$REG\"" "$PROJ/intelligence.yaml"
(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" package add @acme/via-registry --no-sync)
chk test -f "$PROJ/.intelligence/packages/@acme/via-registry/pack-do-thing/SKILL.md"
chk grep -q '"@acme/via-registry"' "$PROJ/intelligence.lock"

echo "== package remove =="
(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" package remove @acme/shared)
chknot grep -q '"@acme/shared"' "$PROJ/intelligence.yaml"
chknot test -d "$PROJ/.intelligence/packages/@acme/shared"
chknot grep -q '@acme/shared' "$PROJ/intelligence.lock"
chknot grep -q 'PACK_RULE_MARKER' "$PROJ/AGENTS.md"

echo "== idempotent second sync =="
out2="$(cd "$PROJ" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync)"
echo "$out2" | grep -q '^IS_STATUS=ok' || { echo "FAIL: final sync not ok"; fail=1; }

[ "$fail" -eq 0 ] && echo "CLI-E2E: ALL OK"
exit "$fail"
