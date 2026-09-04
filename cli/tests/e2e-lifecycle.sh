#!/bin/bash
# e2e: init on a fresh repo; conditionally migrate a vendored legacy project
# (with a mirrored pack); deep status; idempotent init and locked restore.
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

# stage_vendored <umbrella-dir> - build a legacy Intelligence Sync fixture.
# engine (it is archived) and migrate no longer runs one, so the module is a
# STUB: detect_project only needs scripts/sync.sh + scripts/VERSION to classify
# the project as legacy. The content beside it is what its sources point at.
stage_vendored() {
    mkdir -p "$1/sync/scripts"
    printf '#!/bin/bash\necho "legacy Intelligence Sync engine"\n' > "$1/sync/scripts/sync.sh"
    tr -d ' \t\r\n' < "$REPO/engine/VERSION" > "$1/sync/scripts/VERSION"
    cp -r "$REPO/packages/sync/rules" "$REPO/packages/sync/agents" \
        "$REPO/packages/sync/skills" "$1/sync/"
}

echo "== init on a fresh repo =="
FRESH="$OUT/fresh"
SPECIAL_TRACKED='.claude/special-$-tick-`-bang-!-backslash\.md'
APOSTROPHE_TRACKED=".claude/apostrophe's.md"
mkdir -p "$FRESH/.github/instructions" "$FRESH/.claude/skills/legacy"
touch "$FRESH/.cursorrules"
printf "# Claude marker
" > "$FRESH/CLAUDE.md"
printf '%s\n' '# Legacy local skill' > "$FRESH/.claude/skills/legacy/SKILL.md"
printf '# Existing project instructions\nCUSTOM_AGENTS_MARKER\n' > "$FRESH/AGENTS.md"
printf '%s\n' '# Shell-special legacy file' > "$FRESH/$SPECIAL_TRACKED"
printf '%s\n' '# Apostrophe legacy file' > "$FRESH/$APOSTROPHE_TRACKED"
printf '# keep vscode packaging rule\nout/**\n' > "$FRESH/.vscodeignore"
printf '# keep npm packaging rule\ndist/**\n' > "$FRESH/.npmignore"
printf '# keep docker context rule\nnode_modules\n' > "$FRESH/.dockerignore"
git -C "$FRESH" init --quiet
git -C "$FRESH" add CLAUDE.md .cursorrules AGENTS.md .claude/skills/legacy/SKILL.md \
    "$SPECIAL_TRACKED" "$APOSTROPHE_TRACKED"
# Existing broad tool ignores are common in established projects. The CLI's
# settings reinclusions must remain effective even when these earlier rules
# would otherwise exclude the parent directories.
printf '%s\n' '.claude/' '.cursor/' > "$FRESH/.gitignore"
(cd "$FRESH" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" init > "$OUT/fresh-init.txt")
chk test -f "$FRESH/intelligence.yaml"
chk grep -q '/intelligence-learn-from-repository' "$OUT/fresh-init.txt"
chk grep -q 'recognizes the initial backup' "$OUT/fresh-init.txt"
chk grep -q 'Existing AI instructions preserved' "$OUT/fresh-init.txt"
chk grep -q 'intelligence package add @ainova-systems/core' "$OUT/fresh-init.txt"
chk grep -q 'intelligence adapter list' "$OUT/fresh-init.txt"
chk grep -q 'intelligence adapter enable codex' "$OUT/fresh-init.txt"
chk grep -q 'intelligence adapter disable cursor' "$OUT/fresh-init.txt"
chk grep -q 'Generated adapter output is gitignored by CLI-owned path' "$OUT/fresh-init.txt"
chknot grep -Fq "git rm --cached -- 'CLAUDE.md'" "$OUT/fresh-init.txt"
chknot grep -Fq "git rm --cached -- '.cursorrules'" "$OUT/fresh-init.txt"
chknot grep -Fq "git rm --cached -- '.claude/skills/legacy/SKILL.md'" "$OUT/fresh-init.txt"
chk grep -Fq "git rm --cached -- '$SPECIAL_TRACKED'" "$OUT/fresh-init.txt"
chk grep -Fq "POSIX:      git rm --cached -- '.claude/apostrophe'\\''s.md'" "$OUT/fresh-init.txt"
chk grep -Fq "PowerShell: git rm --cached -- '.claude/apostrophe''s.md'" "$OUT/fresh-init.txt"
chk grep -q '^IS_STATUS=ok ' "$OUT/fresh-init.txt"
chk grep -q '^=== Done:' "$OUT/fresh-init.txt"
chknot grep -q '^=== intelligence-sync ===' "$OUT/fresh-init.txt"
if ! awk '
    /^=== Sync started ===$/ { started=NR }
    /^IS_STATUS=ok / { status=NR }
    /^=== Done:/ { done=NR }
    /^=== Sync completed ===$/ { completed=NR }
    /^=== Intelligence ready ===$/ { ready=NR }
    END { exit !(started && status > started && done > status && completed > done && ready > completed) }
' "$OUT/fresh-init.txt"; then
    echo "FAIL: init did not show ordered sync progress before first-run guidance"
    fail=1
fi
if ! awk '
    /intelligence package add @ainova-systems\/core/ { package=NR }
    /Ask your agent to run \/intelligence-learn-from-repository/ { learn=NR }
    END { exit !(package && learn > package) }
' "$OUT/fresh-init.txt"; then
    echo "FAIL: init did not recommend the starter package before repository learning"
    fail=1
fi
chk grep -q 'cursor: { enabled: true' "$FRESH/intelligence.yaml"
chk grep -q 'copilot: { enabled: true, output: ".github"' "$FRESH/intelligence.yaml"
chk grep -q '^\.intelligence/' "$FRESH/.gitignore"
chk grep -Fqx 'CLAUDE.md' "$FRESH/.gitignore"
chk grep -Fqx '.claude/*' "$FRESH/.gitignore"
chk grep -Fqx '!.claude/' "$FRESH/.gitignore"
chk grep -Fqx '!.claude/settings.json' "$FRESH/.gitignore"
chk grep -Fqx '.cursor/*' "$FRESH/.gitignore"
chk grep -Fqx '!.cursor/' "$FRESH/.gitignore"
chk grep -Fqx '!.cursor/settings.json' "$FRESH/.gitignore"
chk grep -Fqx 'intelligence/_backup/' "$FRESH/.gitignore"
chknot grep -Fqx '.github/' "$FRESH/.gitignore"
for policy in .vscodeignore .npmignore .dockerignore; do
    chk grep -Fqx '# Intelligence development context and generated output' "$FRESH/$policy"
    chk grep -Fqx '.intelligence/**' "$FRESH/$policy"
    chk grep -Fqx 'intelligence.yaml' "$FRESH/$policy"
    chk grep -Fqx 'intelligence.lock' "$FRESH/$policy"
    chk grep -Fqx 'intelligence/**' "$FRESH/$policy"
    chk grep -Fqx 'AGENTS.md' "$FRESH/$policy"
    chk grep -Fqx '.claude/**' "$FRESH/$policy"
    chk grep -Fqx '.cursor/**' "$FRESH/$policy"
    chk grep -Fqx '.github/**' "$FRESH/$policy"
done
(cd "$FRESH" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" init --no-sync >/dev/null)
for policy in .vscodeignore .npmignore .dockerignore; do
    count="$(grep -Fxc '# Intelligence development context and generated output' "$FRESH/$policy" || true)"
    [ "$count" -eq 1 ] || { echo "FAIL: publisher-ignore block duplicated in $policy"; fail=1; }
done
chk grep -q '# Claude marker' "$FRESH/intelligence/_backup/CLAUDE.md"
chk test -f "$FRESH/intelligence/_backup/.cursorrules"
chknot test -e "$FRESH/CLAUDE.md"
chknot test -e "$FRESH/.cursorrules"
chknot test -e "$FRESH/.claude/commands"
chknot test -e "$FRESH/.cursor/commands"
chk grep -q 'Legacy local skill' "$FRESH/intelligence/_backup/.claude/skills/legacy/SKILL.md"
chk test -d "$FRESH/intelligence/_backup/.github/instructions"
chk grep -Fqx $'state\tinitial-onboarding' "$FRESH/intelligence/_backup/manifest.tsv"
chk grep -Fqx $'path\tAGENTS.md' "$FRESH/intelligence/_backup/manifest.tsv"
chk grep -Fqx $'legacy\tAGENTS.md' "$FRESH/intelligence/_backup/manifest.tsv"
chk grep -Fqx $'legacy\tCLAUDE.md' "$FRESH/intelligence/_backup/manifest.tsv"
chk grep -Fqx $'legacy\t.cursorrules' "$FRESH/intelligence/_backup/manifest.tsv"
chknot test -e "$FRESH/intelligence/_backup/.quarantine-pending"
chk grep -q 'CUSTOM_AGENTS_MARKER' "$FRESH/intelligence/_backup/AGENTS.md"
chk grep -q 'intelligence/_backup/AGENTS.md' "$FRESH/AGENTS.md"
chk grep -q '/intelligence-learn-from-repository' "$FRESH/AGENTS.md"
touch "$FRESH/.claude/settings.json" "$FRESH/.claude/settings.local.json" "$FRESH/.cursor/settings.json"
chknot git -C "$FRESH" check-ignore -q .claude/settings.json
chk git -C "$FRESH" check-ignore -q .claude/settings.local.json
chknot git -C "$FRESH" check-ignore -q .cursor/settings.json
chknot git -C "$FRESH" check-ignore -q AGENTS.md
chk test -f "$FRESH/AGENTS.md"
chk test -d "$FRESH/.claude"
chk grep -q 'intelligence/\*\*' "$FRESH/.cursor/rules/intelligence-authoring.mdc"
chk grep -q '.intelligence/packages/@ainova-systems/sync/references/conventions.md' \
    "$FRESH/.claude/skills/intelligence-review-skills/SKILL.md"
chk test -f "$FRESH/.claude/skills/intelligence-learn-from-repository/SKILL.md"
chk grep -q '_backup/manifest.tsv' "$FRESH/.claude/skills/intelligence-learn-from-repository/SKILL.md"
chk grep -q 'established Intelligence project' "$FRESH/.claude/skills/intelligence-learn-from-context/SKILL.md"
chk grep -q '.intelligence/packages/@ainova-systems/sync/references/onboarding-migration.md' \
    "$FRESH/.claude/skills/intelligence-learn-from-repository/SKILL.md"
chk test -f "$FRESH/.intelligence/packages/@ainova-systems/sync/references/onboarding-migration.md"
chknot grep -R -E -q '<(content-dir|module|manifest|sync-cmd)>' \
    "$FRESH/AGENTS.md" "$FRESH/.claude" "$FRESH/.cursor" "$FRESH/.github"
(cd "$FRESH" && bash "$CLI" status --check)

# A deliberately new, machine-local CLAUDE.md created after onboarding is not
# the original migration source and must survive later init/alignment runs.
printf '# Local machine only\n' > "$FRESH/CLAUDE.md"
(cd "$FRESH" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" init >/dev/null)
chk grep -q 'Local machine only' "$FRESH/CLAUDE.md"

(cd "$FRESH" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync > "$OUT/fresh-resync.txt")
chknot grep -q 'NOT SYNCED: intelligence/_backup/' "$OUT/fresh-resync.txt"

compact_output="$(cd "$FRESH" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync --compact)"
if ! printf '%s\n' "$compact_output" | awk '
    /^WARNING:/ { next }
    /^CONTEXT:/ { context++; next }
    /^IS_STATUS=ok($| )/ { status++; next }
    /^=== Done:/ { done++; next }
    NF { bad=1 }
    END { exit bad || context != 1 || status != 1 || done != 1 }
'; then
    echo "FAIL: compact sync output escaped its line contract"
    printf '%s\n' "$compact_output"
    fail=1
fi
printf '%s\n' "$compact_output" | grep -q '^CONTEXT: ' || { echo "FAIL: compact sync lacks context summary"; fail=1; }
printf '%s\n' "$compact_output" | grep -q '^IS_STATUS=ok ' || { echo "FAIL: compact sync lacks final status"; fail=1; }
printf '%s\n' "$compact_output" | grep -q '^=== Done:' || { echo "FAIL: compact sync lacks completion line"; fail=1; }

echo "== init --no-sync keeps legacy input until a transactional render =="
DEFERRED="$OUT/deferred"
mkdir -p "$DEFERRED/.claude"
printf '# Deferred legacy instructions\n' > "$DEFERRED/CLAUDE.md"
git -C "$DEFERRED" init --quiet
(cd "$DEFERRED" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" init --targets claude --no-sync >/dev/null)
chk grep -q 'Deferred legacy instructions' "$DEFERRED/CLAUDE.md"
chk test -f "$DEFERRED/intelligence/_backup/.quarantine-pending"
(cd "$DEFERRED" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" init >/dev/null)
chknot test -e "$DEFERRED/CLAUDE.md"
chknot test -e "$DEFERRED/intelligence/_backup/.quarantine-pending"
chk grep -q 'Deferred legacy instructions' "$DEFERRED/intelligence/_backup/CLAUDE.md"

echo "== settings-only backup does not claim or schedule quarantine =="
SETTINGS_ONLY="$OUT/settings-only"
mkdir -p "$SETTINGS_ONLY/.claude"
printf '{"permissions":{}}\n' > "$SETTINGS_ONLY/.claude/settings.json"
git -C "$SETTINGS_ONLY" init --quiet
(cd "$SETTINGS_ONLY" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" init --targets claude --no-sync > "$OUT/settings-only-init.txt")
chk test -f "$SETTINGS_ONLY/intelligence/_backup/.claude/settings.json"
chk test -f "$SETTINGS_ONLY/.claude/settings.json"
chknot test -e "$SETTINGS_ONLY/intelligence/_backup/.quarantine-pending"
chknot grep -q 'Legacy root entry points were quarantined' "$OUT/settings-only-init.txt"
(cd "$SETTINGS_ONLY" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" init >/dev/null)
chk test -f "$SETTINGS_ONLY/.claude/settings.json"
chknot test -e "$SETTINGS_ONLY/intelligence/_backup/.quarantine-pending"

compact_target="$(cd "$FRESH" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync agents --compact)"
printf '%s\n' "$compact_target" | grep -q 'IS_DETAIL=synced=1' || { echo "FAIL: compact filtered sync failed"; fail=1; }
compact_target="$(cd "$FRESH" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync --compact agents)"
printf '%s\n' "$compact_target" | grep -q 'IS_DETAIL=synced=1' || { echo "FAIL: compact-first filtered sync failed"; fail=1; }

PREVIEW_AI="$OUT/preview-ai"
mkdir -p "$PREVIEW_AI"
printf 'legacy cursor rule\n' > "$PREVIEW_AI/.cursorrules"
git -C "$PREVIEW_AI" init --quiet
(cd "$PREVIEW_AI" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" init --preview > "$OUT/preview-ai.txt")
chk grep -q 'would preserve 1 existing AI instruction path(s)' "$OUT/preview-ai.txt"
chknot test -e "$PREVIEW_AI/intelligence.yaml"
chknot test -e "$PREVIEW_AI/intelligence/_backup"

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
printf '# existing Docker context rule\nnode_modules\n' > "$LEG/.dockerignore"
git -C "$LEG" init --quiet
# The mirror is what legacy Intelligence Sync would have materialized: committed pack content
# plus its stamp. migrate must COPY it rather than refetch, so the fixture
# writes it directly - the engine that used to produce it is archived.
mkdir -p "$LEG/intelligence/external/shared-intel"
cp -r "$PACK/rules" "$LEG/intelligence/external/shared-intel/"
printf 'url=file://%s\nref=v1.1.0\nsha=%s\n' "$PACK" "$(git -C "$PACK" rev-parse HEAD)" \
    > "$LEG/intelligence/external/shared-intel/.pack"
chk test -f "$LEG/intelligence/external/shared-intel/.pack"
git -C "$LEG" -c user.email=t@t -c user.name=t add -A
git -C "$LEG" -c user.email=t@t -c user.name=t commit --quiet -m base

echo "== init --preview (legacy conversion) =="
(cd "$LEG" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" init --preview > "$OUT/dry.txt")
chknot test -f "$LEG/intelligence.yaml"
chk test -f "$LEG/intelligence/config.yaml"
chk grep -q 'packages/@' "$OUT/dry.txt"

echo "== init --apply (legacy conversion) =="
(cd "$LEG" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" init --apply > "$OUT/migrate.txt")
chk test -f "$LEG/intelligence.yaml"
chk grep -q '/intelligence-learn-from-repository' "$OUT/migrate.txt"
chk test -f "$LEG/intelligence.lock"
chknot test -f "$LEG/intelligence/config.yaml"
chknot test -d "$LEG/intelligence/sync"
chknot test -d "$LEG/intelligence/external"
chk test -f "$LEG/.intelligence/backup/config.yaml"
chk grep -q 'LEGACY_PACK_MARKER' "$LEG/AGENTS.md"
chk grep -q 'intelligence sync' "$LEG/AGENTS.md"
chk test -f "$LEG/.claude/skills/intelligence-learn-from-repository/SKILL.md"
chk grep -rq 'shared-intel' "$LEG/intelligence.lock"
chk grep -q 'ref: "v1.1.0"' "$LEG/intelligence.yaml"
chknot grep -q '^[[:space:]]*url:' "$LEG/intelligence.yaml"
chknot grep -q '^[[:space:]]*path:' "$LEG/intelligence.yaml"
chk grep -q "url: \"file://$PACK\"" "$LEG/intelligence.lock"
chknot grep -q '^packs:' "$LEG/intelligence.yaml"
chknot grep -q '^sync_version:' "$LEG/intelligence.yaml"
chk grep -q "^schema_version: \"$ENGINE_VER\"" "$LEG/intelligence.yaml"
chk grep -Fqx '.intelligence/**' "$LEG/.dockerignore"
chk grep -Fqx 'intelligence.yaml' "$LEG/.dockerignore"
git -C "$LEG" status --porcelain | grep -q . || { echo "FAIL: migrate produced no diff"; fail=1; }

echo "== deep status after migrate =="
(cd "$LEG" && bash "$CLI" status --check)

echo "== idempotent init =="
(cd "$LEG" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" init | tail -2)
for pattern in '.intelligence/' 'CLAUDE.md' '.claude/*' '!.claude/settings.json'; do
    count="$(grep -Fxc -- "$pattern" "$LEG/.gitignore" || true)"
    [ "$count" -eq 1 ] || { echo "FAIL: gitignore pattern duplicated or missing: $pattern"; fail=1; }
done

echo "== fresh clone of migrated project + sync =="
git -C "$LEG" -c user.email=t@t -c user.name=t add -A
git -C "$LEG" -c user.email=t@t -c user.name=t commit --quiet -m migrated
CLONE2="$OUT/clone2"
git clone --quiet "file://$LEG" "$CLONE2"
(cd "$CLONE2" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync)
chk grep -q 'LEGACY_PACK_MARKER' "$CLONE2/AGENTS.md"

[ "$fail" -eq 0 ] && echo "MIGRATE-E2E: ALL OK"
exit "$fail"
