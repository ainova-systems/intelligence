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
RC=0
OUTPUT=""
chk() { if ! "$@" >/dev/null 2>&1; then echo "FAIL: $*"; fail=1; fi; }
chknot() { if "$@" >/dev/null 2>&1; then echo "FAIL(not): $*"; fail=1; fi; }

run_in() {
    local dir="$1"
    shift
    RC=0
    OUTPUT="$( (cd "$dir" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" "$@") 2>&1 )" || RC=$?
}

snapshot_legacy() {
    local dir="$1" label="$2"
    rm -rf "${OUT:?}/$label.tree"
    mkdir -p "$OUT/$label.tree"
    cp -R "$dir/." "$OUT/$label.tree/"
    # Git's administrative data is fixture machinery, not project state.
    rm -rf "${OUT:?}/$label.tree/.git"
}

assert_legacy_unchanged() {
    local dir="$1" label="$2"
    if ! diff -ru -x .git "$OUT/$label.tree" "$dir" > "$OUT/$label.diff"; then
        echo "FAIL: legacy project changed after refused conversion ($label)"
        sed -n '1,80p' "$OUT/$label.diff"
        fail=1
    fi
}

legacy_xfail() {
    local reason="$1" dir="$2"
    run_in "$dir" init --apply --force
    if [ "$RC" -eq 0 ]; then
        echo "FAIL: expected legacy conversion refusal ($reason)"
        fail=1
    fi
    if ! printf '%s\n' "$OUTPUT" | grep -qF -- "$reason"; then
        echo "FAIL: legacy refusal lacks '$reason'"
        printf '%s\n' "$OUTPUT" | tail -12
        fail=1
    fi
}

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
# A backslash is a path separator on NTFS, where this name cannot exist at all.
# Probe the filesystem instead of branching on the platform: the case then runs
# everywhere over every other shell-special character, and keeps the backslash
# wherever a filesystem can hold one.
mkdir -p "$OUT/fs-probe"
if ! : > "$OUT/fs-probe/back\\slash.md" 2>/dev/null; then
    SPECIAL_TRACKED='.claude/special-$-tick-`-bang-!.md'
    echo "  NOTE: this filesystem cannot hold a backslash in a filename — dropped from the fixture"
fi
rm -rf "$OUT/fs-probe"
mkdir -p "$FRESH/.github/instructions" "$FRESH/.claude/skills/legacy"
touch "$FRESH/.cursorrules"
printf "# Claude marker
" > "$FRESH/CLAUDE.md"
printf '# Gemini marker\n' > "$FRESH/GEMINI.md"
printf '%s\n' '# Antigravity CLI marker' > "$FRESH/.antigravity.md"
printf '%s\n' '# Legacy local skill' > "$FRESH/.claude/skills/legacy/SKILL.md"
printf '# Existing project instructions\nCUSTOM_AGENTS_MARKER\n' > "$FRESH/AGENTS.md"
printf '%s\n' '# Shell-special legacy file' > "$FRESH/$SPECIAL_TRACKED"
printf '%s\n' '# Apostrophe legacy file' > "$FRESH/$APOSTROPHE_TRACKED"
printf '# keep vscode packaging rule\nout/**\n' > "$FRESH/.vscodeignore"
printf '# keep npm packaging rule\ndist/**\n' > "$FRESH/.npmignore"
printf '# keep docker context rule\nnode_modules\n' > "$FRESH/.dockerignore"
git -C "$FRESH" init --quiet
git -C "$FRESH" add CLAUDE.md GEMINI.md .cursorrules AGENTS.md .claude/skills/legacy/SKILL.md \
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
chknot grep -Fq "git rm --cached -- 'GEMINI.md'" "$OUT/fresh-init.txt"
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
chk grep -q 'antigravity: { enabled: true, output: ".agents"' "$FRESH/intelligence.yaml"
chk grep -q '^\.intelligence/' "$FRESH/.gitignore"
chk grep -Fqx 'CLAUDE.md' "$FRESH/.gitignore"
chk grep -Fqx '.claude/*' "$FRESH/.gitignore"
chk grep -Fqx '!.claude/' "$FRESH/.gitignore"
chk grep -Fqx '!.claude/settings.json' "$FRESH/.gitignore"
chk grep -Fqx '.cursor/*' "$FRESH/.gitignore"
chk grep -Fqx '!.cursor/' "$FRESH/.gitignore"
chk grep -Fqx '!.cursor/settings.json' "$FRESH/.gitignore"
chk grep -Fqx 'GEMINI.md' "$FRESH/.gitignore"
chk grep -Fqx '.antigravity.md' "$FRESH/.gitignore"
chk grep -Fqx '.agents/rules/' "$FRESH/.gitignore"
chk grep -Fqx '.agents/agents/' "$FRESH/.gitignore"
chk grep -Fqx '.agents/skills/' "$FRESH/.gitignore"
# `.agents/` is a shared workspace root, not adapter-owned output: ignoring it
# whole would hide hand-written workspace content the adapter never writes.
chknot grep -Fqx '.agents/' "$FRESH/.gitignore"
chk grep -Fqx 'intelligence/_backup/' "$FRESH/.gitignore"
chknot grep -Fqx '.github/' "$FRESH/.gitignore"
for sub in instructions prompts agents skills; do
    chk grep -Fqx ".github/$sub/" "$FRESH/.gitignore"
done
chknot git -C "$FRESH" check-ignore -q .github/workflows/x.yml
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
    chk grep -Fqx '.agents/**' "$FRESH/$policy"
done
(cd "$FRESH" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" init --no-sync >/dev/null)
for policy in .vscodeignore .npmignore .dockerignore; do
    count="$(grep -Fxc '# Intelligence development context and generated output' "$FRESH/$policy" || true)"
    [ "$count" -eq 1 ] || { echo "FAIL: publisher-ignore block duplicated in $policy"; fail=1; }
done
chk grep -q '# Claude marker' "$FRESH/intelligence/_backup/CLAUDE.md"
chk grep -q '# Gemini marker' "$FRESH/intelligence/_backup/GEMINI.md"
chk grep -q '# Antigravity CLI marker' "$FRESH/intelligence/_backup/.antigravity.md"
chk test -f "$FRESH/intelligence/_backup/.cursorrules"
chknot test -e "$FRESH/CLAUDE.md"
# A workspace-root instruction file outranks AGENTS.md in Antigravity's rule
# precedence — GEMINI.md over AGENTS.md, .antigravity.md over GEMINI.md in the
# CLI. Left in place either silently overrides every synced rule, so onboarding
# quarantines both.
chknot test -e "$FRESH/GEMINI.md"
chknot test -e "$FRESH/.antigravity.md"
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
chk grep -Fqx $'legacy\tGEMINI.md' "$FRESH/intelligence/_backup/manifest.tsv"
chk grep -Fqx $'legacy\t.antigravity.md' "$FRESH/intelligence/_backup/manifest.tsv"
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
# Antigravity: AGENTS.md carries always-on rules, so only path-scoped rules
# reach .agents/rules — as glob-triggered files. Agents need the `name` the
# tool requires and a model from its documented inherit|flash|pro set.
chk grep -Fqx 'trigger: glob' "$FRESH/.agents/rules/intelligence-authoring.md"
chk grep -Fqx 'globs:' "$FRESH/.agents/rules/intelligence-authoring.md"
chknot grep -Fqx 'paths:' "$FRESH/.agents/rules/intelligence-authoring.md"
chk grep -q 'intelligence/\*\*' "$FRESH/.agents/rules/intelligence-authoring.md"
chk grep -Fqx 'name: "intelligence-architect"' "$FRESH/.agents/agents/intelligence-architect.md"
chk grep -Fqx 'model: "pro"' "$FRESH/.agents/agents/intelligence-architect.md"
chk grep -Fqx 'model: "flash"' "$FRESH/.agents/agents/intelligence-operator.md"
chk grep -Fqx 'subagent: true' "$FRESH/.agents/agents/intelligence-architect.md"
chk grep -Fqx 'mainAgent: false' "$FRESH/.agents/agents/intelligence-architect.md"
chk test -f "$FRESH/.agents/skills/intelligence-review-context/SKILL.md"
chk grep -q '.intelligence/packages/@ainova-systems/sync/references/conventions.md' \
    "$FRESH/.claude/skills/intelligence-review-context/SKILL.md"
chk test -f "$FRESH/.claude/skills/intelligence-learn-from-repository/SKILL.md"
chk grep -q '_backup/manifest.tsv' "$FRESH/.claude/skills/intelligence-learn-from-repository/SKILL.md"
chk grep -q 'established Intelligence project' "$FRESH/.claude/skills/intelligence-learn-from-session/SKILL.md"
chk grep -q '.intelligence/packages/@ainova-systems/sync/references/onboarding-migration.md' \
    "$FRESH/.claude/skills/intelligence-learn-from-repository/SKILL.md"
chk test -f "$FRESH/.intelligence/packages/@ainova-systems/sync/references/onboarding-migration.md"
# The bundled catalog and its conditional references must survive rendering;
# contributor-only implementation workflows do not belong in consumer output.
expected_skills=(
    intelligence-learn-from-repository intelligence-learn-from-session
    intelligence-manage-adapters intelligence-review-context intelligence-sync
    intelligence-upgrade intelligence-update-context
)
printf '%s\n' "${expected_skills[@]}" | sort > "$OUT/expected-skills.txt"
for skill_root in "$FRESH/.intelligence/packages/@ainova-systems/sync/skills" \
    "$FRESH/.claude/skills" "$FRESH/.agents/skills"; do
    find "$skill_root" -mindepth 2 -maxdepth 2 -name SKILL.md \
        | awk -F/ '{ print $(NF-1) }' | sort > "$OUT/actual-skills.txt"
    chk diff -u "$OUT/expected-skills.txt" "$OUT/actual-skills.txt"
    for reference in rules agents skills; do
        chk test -s "$skill_root/intelligence-update-context/references/$reference.md"
    done
    for reference in audit-checks compaction principles; do
        chk test -s "$skill_root/intelligence-review-context/references/$reference.md"
    done
    chknot test -e "$skill_root/dev-build-adapter"
done
# Upgrades and adapter changes are the owner's decision: those two skills reach
# every skill output marked so no agent selects them, and the operator a forked
# sync runs as no longer preloads them.
for skill_root in "$FRESH/.claude/skills" "$FRESH/.agents/skills"; do
    for skill in intelligence-upgrade intelligence-manage-adapters; do
        chk grep -Fqx 'disable-model-invocation: true' "$skill_root/$skill/SKILL.md"
    done
    chknot grep -Fq 'disable-model-invocation' "$skill_root/intelligence-sync/SKILL.md"
done
# Codex ignores that frontmatter key, so sync derives its policy file in the
# tree Codex reads; the package source and the other outputs carry none.
for skill in intelligence-upgrade intelligence-manage-adapters; do
    chk grep -Fqx '  allow_implicit_invocation: false' "$FRESH/.agents/skills/$skill/agents/openai.yaml"
    chknot test -e "$FRESH/.intelligence/packages/@ainova-systems/sync/skills/$skill/agents"
    chknot test -e "$FRESH/.claude/skills/$skill/agents"
done
chknot test -e "$FRESH/.agents/skills/intelligence-sync/agents/openai.yaml"
chk grep -Fqx '  - intelligence-sync' "$FRESH/.claude/agents/intelligence-operator.md"
chknot grep -Eq '^  - intelligence-(upgrade|manage-adapters)$' "$FRESH/.claude/agents/intelligence-operator.md"
chk grep -Fq 'intelligence.yaml' \
    "$FRESH/.claude/skills/intelligence-review-context/references/audit-checks.md"
chknot grep -R -E -q '<(content-dir|module|manifest|sync-cmd)>' \
    "$FRESH/AGENTS.md" "$FRESH/.claude" "$FRESH/.cursor" "$FRESH/.github" "$FRESH/.agents"
(cd "$FRESH" && bash "$CLI" status --check)

# A deliberately new, machine-local CLAUDE.md created after onboarding is not
# the original migration source and must survive later init/alignment runs.
printf '# Local machine only\n' > "$FRESH/CLAUDE.md"
(cd "$FRESH" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" init >/dev/null)
chk grep -q 'Local machine only' "$FRESH/CLAUDE.md"

(cd "$FRESH" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync > "$OUT/fresh-resync.txt")
chknot grep -q 'NOT SYNCED: intelligence/_backup/' "$OUT/fresh-resync.txt"

# Simulate output from the previous catalog, then regenerate from the current
# package. Removed commands must disappear while a configured local skill stays.
old_skills=(intelligence-add-rule intelligence-add-agent intelligence-add-skill
    intelligence-learn-from-context intelligence-extract-skill intelligence-review-skills
    intelligence-compact-context intelligence-install-adapter intelligence-uninstall-adapter
    intelligence-update)
for skill_root in "$FRESH/.claude/skills" "$FRESH/.agents/skills"; do
    for old_skill in "${old_skills[@]}"; do
        mkdir -p "$skill_root/$old_skill"
        printf '# Previous generated command\n' > "$skill_root/$old_skill/SKILL.md"
    done
done
mkdir -p "$FRESH/intelligence/skills"
cp -R "$REPO/intelligence/skills/dev-build-adapter" "$FRESH/intelligence/skills/"
(cd "$FRESH" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync --compact > "$OUT/catalog-sync.txt")
chk grep -q '^IS_STATUS=ok ' "$OUT/catalog-sync.txt"
for skill_root in "$FRESH/.claude/skills" "$FRESH/.agents/skills"; do
    chk test -s "$skill_root/dev-build-adapter/SKILL.md"
    for old_skill in "${old_skills[@]}"; do
        chknot test -e "$skill_root/$old_skill"
    done
done
chk test -s "$FRESH/intelligence/skills/dev-build-adapter/SKILL.md"
chknot test -e "$FRESH/.intelligence/packages/@ainova-systems/sync/skills/dev-build-adapter"
cp -R "$FRESH/.claude/skills" "$OUT/catalog-first-render"
(cd "$FRESH" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync --compact > "$OUT/catalog-resync.txt")
chk diff -ru "$OUT/catalog-first-render" "$FRESH/.claude/skills"
(cd "$FRESH" && bash "$CLI" status --check)

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

echo "== .agents/ markers select only the tools that read them =="
# The shared root holds Antigravity's own directories next to the skills
# directory Codex reads. An Antigravity-only workspace must not enable Codex.
AG_ONLY="$OUT/agents-root-only"
mkdir -p "$AG_ONLY/.agents/rules"
git -C "$AG_ONLY" init --quiet
(cd "$AG_ONLY" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" init --no-sync >/dev/null)
chk grep -q 'antigravity: { enabled: true' "$AG_ONLY/intelligence.yaml"
chknot grep -q 'codex:' "$AG_ONLY/intelligence.yaml"
# The shared skills directory still implies Codex, which genuinely reads it.
AG_SHARED="$OUT/agents-root-shared"
mkdir -p "$AG_SHARED/.agents/rules" "$AG_SHARED/.agents/skills"
git -C "$AG_SHARED" init --quiet
(cd "$AG_SHARED" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" init --no-sync >/dev/null)
chk grep -q 'antigravity: { enabled: true' "$AG_SHARED/intelligence.yaml"
chk grep -q 'codex: { enabled: true' "$AG_SHARED/intelligence.yaml"

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

echo "== mirrored legacy pack requires a recorded commit SHA =="
for stamp_case in missing-stamp no-sha unknown-sha malformed-sha; do
    BAD_LEG="$OUT/legacy-$stamp_case"
    mkdir -p "$BAD_LEG"
    cp -R "$LEG/." "$BAD_LEG/"
    stamp="$BAD_LEG/intelligence/external/shared-intel/.pack"
    case "$stamp_case" in
        missing-stamp)
            rm "$stamp"
            reason="has no .pack ownership stamp"
            ;;
        no-sha)
            printf 'url=file://%s\nref=v1.1.0\n' "$PACK" > "$stamp"
            reason="missing or invalid recorded commit SHA"
            ;;
        unknown-sha)
            printf 'url=file://%s\nref=v1.1.0\nsha=unknown\n' "$PACK" > "$stamp"
            reason="missing or invalid recorded commit SHA"
            ;;
        malformed-sha)
            printf 'url=file://%s\nref=v1.1.0\nsha=not-a-git-id\n' "$PACK" > "$stamp"
            reason="missing or invalid recorded commit SHA"
            ;;
    esac
    snapshot_legacy "$BAD_LEG" "$stamp_case"
    legacy_xfail "$reason" "$BAD_LEG"
    if [ "$stamp_case" != missing-stamp ] \
        && ! printf '%s\n' "$OUTPUT" | grep -qF 'legacy project unchanged'; then
        echo "FAIL: malformed legacy stamp lacks unchanged-project guidance"
        printf '%s\n' "$OUTPUT" | tail -12
        fail=1
    fi
    assert_legacy_unchanged "$BAD_LEG" "$stamp_case"
done

echo "== valid stamped mirror converts with its source offline =="
OFFLINE_LEG="$OUT/legacy-offline-stamped"
mkdir -p "$OFFLINE_LEG"
cp -R "$LEG/." "$OFFLINE_LEG/"
OFFLINE_URL="file://$OUT/source-is-intentionally-unavailable"
awk -v url="$OFFLINE_URL" '/^[[:space:]]+url:/ { print "    url: " url; next } { print }' \
    "$OFFLINE_LEG/intelligence/config.yaml" > "$OFFLINE_LEG/intelligence/config.yaml.tmp"
mv "$OFFLINE_LEG/intelligence/config.yaml.tmp" "$OFFLINE_LEG/intelligence/config.yaml"
printf 'url=%s\r\nref=v1.1.0\r\nsha=%s\r\n' "$OFFLINE_URL" "$(git -C "$PACK" rev-parse HEAD)" \
    > "$OFFLINE_LEG/intelligence/external/shared-intel/.pack"
run_in "$OFFLINE_LEG" init --apply --force
if [ "$RC" -ne 0 ]; then
    echo "FAIL: valid stamped mirror required its unavailable source"
    printf '%s\n' "$OUTPUT" | tail -12
    fail=1
fi
chk grep -q "url: \"$OFFLINE_URL\"" "$OFFLINE_LEG/intelligence.lock"
chk grep -q "sha: \"$(git -C "$PACK" rev-parse HEAD)\"" "$OFFLINE_LEG/intelligence.lock"
chk grep -q 'LEGACY_PACK_MARKER' "$OFFLINE_LEG/AGENTS.md"

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

echo "== Antigravity renders what its docs describe =="
# Three claims the vendor documents, asserted on real output: a readonly agent
# carries only documented tool names (an unmapped name may hang the subagent),
# `paths:` becomes `globs:` inside frontmatter and nowhere else, and a rule
# past the documented 12,000-character limit is reported rather than shipped
# silently.
AGR="$OUT/antigravity-render"
mkdir -p "$AGR/intelligence/rules" "$AGR/intelligence/agents"
git -C "$AGR" init --quiet
cat > "$AGR/intelligence.yaml" <<EOF
project:
  name: antigravity-render

schema_version: "$ENGINE_VER"

sources:
  rules:
    - "intelligence/rules"
  agents:
    - "intelligence/agents"
  skills:

targets:
  agents: { enabled: true, output: "AGENTS.md" }
  antigravity: { enabled: true, output: ".agents" }
  cursor: { enabled: true, output: ".cursor" }
EOF
cat > "$AGR/intelligence/agents/auditor.md" <<'EOF'
---
name: auditor
description: "Reviews without writing"
tier: heavy
access: readonly
---

# Auditor

Reads and reports.
EOF
cat > "$AGR/intelligence/agents/builder.md" <<'EOF'
---
name: builder
description: "Implements changes"
tier: standard
access: full
---

# Builder

Writes code.
EOF
{
    printf -- '---\npaths:\n  - "src/**"\ndescription: "scoped"\n---\n\n# Scoped\n\n'
    printf 'A rule that teaches rule syntax quotes the key itself:\n\n```yaml\npaths:\n  - "docs/**"\n```\n'
} > "$AGR/intelligence/rules/scoped.md"
(cd "$AGR" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync > "$OUT/agr-sync.txt" 2>&1)
chk grep -Fqx '  - view_file' "$AGR/.agents/agents/auditor.md"
chk grep -Fqx '  - grep_search' "$AGR/.agents/agents/auditor.md"
chknot grep -Eq 'search_web|read_url_content' "$AGR/.agents/agents/auditor.md"
chk grep -Fqx 'model: "pro"' "$AGR/.agents/agents/auditor.md"
# access: full inherits the main agent's tools, which is Antigravity's default.
chknot grep -q '^tools:' "$AGR/.agents/agents/builder.md"
chk grep -Fqx 'trigger: glob' "$AGR/.agents/rules/scoped.md"
chk grep -Fqx 'globs:' "$AGR/.agents/rules/scoped.md"
# The body keeps the key it documents; only the frontmatter is rewritten.
chk grep -Fqx '  - "docs/**"' "$AGR/.agents/rules/scoped.md"
# Cursor rewrites the same key through its own awk, so it carries its own
# regression: the assertion pair must fail independently if either drifts.
for rendered in "$AGR/.agents/rules/scoped.md" "$AGR/.cursor/rules/scoped.mdc"; do
    body_paths="$(awk 'n >= 2 && /^paths:$/ { found = 1 } /^---$/ { n++ } END { exit(found ? 0 : 1) }' "$rendered" && echo yes || echo no)"
    [ "$body_paths" = "yes" ] || { echo "FAIL: body 'paths:' line was rewritten in $rendered"; fail=1; }
    chk grep -Fqx '  - "docs/**"' "$rendered"
done
chk grep -Fqx 'alwaysApply: false' "$AGR/.cursor/rules/scoped.mdc"
chk grep -Fqx 'globs:' "$AGR/.cursor/rules/scoped.mdc"
chknot grep -q 'limits a rule file' "$OUT/agr-sync.txt"

{
    printf -- '---\npaths:\n  - "big/**"\n---\n\n'
    awk 'BEGIN { for (i = 0; i < 300; i++) printf "%s\n", sprintf("%060d", i) }'
} > "$AGR/intelligence/rules/big.md"
(cd "$AGR" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync > "$OUT/agr-big.txt" 2>&1)
chk grep -q 'Antigravity limits a rule file to 12000 characters' "$OUT/agr-big.txt"
chk grep -q '.agents/rules/big.md' "$OUT/agr-big.txt"
# agr_rule_limit <yaml-value> — repoint the setting through a temp file; BSD
# sed -i takes a suffix argument, so in-place editing is not portable.
agr_rule_limit() {
    awk -v setting="$1" '{
        sub(/\r$/, "")
        if ($0 ~ /^  antigravity:/)
            print "  antigravity: { enabled: true, output: \".agents\", warn_rule_limit: " setting " }"
        else print
    }' "$AGR/intelligence.yaml" > "$AGR/intelligence.yaml.tmp"
    mv "$AGR/intelligence.yaml.tmp" "$AGR/intelligence.yaml"
}

# A positive count is the threshold itself, in both directions: below it the
# same rule reports, above it the same rule is silent.
agr_rule_limit 100
(cd "$AGR" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync > "$OUT/agr-100.txt" 2>&1)
chk grep -q 'Antigravity limits a rule file to 100 characters' "$OUT/agr-100.txt"
agr_rule_limit 25000
(cd "$AGR" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync > "$OUT/agr-25000.txt" 2>&1)
chknot grep -q 'limits a rule file' "$OUT/agr-25000.txt"

agr_rule_limit false
(cd "$AGR" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync > "$OUT/agr-off.txt" 2>&1)
chknot grep -q 'limits a rule file' "$OUT/agr-off.txt"

# A later source replaces the file and its measured size, even when the
# earlier rule exceeded the limit. Measure the actual output for the warning.
mkdir -p "$AGR/project-rules"
printf -- '---\npaths:\n  - "big/**"\n---\n\nShort override.\n' > "$AGR/project-rules/big.md"
(cd "$AGR" && bash "$CLI" source add rules project-rules > "$OUT/agr-source.txt" 2>&1)
agr_rule_limit true
(cd "$AGR" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync > "$OUT/agr-override.txt" 2>&1)
chk grep -Fqx 'Short override.' "$AGR/.agents/rules/big.md"
chknot grep -q 'limits a rule file' "$OUT/agr-override.txt"
agr_rule_limit 10
(cd "$AGR" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync > "$OUT/agr-override-10.txt" 2>&1)
override_chars="$(wc -c < "$AGR/.agents/rules/big.md" | tr -d '[:space:]')"
chk grep -Fq ".agents/rules/big.md renders $override_chars;" "$OUT/agr-override-10.txt"

echo "== every built-in adapter renders every model tier =="
# The expected model comes from the engine's own default table, so a model
# bump does not touch this test; what it pins is that each adapter emits the
# tier's resolved model, never an empty one, and that a tier never sets a
# reasoning effort (decision 0015).
TIERS="$OUT/model-tiers"
mkdir -p "$TIERS/intelligence/agents" "$TIERS/intelligence/skills"
git -C "$TIERS" init --quiet
cat > "$TIERS/intelligence.yaml" <<EOF
project:
  name: model-tiers

schema_version: "$ENGINE_VER"

sources:
  rules:
  agents:
    - "intelligence/agents"
  skills:
    - "intelligence/skills"

targets:
  agents: { enabled: true, output: "AGENTS.md" }
  antigravity: { enabled: true, output: ".agents" }
  claude: { enabled: true, output: ".claude" }
  codex: { enabled: true, output: ".codex" }
  copilot: { enabled: true, output: ".github" }
  cursor: { enabled: true, output: ".cursor" }
  opencode: { enabled: true, output: ".opencode" }
EOF
for tier in frontier heavy standard light; do
    printf -- '---\nname: %s-agent\ndescription: "A %s agent"\ntier: %s\naccess: full\n---\n\n# Agent\n' \
        "$tier" "$tier" "$tier" > "$TIERS/intelligence/agents/$tier-agent.md"
done
printf -- '---\nname: untiered-agent\ndescription: "No tier"\naccess: full\n---\n\n# Agent\n' \
    > "$TIERS/intelligence/agents/untiered-agent.md"
(cd "$TIERS" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync > "$OUT/tiers-sync.txt" 2>&1) || { echo "FAIL: model-tier sync"; cat "$OUT/tiers-sync.txt"; fail=1; }
# shellcheck source=/dev/null
default_model() { (source "$REPO/engine/lib/common.sh" && get_model_default "$1" "$2"); }
for tier in frontier heavy standard light; do
    for tool in claude codex copilot cursor opencode antigravity; do
        [ -n "$(default_model "$tool" "$tier")" ] || { echo "FAIL: no $tool default for $tier"; fail=1; }
    done
    chk grep -Fqx "model: $(default_model claude "$tier")" "$TIERS/.claude/agents/$tier-agent.md"
    chk grep -Fqx "model = \"$(default_model codex "$tier")\"" "$TIERS/.codex/agents/$tier-agent.toml"
    chk grep -Fqx "model: $(default_model copilot "$tier")" "$TIERS/.github/agents/$tier-agent.agent.md"
    chk grep -Fqx "model: $(default_model cursor "$tier")" "$TIERS/.cursor/agents/$tier-agent.md"
    chk grep -Fqx "model: \"$(default_model opencode "$tier")\"" "$TIERS/.opencode/agents/$tier-agent.md"
    chk grep -Fqx "model: \"$(default_model antigravity "$tier")\"" "$TIERS/.agents/agents/$tier-agent.md"
done
# No tier resolves to heavy.
chk grep -Fqx "model = \"$(default_model codex heavy)\"" "$TIERS/.codex/agents/untiered-agent.toml"
chk grep -Fqx "model: $(default_model claude heavy)" "$TIERS/.claude/agents/untiered-agent.md"
# A tier selects the model only: without `effort:` no tool receives an effort,
# so the tool's own setting applies — and frontier and heavy, which share a
# Codex model, render the same agent.
for agent in frontier-agent heavy-agent standard-agent light-agent untiered-agent; do
    chknot grep -q 'model_reasoning_effort' "$TIERS/.codex/agents/$agent.toml"
    chknot grep -q '^effort:' "$TIERS/.claude/agents/$agent.md"
done
eq() { [ "$1" = "$2" ]; }
# same_but_identity <a> <b> — identical once name and description are set aside.
same_but_identity() { eq "$(grep -Ev '^(name|description) = ' "$1")" "$(grep -Ev '^(name|description) = ' "$2")"; }
chk same_but_identity "$TIERS/.codex/agents/frontier-agent.toml" "$TIERS/.codex/agents/heavy-agent.toml"
# A tier nothing resolves still renders, but never silently: one warning per
# tool and tier, however many agents carry it. A custom tier the manifest
# overrides resolves quietly for that tool.
for name in typo-agent typo-twin; do
    printf -- '---\nname: %s\ndescription: "Typo"\ntier: haevy\naccess: full\n---\n\n# Agent\n' "$name" \
        > "$TIERS/intelligence/agents/$name.md"
done
printf -- '---\nname: custom-agent\ndescription: "Custom"\ntier: review-deep\naccess: full\n---\n\n# Agent\n' \
    > "$TIERS/intelligence/agents/custom-agent.md"
printf '%s\n' 'models:' '  claude:' '    review-deep: "claude-opus-5-5"' >> "$TIERS/intelligence.yaml"
(cd "$TIERS" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync > "$OUT/tiers-unknown.txt" 2>&1) \
    || { echo "FAIL: unknown-tier sync"; cat "$OUT/tiers-unknown.txt"; fail=1; }
chk test "$(grep -Fc "no claude model for tier 'haevy'" "$OUT/tiers-unknown.txt")" -eq 1
chk grep -Fq "no codex model for tier 'haevy'" "$OUT/tiers-unknown.txt"
chknot grep -Fq "no claude model for tier 'review-deep'" "$OUT/tiers-unknown.txt"
chk grep -Fqx 'model: claude-opus-5-5' "$TIERS/.claude/agents/custom-agent.md"
chknot grep -Fq "tier 'heavy'" "$OUT/tiers-unknown.txt"
# `sync --compact` keeps only unindented WARNING: lines, so the warning must be
# one: on a full render, and on the unchanged run that replays it.
(cd "$TIERS" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync --compact --force > "$OUT/tiers-compact.txt" 2>&1) \
    || { echo "FAIL: unknown-tier compact sync"; cat "$OUT/tiers-compact.txt"; fail=1; }
(cd "$TIERS" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync --compact > "$OUT/tiers-replay.txt" 2>&1) \
    || { echo "FAIL: unknown-tier compact replay"; cat "$OUT/tiers-replay.txt"; fail=1; }
chk grep -q "^WARNING: no claude model for tier 'haevy'" "$OUT/tiers-compact.txt"
chk grep -q "^WARNING: no claude model for tier 'haevy'" "$OUT/tiers-replay.txt"

echo "== effort is written once and rendered where a tool has a field =="
# Decision 0015: the neutral level reaches Claude Code (the nearest lower level
# it has) and Codex; the shared skills tree keeps it as written; every other
# tool gets no effort key. An off-scale value warns, names its source and is
# rendered as absent without failing the sync; an empty one is absent, silently.
# fm_effort_keys <file> — the frontmatter lines whose key names any effort
# (`effort`, `reasoningEffort`, ...); a body line is the author's text and stays.
fm_effort_keys() {
    awk 'NR == 1 && $0 != "---" { exit } /^---$/ { if (++n == 2) exit; next }
        index($0, ":") && tolower(substr($0, 1, index($0, ":") - 1)) ~ /effort/' "$1"
}
no_effort_key() { [ -z "$(fm_effort_keys "$1")" ]; }
tiers_agent() { # <name> <frontmatter line>...
    local name="$1"
    shift
    { printf -- '---\nname: %s\ndescription: "Agent %s"\n' "$name" "$name"
      [ "$#" -eq 0 ] || printf '%s\n' "$@"
      printf -- '---\n\n# Agent\n\neffort: a body line keeps its text\n'; } > "$TIERS/intelligence/agents/$name.md"
}
tiers_skill() { # <name> <frontmatter line>...
    local name="$1"
    shift
    mkdir -p "$TIERS/intelligence/skills/$name"
    { printf -- '---\nname: %s\ndescription: "Skill %s"\n' "$name" "$name"
      [ "$#" -eq 0 ] || printf '%s\n' "$@"
      printf -- '---\n\n# Skill\n\neffort: a body line keeps its text\n'; } > "$TIERS/intelligence/skills/$name/SKILL.md"
}
tiers_agent effort-xhigh 'tier: light' 'effort: xhigh'
tiers_agent effort-ultra 'effort: ultra'
tiers_agent effort-quoted 'effort: "low"'
tiers_agent effort-typo 'effort: hiigh'
tiers_agent effort-case 'effort: High'
tiers_agent effort-bare 'effort:'
tiers_agent effort-empty 'effort: ""'
# Only the first `effort:` counts, as for every other frontmatter key.
tiers_agent effort-twice 'effort: medium' 'effort: ultra'
printf -- '---\r\nname: effort-crlf\r\ndescription: "CRLF"\r\neffort: max\r\n---\r\n\r\n# Agent\r\n' \
    > "$TIERS/intelligence/agents/effort-crlf.md"
tiers_skill skill-ultra 'effort: ultra'
tiers_skill skill-quoted 'effort: "high"'
tiers_skill skill-typo 'effort: hiigh'
tiers_skill skill-bare 'effort:'
tiers_skill skill-empty 'effort: ""'
tiers_skill skill-plain
RC=0
(cd "$TIERS" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync > "$OUT/effort-sync.txt" 2>&1) || RC=$?
[ "$RC" -eq 0 ] || { echo "FAIL: effort sync exited $RC"; cat "$OUT/effort-sync.txt"; fail=1; }
claude_effort() { chk grep -Fqx "effort: $2" "$TIERS/.claude/agents/$1.md"; }
codex_effort() { chk grep -Fqx "model_reasoning_effort = \"$2\"" "$TIERS/.codex/agents/$1.toml"; }
claude_effort effort-xhigh xhigh;   codex_effort effort-xhigh xhigh
claude_effort effort-ultra max;     codex_effort effort-ultra ultra
claude_effort effort-quoted low;    codex_effort effort-quoted low
claude_effort effort-twice medium;  codex_effort effort-twice medium
claude_effort effort-crlf max;      codex_effort effort-crlf max
# Effort leaves the model alone.
chk grep -Fqx "model: $(default_model claude light)" "$TIERS/.claude/agents/effort-xhigh.md"
chk grep -Fqx "model = \"$(default_model codex light)\"" "$TIERS/.codex/agents/effort-xhigh.toml"
chk eq "$(fm_effort_keys "$TIERS/.claude/agents/effort-twice.md")" "effort: medium"
for agent in effort-typo effort-case effort-bare effort-empty; do
    chk no_effort_key "$TIERS/.claude/agents/$agent.md"
    chknot grep -q 'model_reasoning_effort' "$TIERS/.codex/agents/$agent.toml"
done
# Tools without a per-agent effort field never receive the key.
for agent in effort-xhigh effort-ultra effort-quoted effort-typo effort-twice effort-crlf; do
    for rendered in ".github/agents/$agent.agent.md" ".opencode/agents/$agent.md" \
        ".agents/agents/$agent.md" ".cursor/agents/$agent.md"; do
        chk no_effort_key "$TIERS/$rendered"
    done
done
# The frontmatter is rewritten, never the body that documents it.
chk grep -Fqx 'effort: a body line keeps its text' "$TIERS/.claude/agents/effort-typo.md"
chk grep -Fqx 'effort: a body line keeps its text' "$TIERS/.cursor/agents/effort-xhigh.md"
# Skills: Claude's level in .claude, the neutral value as written in the shared
# tree, nothing where the tool has no field, and nothing for an off-scale or
# empty value anywhere.
chk grep -Fqx 'effort: max' "$TIERS/.claude/skills/skill-ultra/SKILL.md"
chk grep -Fqx 'effort: ultra' "$TIERS/.agents/skills/skill-ultra/SKILL.md"
chk grep -Fqx 'effort: "high"' "$TIERS/.claude/skills/skill-quoted/SKILL.md"
chk grep -Fqx 'effort: "high"' "$TIERS/.agents/skills/skill-quoted/SKILL.md"
for skill in skill-ultra skill-quoted skill-typo skill-bare skill-empty skill-plain; do
    for tree in .github/skills .cursor/skills; do
        chk no_effort_key "$TIERS/$tree/$skill/SKILL.md"
    done
done
for skill in skill-typo skill-bare skill-empty skill-plain; do
    for tree in .claude/skills .agents/skills; do
        chk no_effort_key "$TIERS/$tree/$skill/SKILL.md"
        chk grep -Fqx 'effort: a body line keeps its text' "$TIERS/$tree/$skill/SKILL.md"
    done
done
# One warning per off-scale source, naming it and the value; none for empty.
for source in agents/effort-typo.md:hiigh agents/effort-case.md:High skills/skill-typo/SKILL.md:hiigh; do
    chk eq "$(grep -c "^WARNING: .*intelligence/${source%%:*}:[0-9]* effort \"${source##*:}\" is not one of low, medium, high, xhigh, max, ultra" "$OUT/effort-sync.txt")" 1
done
chknot grep -Eq 'WARN(ING)?: .*(effort-bare|effort-empty|skill-bare|skill-empty|effort-quoted|effort-twice|effort-crlf|skill-quoted)' "$OUT/effort-sync.txt"
chk eq "$(grep -Ec 'WARN(ING)?: .*effort "' "$OUT/effort-sync.txt")" 3
# `sync --compact`, which `init` runs, keeps only unindented WARNING: lines, so
# the typo reaches it: on a full render, and on the unchanged run that replays it.
(cd "$TIERS" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync --compact --force > "$OUT/effort-compact.txt" 2>&1) \
    || { echo "FAIL: effort compact sync"; cat "$OUT/effort-compact.txt"; fail=1; }
(cd "$TIERS" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync --compact > "$OUT/effort-replay.txt" 2>&1) \
    || { echo "FAIL: effort compact replay"; cat "$OUT/effort-replay.txt"; fail=1; }
for report in effort-compact effort-replay; do
    chk grep -q '^WARNING: .*intelligence/agents/effort-typo.md:[0-9]* effort "hiigh" is not one of' "$OUT/$report.txt"
    chk grep -q '^WARNING: .*intelligence/skills/skill-typo/SKILL.md:[0-9]* effort "hiigh" is not one of' "$OUT/$report.txt"
done

echo "== skills only the owner invokes get Codex's policy at sync =="
# The source states the intent once; Codex's own file is the engine's to write,
# for project skills as much as package ones, and an author's own file is kept.
POL="$OUT/skill-policy"
mkdir -p "$POL/intelligence/skills/owner-only" "$POL/intelligence/skills/own-policy/agents" \
    "$POL/intelligence/skills/open"
git -C "$POL" init --quiet
cat > "$POL/intelligence.yaml" <<EOF
project:
  name: skill-policy

schema_version: "$ENGINE_VER"

sources:
  rules:
  agents:
  skills:
    - "intelligence/skills"

targets:
  agents: { enabled: true, output: "AGENTS.md" }
  codex: { enabled: true, output: ".codex" }
EOF
printf -- '---\nname: owner-only\ndescription: "Owner only"\ndisable-model-invocation: true\n---\n\n# Owner only\n' \
    > "$POL/intelligence/skills/owner-only/SKILL.md"
printf -- '---\nname: own-policy\ndescription: "Own policy"\ndisable-model-invocation: true\n---\n\n# Own policy\n' \
    > "$POL/intelligence/skills/own-policy/SKILL.md"
printf '%s\n' 'policy:' '  allow_implicit_invocation: false' 'interface:' '  display_name: "Kept"' \
    > "$POL/intelligence/skills/own-policy/agents/openai.yaml"
printf -- '---\nname: open\ndescription: "Open"\n---\n\n# Open\n' > "$POL/intelligence/skills/open/SKILL.md"
(cd "$POL" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync > "$OUT/policy-sync.txt" 2>&1) \
    || { echo "FAIL: skill-policy sync"; cat "$OUT/policy-sync.txt"; fail=1; }
chk grep -Fqx '  allow_implicit_invocation: false' "$POL/.agents/skills/owner-only/agents/openai.yaml"
chk grep -Fqx '  display_name: "Kept"' "$POL/.agents/skills/own-policy/agents/openai.yaml"
# A file that already sets the policy is kept byte for byte, never given the key twice.
chk cmp -s "$POL/intelligence/skills/own-policy/agents/openai.yaml" "$POL/.agents/skills/own-policy/agents/openai.yaml"
chknot test -e "$POL/.agents/skills/open/agents"
chknot test -e "$POL/intelligence/skills/owner-only/agents"
# Dropping the field drops the derived file on the next sync.
printf -- '---\nname: owner-only\ndescription: "Owner only"\n---\n\n# Owner only\n' \
    > "$POL/intelligence/skills/owner-only/SKILL.md"
(cd "$POL" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync > "$OUT/policy-resync.txt" 2>&1) \
    || { echo "FAIL: skill-policy resync"; cat "$OUT/policy-resync.txt"; fail=1; }
chknot test -e "$POL/.agents/skills/owner-only/agents/openai.yaml"
# An author's file that sets no policy gains one in the output copy, inside an
# existing `policy:` block or as a new one, with every other line kept; the
# source file stays as written.
pol_skill() {
    mkdir -p "$POL/intelligence/skills/$1/agents"
    printf -- '---\nname: %s\ndescription: "%s"\ndisable-model-invocation: true\n---\n\n# %s\n' "$1" "$1" "$1" \
        > "$POL/intelligence/skills/$1/SKILL.md"
    printf '%s\n' "${@:2}" > "$POL/intelligence/skills/$1/agents/openai.yaml"
}
pol_skill interface-only 'interface:' '  display_name: "Interface only"'
pol_skill policy-block 'policy:' '    products: []' 'interface:' '  display_name: "Block"'
# Only a direct child of `policy:` is the key Codex reads: a deeper one gains
# the direct key beside it, and a flat flow mapping holding it is kept as is.
pol_skill nested-key 'policy:' '  products:' '    allow_implicit_invocation: false'
pol_skill flow-policy 'policy: {allow_implicit_invocation: false}'
(cd "$POL" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync > "$OUT/policy-merge.txt" 2>&1) \
    || { echo "FAIL: skill-policy merge sync"; cat "$OUT/policy-merge.txt"; fail=1; }
chk grep -Fqx '  allow_implicit_invocation: false' "$POL/.agents/skills/interface-only/agents/openai.yaml"
chk grep -Fqx '  display_name: "Interface only"' "$POL/.agents/skills/interface-only/agents/openai.yaml"
chknot grep -q 'allow_implicit_invocation' "$POL/intelligence/skills/interface-only/agents/openai.yaml"
chk grep -Fqx '    allow_implicit_invocation: false' "$POL/.agents/skills/policy-block/agents/openai.yaml"
chk grep -Fqx '    products: []' "$POL/.agents/skills/policy-block/agents/openai.yaml"
chk test "$(grep -c '^policy:' "$POL/.agents/skills/policy-block/agents/openai.yaml")" -eq 1
chk grep -Fqx '  allow_implicit_invocation: false' "$POL/.agents/skills/nested-key/agents/openai.yaml"
chk grep -Fqx '    allow_implicit_invocation: false' "$POL/.agents/skills/nested-key/agents/openai.yaml"
chk cmp -s "$POL/intelligence/skills/flow-policy/agents/openai.yaml" "$POL/.agents/skills/flow-policy/agents/openai.yaml"
# A file whose policy contradicts the field, or states it in a shape sync does
# not read as the plain boolean, refuses the render and restores it.
pol_skill contradicts 'policy:' '  allow_implicit_invocation: true'
pol_skill quoted-false 'policy:' '  allow_implicit_invocation: "false"'
pol_skill inline-true 'policy: {allow_implicit_invocation: true}'
pol_skill inline-string 'policy: "allow_implicit_invocation: false"'
RC=0
(cd "$POL" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync > "$OUT/policy-refuse.txt" 2>&1) || RC=$?
chk test "$RC" -ne 0
chk grep -Fq 'contradicts sets disable-model-invocation: true, but its agents/openai.yaml sets policy.allow_implicit_invocation: true' \
    "$OUT/policy-refuse.txt"
chk grep -Fq 'quoted-false sets disable-model-invocation: true, but its agents/openai.yaml sets policy.allow_implicit_invocation: "false"' \
    "$OUT/policy-refuse.txt"
chk grep -Fq 'inline-true sets disable-model-invocation: true, but its agents/openai.yaml has policy: {allow_implicit_invocation: true}' \
    "$OUT/policy-refuse.txt"
chk grep -Fq 'inline-string sets disable-model-invocation: true, but its agents/openai.yaml has policy: "allow_implicit_invocation: false"' \
    "$OUT/policy-refuse.txt"
for skill in contradicts quoted-false inline-true inline-string; do
    chknot test -e "$POL/.agents/skills/$skill"
    rm -rf "$POL/intelligence/skills/$skill"
done
chk grep -Fqx '  display_name: "Interface only"' "$POL/.agents/skills/interface-only/agents/openai.yaml"

echo "== symlinks in a skill source: rendered inside it, left out otherwise =="
# Decision 0017. A link that resolves inside its own skills source renders as
# the regular file or directory it points at, in every skill tree, with the
# quoting and Codex policy any other file gets. One that resolves outside the
# source (the repository included), nowhere, or to a directory enclosing it is
# left out with one WARNING: line naming the skill and the link itself. No tree
# ever holds a link. Probed: some hosts cannot create a symlink and copy instead.
LNK="$OUT/skill-links"
LS="$LNK/intelligence/skills"
EL="$OUT/skill-links-elsewhere"
mkdir -p "$LS/_shared/aliased/references" "$LS/_shared/assets" "$LS/_shared/agents-dir" \
    "$LS/plain/references" "$EL/outside" "$EL/agents" "$LNK/beside-source/rel-out"
if ln -s ../../_shared/aliased "$LS/plain/probe" 2>/dev/null && [ -L "$LS/plain/probe" ]; then
    rm "$LS/plain/probe"
    git -C "$LNK" init --quiet
    cat > "$LNK/intelligence.yaml" <<EOF
project:
  name: skill-links

schema_version: "$ENGINE_VER"

sources:
  rules:
  agents:
  skills:
    - "intelligence/skills"

targets:
  agents: { enabled: true, output: "AGENTS.md" }
  claude: { enabled: true, output: ".claude" }
  codex: { enabled: true, output: ".codex" }
  cursor: { enabled: true, output: ".cursor" }
  copilot: { enabled: true, output: ".github" }
  opencode: { enabled: true, output: ".opencode" }
  pi: { enabled: true, output: ".pi" }
EOF
    # link_skill <dir> <name> [frontmatter line] — a minimal skill.
    link_skill() {
        mkdir -p "$1"
        {
            printf -- '---\nname: %s\ndescription: "%s"\n' "$2" "$2"
            [ -z "${3:-}" ] || printf '%s\n' "$3"
            printf -- '---\n\n# %s\n' "$2"
        } > "$1/SKILL.md"
    }
    printf 'ELSEWHERE_MARKER\n' > "$EL/host.txt"
    # Inside the source: a whole skill directory, a resource file and
    # directory, a link inside a linked directory, SKILL.md itself, an
    # authored agents/openai.yaml and the agents directory holding one.
    link_skill "$LS/plain" plain
    printf 'GUIDE_MARKER\n' > "$LS/_shared/guide.md"
    printf '\000\001binary\377' > "$LS/_shared/assets/data.bin"
    ln -s ../../_shared/guide.md "$LS/plain/references/guide.md"
    ln -s ../_shared/assets "$LS/plain/assets"
    link_skill "$LS/_shared/aliased" aliased 'effort: ultra'
    ln -s ../../guide.md "$LS/_shared/aliased/references/guide.md"
    ln -s _shared/aliased "$LS/aliased"
    mkdir -p "$LS/linked-md"
    printf -- '---\nname: linked-md\ndescription: Linked: colon\neffort: ultra\ndisable-model-invocation: true\n---\n\n# Linked md\n' \
        > "$LS/_shared/linked-md.md"
    ln -s ../_shared/linked-md.md "$LS/linked-md/SKILL.md"
    link_skill "$LS/policy-linked" policy-linked 'disable-model-invocation: true'
    mkdir -p "$LS/policy-linked/agents"
    printf '%s\n' 'policy:' '  allow_implicit_invocation: false' 'interface:' '  display_name: "Linked policy"' \
        > "$LS/_shared/openai.yaml"
    ln -s ../../_shared/openai.yaml "$LS/policy-linked/agents/openai.yaml"
    link_skill "$LS/agents-linked" agents-linked 'disable-model-invocation: true'
    printf '%s\n' 'interface:' '  display_name: "Agents dir"' > "$LS/_shared/agents-dir/openai.yaml"
    ln -s ../_shared/agents-dir "$LS/agents-linked/agents"
    # Outside the source, nowhere, or enclosing itself.
    link_skill "$EL/outside" outside
    ln -s "$EL/outside" "$LS/outside"
    mkdir -p "$EL/outside-empty"
    ln -s "$EL/outside-empty" "$LS/outside-empty"
    mkdir -p "$LS/outside-md"
    printf -- '---\nname: outside-md\ndescription: "ELSEWHERE_MARKER"\n---\n' > "$EL/outside-md.md"
    ln -s "$EL/outside-md.md" "$LS/outside-md/SKILL.md"
    link_skill "$LNK/beside-source/rel-out" rel-out
    ln -s ../../beside-source/rel-out "$LS/rel-out"
    ln -s "$EL/host.txt" "$LS/plain/references/host"
    ln -s ../../_shared/missing.md "$LS/plain/references/gone"
    ln -s . "$LS/plain/loop"
    ln -s missing-skill "$LS/dangling"
    link_skill "$LS/esc-policy" esc-policy 'disable-model-invocation: true'
    mkdir -p "$LS/esc-policy/agents"
    printf '%s\n' 'policy:' '  allow_implicit_invocation: true' > "$EL/openai.yaml"
    ln -s "$EL/openai.yaml" "$LS/esc-policy/agents/openai.yaml"
    link_skill "$LS/esc-agents" esc-agents 'disable-model-invocation: true'
    printf '%s\n' 'policy:' '  allow_implicit_invocation: true' > "$EL/agents/openai.yaml"
    ln -s "$EL/agents" "$LS/esc-agents/agents"
    # A link an older sync copied verbatim is pruned, not kept.
    mkdir -p "$LNK/.claude/skills"
    ln -s "$EL/outside" "$LNK/.claude/skills/stale-link"
    (cd "$LNK" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync > "$OUT/skill-links.txt" 2>&1) \
        || { echo "FAIL: skill-links sync"; cat "$OUT/skill-links.txt"; fail=1; }
    TREES=("$LNK/.claude/skills" "$LNK/.agents/skills" "$LNK/.cursor/skills" "$LNK/.github/skills")
    links_left="$(find "${TREES[@]}" "$LNK/.opencode" "$LNK/.pi" -type l 2>&1)"
    [ -z "$links_left" ] || { echo "FAIL: generated output holds symlinks:"; printf '%s\n' "$links_left"; fail=1; }
    chknot grep -rq ELSEWHERE_MARKER "${TREES[@]}" "$LNK/.opencode" "$LNK/.pi" "$LNK/AGENTS.md"
    for tree in "${TREES[@]}"; do
        for skill in plain aliased linked-md policy-linked agents-linked esc-policy esc-agents; do
            chk test -f "$tree/$skill/SKILL.md"
        done
        for skill in outside outside-empty outside-md rel-out dangling stale-link _shared; do
            chknot test -e "$tree/$skill"
        done
        chk grep -Fqx 'GUIDE_MARKER' "$tree/plain/references/guide.md"
        chk grep -Fqx 'GUIDE_MARKER' "$tree/aliased/references/guide.md"
        chk cmp -s "$LS/_shared/assets/data.bin" "$tree/plain/assets/data.bin"
        chknot test -e "$tree/plain/references/host"
        chknot test -e "$tree/plain/references/gone"
        chknot test -e "$tree/plain/loop"
        # SKILL.md behind a link gets the frontmatter quoting every SKILL.md gets.
        chk grep -Fqx 'description: "Linked: colon"' "$tree/linked-md/SKILL.md"
    done
    # ... and the effort each tree renders (#47): Claude's level, the neutral
    # value in the shared tree, no key where the tool has no field.
    for skill in linked-md aliased; do
        chk grep -Fqx 'effort: max' "$LNK/.claude/skills/$skill/SKILL.md"
        chk grep -Fqx 'effort: ultra' "$LNK/.agents/skills/$skill/SKILL.md"
        chknot grep -q '^effort:' "$LNK/.github/skills/$skill/SKILL.md"
        chknot grep -q '^effort:' "$LNK/.cursor/skills/$skill/SKILL.md"
    done
    for skill in plain aliased linked-md policy-linked agents-linked esc-policy esc-agents; do
        chk test -f "$LNK/.opencode/commands/$skill.md"
        chk grep -q "intelligence/skills/$skill/SKILL.md" "$LNK/AGENTS.md"
    done
    for skill in outside outside-empty outside-md rel-out dangling; do
        chknot test -e "$LNK/.opencode/commands/$skill.md"
        chknot grep -q "intelligence/skills/$skill/" "$LNK/AGENTS.md"
    done
    # Codex reads the policy from the materialized files: derived for a linked
    # SKILL.md, kept byte for byte when a linked file already sets it, added to
    # a file in a linked agents directory, and derived in place of one left out.
    OPEN="$LNK/.agents/skills"
    chk grep -Fqx '  allow_implicit_invocation: false' "$OPEN/linked-md/agents/openai.yaml"
    chk cmp -s "$LS/_shared/openai.yaml" "$OPEN/policy-linked/agents/openai.yaml"
    chk grep -Fqx '  allow_implicit_invocation: false' "$OPEN/agents-linked/agents/openai.yaml"
    chk grep -Fqx '  display_name: "Agents dir"' "$OPEN/agents-linked/agents/openai.yaml"
    chknot grep -q 'allow_implicit_invocation' "$LS/_shared/agents-dir/openai.yaml"
    for skill in esc-policy esc-agents; do
        chk grep -q '^# Generated by intelligence-sync' "$OPEN/$skill/agents/openai.yaml"
        chknot grep -q 'allow_implicit_invocation: true' "$OPEN/$skill/agents/openai.yaml"
    done
    # One warning per link, naming the skill and the path that is the link.
    S_REL="intelligence/skills"
    WANT_WARNINGS=(
        "WARNING: skill 'outside' is left out of every output: $S_REL/outside is a symlink that resolves outside $S_REL"
        "WARNING: skill 'outside-empty' is left out of every output: $S_REL/outside-empty is a symlink that resolves outside $S_REL"
        "WARNING: skill 'outside-md' is left out of every output: $S_REL/outside-md/SKILL.md is a symlink that resolves outside $S_REL"
        "WARNING: skill 'rel-out' is left out of every output: $S_REL/rel-out is a symlink that resolves outside $S_REL"
        "WARNING: skill 'dangling' is left out of every output: $S_REL/dangling is a dangling symlink"
        "WARNING: skill 'plain' renders without references/host: $S_REL/plain/references/host is a symlink that resolves outside $S_REL"
        "WARNING: skill 'plain' renders without references/gone: $S_REL/plain/references/gone is a dangling symlink"
        "WARNING: skill 'plain' renders without loop: $S_REL/plain/loop is a symlink to a directory that encloses it"
        "WARNING: skill 'esc-policy' renders without agents/openai.yaml: $S_REL/esc-policy/agents/openai.yaml is a symlink that resolves outside $S_REL"
        "WARNING: skill 'esc-agents' renders without agents: $S_REL/esc-agents/agents is a symlink that resolves outside $S_REL"
    )
    for want in "${WANT_WARNINGS[@]}"; do
        [ "$(grep -Fxc -- "$want" "$OUT/skill-links.txt")" = 1 ] \
            || { echo "FAIL: expected exactly one line: $want"; fail=1; }
    done
    chk test "$(grep -c '^WARNING: skill ' "$OUT/skill-links.txt")" -eq "${#WANT_WARNINGS[@]}"
    # The same warnings are compact output's to keep.
    (cd "$LNK" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync --compact --force > "$OUT/skill-links-compact.txt" 2>&1) \
        || { echo "FAIL: skill-links compact sync"; cat "$OUT/skill-links-compact.txt"; fail=1; }
    for want in "${WANT_WARNINGS[@]}"; do
        chk grep -Fqx -- "$want" "$OUT/skill-links-compact.txt"
    done
else
    echo "  NOTE: this host cannot create a symlink — symlinks in a skill source not exercised"
fi

echo "== Copilot output is ignored by default; commit_output keeps it tracked =="
# Copilot in the editor reads its files from disk after sync, as Cursor and
# Claude Code do, so the default ignores them. Only Copilot on github.com reads
# the repository, and committing for it is the project's opt-in (decision 0020).
COP="$OUT/copilot-policy"
mkdir -p "$COP/.github/workflows" "$COP/intelligence/rules" "$COP/intelligence/agents" \
    "$COP/intelligence/skills/cop-skill"
printf 'name: ci\non: push\n' > "$COP/.github/workflows/ci.yml"
printf -- '---\npaths:\n  - "src/**"\ndescription: "scoped"\n---\n\n# Scoped\n' \
    > "$COP/intelligence/rules/cop-scoped.md"
printf -- '---\nname: cop-agent\ndescription: "An agent"\ntier: standard\naccess: full\n---\n\n# Agent\n' \
    > "$COP/intelligence/agents/cop-agent.md"
printf -- '---\nname: cop-skill\ndescription: "A skill"\n---\n\n# Skill\n' \
    > "$COP/intelligence/skills/cop-skill/SKILL.md"
git -C "$COP" init --quiet
COP_GENERATED=(.github/instructions/cop-scoped.instructions.md .github/agents/cop-agent.agent.md
    .github/skills/cop-skill/SKILL.md)
# cop_commit_output <yaml-value|""> — rewrite the Copilot entry through a temp
# file; BSD sed -i takes a suffix argument, so in-place editing is not portable.
cop_commit_output() {
    awk -v setting="$1" '{
        sub(/\r$/, "")
        if ($0 !~ /^  copilot:/) { print; next }
        if (setting == "") print "  copilot: { enabled: true, output: \".github\" }"
        else print "  copilot: { enabled: true, output: \".github\", commit_output: " setting " }"
    }' "$COP/intelligence.yaml" > "$COP/intelligence.yaml.tmp"
    mv "$COP/intelligence.yaml.tmp" "$COP/intelligence.yaml"
}
run_in "$COP" init --targets copilot --bare
chk test "$RC" -eq 0
printf '%s\n' "$OUTPUT" > "$OUT/copilot-init.txt"
chk grep -Fq 'targets.copilot.commit_output: true' "$OUT/copilot-init.txt"
chknot grep -Fq 'AGENTS.md, and .github/' "$OUT/copilot-init.txt"
for sub in instructions prompts agents skills; do
    chk grep -Fqx ".github/$sub/" "$COP/.gitignore"
done
# `.github/` holds workflows, templates and hand-written files: never wholesale.
chknot grep -Fqx '.github/' "$COP/.gitignore"
for path in "${COP_GENERATED[@]}"; do
    chk test -f "$COP/$path"
    chk git -C "$COP" check-ignore -q "$path"
done
chknot git -C "$COP" check-ignore -q .github/workflows/ci.yml
chknot git -C "$COP" check-ignore -q AGENTS.md
run_in "$COP" status --check
chk test "$RC" -eq 0

# Opting in: until init withdraws the lines, status --check names them.
cop_commit_output true
run_in "$COP" status --check
chk test "$RC" -ne 0
printf '%s\n' "$OUTPUT" | grep -Fq "keeps '.github/agents/' tracked, but .gitignore still ignores it" \
    || { echo "FAIL: status --check did not report the stale Copilot ignore"; fail=1; }
run_in "$COP" init
chk test "$RC" -eq 0
for sub in instructions prompts agents skills; do
    chknot grep -Fqx ".github/$sub/" "$COP/.gitignore"
done
chk grep -Fqx '.intelligence/' "$COP/.gitignore"
for path in "${COP_GENERATED[@]}"; do
    chknot git -C "$COP" check-ignore -q "$path"
done
cp "$COP/.gitignore" "$OUT/copilot-commit.gitignore"
run_in "$COP" init --no-sync
chk cmp -s "$OUT/copilot-commit.gitignore" "$COP/.gitignore"
run_in "$COP" status --check
chk test "$RC" -eq 0
git -C "$COP" add -A
git -C "$COP" -c user.email=t@t -c user.name=t commit --quiet -m "committed Copilot output"
chk test -n "$(git -C "$COP" ls-files .github/agents/cop-agent.agent.md)"

# Back to the default — the state an existing project with committed output
# reaches on this release. init restores the ignores; Git keeps tracking what
# it already tracks, so init names each generated file to untrack and never
# untracks one itself.
cop_commit_output ""
# Until init runs, status --check names each missing line and the command
# that adds it.
run_in "$COP" status --check
chk test "$RC" -ne 0
printf '%s\n' "$OUTPUT" | grep -Fq "Git policy is missing '.github/agents/' — run 'intelligence init'" \
    || { echo "FAIL: status --check did not name init for a missing Copilot ignore"; fail=1; }
run_in "$COP" init
chk test "$RC" -eq 0
for sub in instructions prompts agents skills; do
    chk test "$(grep -Fxc ".github/$sub/" "$COP/.gitignore")" -eq 1
done
for path in "${COP_GENERATED[@]}"; do
    printf '%s\n' "$OUTPUT" | grep -Fq "git rm --cached -- '$path'" \
        || { echo "FAIL: init did not name the tracked generated file $path"; fail=1; }
done
if printf '%s\n' "$OUTPUT" | grep -Fq ".github/workflows/ci.yml"; then
    echo "FAIL: init told the project to untrack a hand-written workflow"
    fail=1
fi
chk test -n "$(git -C "$COP" ls-files .github/agents/cop-agent.agent.md)"
run_in "$COP" status --check
chk test "$RC" -eq 0

echo "== fresh clone of migrated project + sync =="
git -C "$LEG" -c user.email=t@t -c user.name=t add -A
git -C "$LEG" -c user.email=t@t -c user.name=t commit --quiet -m migrated
CLONE2="$OUT/clone2"
git clone --quiet "file://$LEG" "$CLONE2"
(cd "$CLONE2" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync)
chk grep -q 'LEGACY_PACK_MARKER' "$CLONE2/AGENTS.md"

echo "== legacy content kept outside intelligence/ stays the content directory =="
# The converted manifest names the legacy directory, so AGENTS.md, protected
# outputs and project adapters point at the directory that exists on disk. The
# lowercase layout above keeps the default and writes nothing.
chknot grep -q 'intelligence_dir' "$LEG/intelligence.yaml"
for layout in block absent dotted; do
    CAP="$OUT/legacy-capital-$layout"
    mkdir -p "$CAP/Intelligence/project/rules" "$CAP/Intelligence/adapters"
    stage_vendored "$CAP/Intelligence"
    printf '# Ctx\n\nCAPITAL_CONTEXT_MARKER\n' > "$CAP/Intelligence/project/rules/context.md"
    {
        if [ "$layout" = block ]; then
            printf 'project:  # the project\n  name: capital-fixture\n\n'
        fi
        printf 'sync_version: "%s"\n\n' "$ENGINE_VER"
        if [ "$layout" = dotted ]; then
            printf 'sources:\n  rules:\n    - "./Intelligence/project/rules/"\n    - "Intelligence/sync/rules"\n'
        else
            printf 'sources:\n  rules:\n    - "Intelligence/project/rules"\n    - "Intelligence/sync/rules"\n'
        fi
        printf '  agents:\n    - "Intelligence/sync/agents"\n  skills:\n    - "Intelligence/sync/skills"\n\n'
        printf 'targets:\n  agents: { enabled: true, output: "AGENTS.md" }\n  claude: { enabled: true, output: ".claude" }\n'
    } > "$CAP/Intelligence/config.yaml"
    git -C "$CAP" init --quiet
    run_in "$CAP" init --apply --force
    chk test "$RC" -eq 0
    chk test "$(grep -c '^  intelligence_dir: "Intelligence"$' "$CAP/intelligence.yaml")" -eq 1
    chk test "$(grep -c '^project:' "$CAP/intelligence.yaml")" -eq 1
    chk grep -qF 'Source of truth: `Intelligence/`' "$CAP/AGENTS.md"
    chk grep -q 'CAPITAL_CONTEXT_MARKER' "$CAP/AGENTS.md"
    run_in "$CAP" status --check
    chk test "$RC" -eq 0
done
chk grep -q '^  name: capital-fixture$' "$OUT/legacy-capital-block/intelligence.yaml"
# Config-only: every source is the vendored module, which conversion moves into
# the store and removes, so no project content stays to name.
CFG="$OUT/legacy-capital-config-only"
mkdir -p "$CFG"
stage_vendored "$CFG/Intelligence"
{
    printf 'sync_version: "%s"\n\n' "$ENGINE_VER"
    printf 'sources:\n  rules:\n    - "Intelligence/sync/rules"\n'
    printf '  agents:\n    - "Intelligence/sync/agents"\n  skills:\n    - "Intelligence/sync/skills"\n\n'
    printf 'targets:\n  agents: { enabled: true, output: "AGENTS.md" }\n'
} > "$CFG/Intelligence/config.yaml"
git -C "$CFG" init --quiet
run_in "$CFG" init --apply --force
chk test "$RC" -eq 0
chknot grep -q 'intelligence_dir' "$CFG/intelligence.yaml"

[ "$fail" -eq 0 ] && echo "MIGRATE-E2E: ALL OK"
exit "$fail"
