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
chk grep -Fqx '.agents/rules/' "$FRESH/.gitignore"
chk grep -Fqx '.agents/agents/' "$FRESH/.gitignore"
chk grep -Fqx '.agents/skills/' "$FRESH/.gitignore"
# `.agents/` is a shared workspace root, not adapter-owned output: ignoring it
# whole would hide hand-written workspace content the adapter never writes.
chknot grep -Fqx '.agents/' "$FRESH/.gitignore"
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
    chk grep -Fqx '.agents/**' "$FRESH/$policy"
done
(cd "$FRESH" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" init --no-sync >/dev/null)
for policy in .vscodeignore .npmignore .dockerignore; do
    count="$(grep -Fxc '# Intelligence development context and generated output' "$FRESH/$policy" || true)"
    [ "$count" -eq 1 ] || { echo "FAIL: publisher-ignore block duplicated in $policy"; fail=1; }
done
chk grep -q '# Claude marker' "$FRESH/intelligence/_backup/CLAUDE.md"
chk grep -q '# Gemini marker' "$FRESH/intelligence/_backup/GEMINI.md"
chk test -f "$FRESH/intelligence/_backup/.cursorrules"
chknot test -e "$FRESH/CLAUDE.md"
# GEMINI.md outranks AGENTS.md in Antigravity's rule precedence: left in place
# it would silently override every synced rule, so onboarding quarantines it.
chknot test -e "$FRESH/GEMINI.md"
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
    intelligence-update intelligence-update-context
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
    intelligence-compact-context intelligence-install-adapter intelligence-uninstall-adapter)
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

echo "== fresh clone of migrated project + sync =="
git -C "$LEG" -c user.email=t@t -c user.name=t add -A
git -C "$LEG" -c user.email=t@t -c user.name=t commit --quiet -m migrated
CLONE2="$OUT/clone2"
git clone --quiet "file://$LEG" "$CLONE2"
(cd "$CLONE2" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" sync)
chk grep -q 'LEGACY_PACK_MARKER' "$CLONE2/AGENTS.md"

[ "$fail" -eq 0 ] && echo "MIGRATE-E2E: ALL OK"
exit "$fail"
