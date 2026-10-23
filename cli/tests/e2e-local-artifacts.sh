#!/bin/bash
# Hermetic e2e for decision 0021: one source catalog names every artifact,
# applies overrides everywhere, refuses ambiguous names, and keeps a local
# rule, agent or skill out of every output Git tracks.
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

# run <dir> <args>... — the CLI in a project; status in RC, output in LOG.
RC=0
LOG="$OUT/log"
run() {
    local dir="$1"
    shift
    RC=0
    (cd "$dir" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" "$@") > "$LOG" 2>&1 || RC=$?
}
commit_all() { git -C "$1" add -A >/dev/null 2>&1 && git -C "$1" commit -qm "$2" >/dev/null 2>&1; }
# snapshot <dir> — one line naming every generated file and its bytes.
snapshot() {
    (cd "$1" && find AGENTS.md .claude .cursor .codex .github .agents .opencode -type f 2>/dev/null \
        | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done)
}

TARGETS=agents,claude,cursor,codex,copilot,opencode
P="$OUT/project"
mkdir -p "$P"
git -C "$P" init --quiet
git -C "$P" config user.email e2e@example.com
git -C "$P" config user.name e2e
git -C "$P" config core.autocrlf false

echo "== init writes the local artifact patterns into the managed block =="
run "$P" init --bare --targets "$TARGETS"
is "init exit" 0 "$RC"
for pattern in 'intelligence/rules/*.local.md' 'intelligence/agents/*.local.md' 'intelligence/skills/*.local/'; do
    chk grep -Fqx "$pattern" "$P/.gitignore"
done
for path in intelligence/rules/me.local.md intelligence/rules/.environment.local.md \
    intelligence/agents/helper.local.md intelligence/skills/deploy.local/SKILL.md; do
    chk git -C "$P" check-ignore -q --no-index "$path"
done
for path in intelligence/rules/team.md intelligence/rules/.draft.md intelligence/skills/deploy/SKILL.md; do
    chknot git -C "$P" check-ignore -q --no-index "$path"
done
run "$P" status --check
is "status --check on a fresh project" 0 "$RC"

echo "== status --check reports a missing local pattern; init restores it =="
grep -Fvx 'intelligence/agents/*.local.md' "$P/.gitignore" > "$OUT/gitignore" && cp "$OUT/gitignore" "$P/.gitignore"
run "$P" status --check
is "status --check exit" 1 "$RC"
chk grep -Fq "local artifact Git policy is missing 'intelligence/agents/*.local.md'" "$LOG"
run "$P" init
is "init on the project" 0 "$RC"
chk grep -Fqx 'intelligence/agents/*.local.md' "$P/.gitignore"
run "$P" status --check
is "status --check after init" 0 "$RC"

mkdir -p "$P/intelligence/rules"
printf '# Team\n\nTEAM_BODY\n' > "$P/intelligence/rules/team.md"
run "$P" sync
is "sync of the team rule" 0 "$RC"
commit_all "$P" start
cp "$P/AGENTS.md" "$OUT/AGENTS.committed"

echo "== local artifacts leave AGENTS.md and the work tree untouched =="
mkdir -p "$P/intelligence/agents" "$P/intelligence/skills/deploy.local/references"
printf '# Environment\n\nLOCAL_ENV_BODY\n' > "$P/intelligence/rules/.environment.local.md"
printf -- '---\npaths:\n  - "src/**"\n---\n\nLOCAL_SCOPED_BODY\n' > "$P/intelligence/rules/scoped.local.md"
printf -- '---\nname: helper\ndescription: "Local helper"\ntier: standard\naccess: readonly\n---\n\nLOCAL_AGENT_BODY\n' \
    > "$P/intelligence/agents/helper.local.md"
printf -- '---\nname: deploy\ndescription: "Deploy from this machine"\n---\n\nLOCAL_SKILL_BODY\n' \
    > "$P/intelligence/skills/deploy.local/SKILL.md"
printf 'notes\n' > "$P/intelligence/skills/deploy.local/references/notes.md"
run "$P" sync
is "sync with local artifacts" 0 "$RC"
chk cmp -s "$OUT/AGENTS.committed" "$P/AGENTS.md"
for word in environment scoped helper deploy LOCAL_; do
    chknot grep -q "$word" "$P/AGENTS.md"
done
is "work tree after sync" "" "$(git -C "$P" status --porcelain)"

echo "== status --check names a tracked file with a local name =="
# .gitignore never applies to a tracked file, so Git would share what the
# engine renders as local.
run "$P" status --check
is "status --check with untracked local artifacts" 0 "$RC"
git -C "$P" add -f intelligence/rules/.environment.local.md intelligence/skills/deploy.local
run "$P" status --check
is "status --check with tracked local artifacts" 1 "$RC"
chk grep -Fq 'intelligence/rules/.environment.local.md is tracked by Git' "$LOG"
chk grep -Fq 'intelligence/skills/deploy.local/ is tracked by Git' "$LOG"
chknot grep -Fq 'notes.md is tracked' "$LOG"
chknot grep -Fq 'scoped.local.md is tracked' "$LOG"
git -C "$P" rm -q -r --cached intelligence/rules/.environment.local.md intelligence/skills/deploy.local
run "$P" status --check
is "status --check once they are untracked" 0 "$RC"

echo "== local artifacts reach ignored outputs under their names =="
for f in .claude/rules/environment.md .claude/rules/scoped.md .claude/agents/helper.md \
    .claude/skills/deploy/SKILL.md .claude/skills/deploy/references/notes.md .cursor/rules/scoped.mdc \
    .cursor/agents/helper.md .cursor/skills/deploy/SKILL.md .github/instructions/scoped.instructions.md \
    .github/agents/helper.agent.md .github/skills/deploy/SKILL.md .codex/agents/helper.toml \
    .agents/skills/deploy/SKILL.md .opencode/agents/helper.md; do
    chk test -f "$P/$f"
done
chk grep -q LOCAL_ENV_BODY "$P/.claude/rules/environment.md"
chk grep -q 'name = "helper"' "$P/.codex/agents/helper.toml"
# The tracked OpenCode commands directory never names a local skill.
chknot test -e "$P/.opencode/commands/deploy.md"
is "no .local in any output name" "" "$(cd "$P" && find .claude .cursor .github .codex .agents .opencode -name '*.local*' 2>/dev/null)"

echo "== a clone, which has no local artifact, passes sync --check =="
git clone --quiet "$P" "$OUT/clone"
git -C "$OUT/clone" config core.autocrlf false
run "$OUT/clone" sync
is "first sync in the clone" 0 "$RC"
run "$OUT/clone" sync --check
is "sync --check in the clone" 0 "$RC"
chk cmp -s "$OUT/AGENTS.committed" "$OUT/clone/AGENTS.md"

echo "== commit_output: true keeps every local artifact out of Copilot =="
C="$OUT/committed"
cp -R "$P" "$C"
sed 's#copilot: { enabled: true, output: ".github" }#copilot: { enabled: true, output: ".github", commit_output: true }#' \
    "$C/intelligence.yaml" > "$OUT/manifest" && cp "$OUT/manifest" "$C/intelligence.yaml"
chk grep -q 'commit_output: true' "$C/intelligence.yaml"
run "$C" init
is "init with commit_output" 0 "$RC"
commit_all "$C" "track copilot output"
run "$C" sync --force
is "sync with commit_output" 0 "$RC"
for f in .github/instructions/scoped.instructions.md .github/agents/helper.agent.md .github/skills/deploy; do
    chknot test -e "$C/$f"
done
chk test -f "$C/.claude/rules/scoped.md"
is "work tree with tracked Copilot output" "" "$(git -C "$C" status --porcelain)"

echo "== a local and a non-local artifact of one name refuse =="
before="$(snapshot "$P")"
printf '# Team, mine\n' > "$P/intelligence/rules/team.local.md"
run "$P" sync
is "team.local.md beside team.md" 1 "$RC"
chk grep -Fq 'intelligence/rules/team.local.md' "$LOG"
chk grep -Fq 'intelligence/rules/team.md' "$LOG"
is "outputs after the refusal" "$before" "$(snapshot "$P")"
rm "$P/intelligence/rules/team.local.md"
printf '# Team, dot\n' > "$P/intelligence/rules/.team.md"
run "$P" sync
is ".team.md beside team.md" 1 "$RC"
chk grep -Fq 'intelligence/rules/.team.md' "$LOG"
chk grep -Fq 'intelligence/rules/team.md' "$LOG"
is "outputs after the second refusal" "$before" "$(snapshot "$P")"
rm "$P/intelligence/rules/.team.md"
mkdir -p "$P/intelligence/skills/deploy"
printf -- '---\nname: deploy\ndescription: "Shared deploy"\n---\n' > "$P/intelligence/skills/deploy/SKILL.md"
run "$P" sync
is "deploy/ beside deploy.local/" 1 "$RC"
chk grep -Fq "both the skill 'deploy'" "$LOG"
rm -rf "$P/intelligence/skills/deploy"
# Across sources: a local artifact can neither override nor yield to a
# committed one.
mkdir -p "$P/shared/rules"
printf '# Environment, shared\n' > "$P/shared/rules/environment.md"
awk '{ print } /^  rules:/ && !done { print "    - \"shared/rules\""; done = 1 }' "$P/intelligence.yaml" > "$OUT/manifest"
cp "$OUT/manifest" "$P/intelligence.yaml"
run "$P" sync
is "shared environment.md under a local one" 1 "$RC"
chk grep -Fq 'shared/rules/environment.md' "$LOG"
chk grep -Fq 'intelligence/rules/.environment.local.md' "$LOG"
chk grep -Fq 'one local and one not' "$LOG"
is "outputs after the cross-source refusal" "$before" "$(snapshot "$P")"
rm "$P/shared/rules/environment.md"
# A source outside the content directory has no ignore pattern, so a local
# file there is the one Git offers to commit; once tracked it is named too.
printf '# Mine\n' > "$P/shared/rules/mine.local.md"
run "$P" status --check
chknot grep -Fq 'mine.local.md is tracked' "$LOG"
git -C "$P" add shared/rules/mine.local.md
run "$P" status --check
is "status --check with a tracked local rule in another source" 1 "$RC"
chk grep -Fq 'shared/rules/mine.local.md is tracked by Git' "$LOG"
git -C "$P" rm -q --cached shared/rules/mine.local.md
rm "$P/shared/rules/mine.local.md"

echo "== AGENTS.md applies source overrides: a same-named rule is listed once =="
# Regression: AGENTS.md listed and inlined `style` once per source while every
# copying adapter rendered only the later one.
printf '# Style\n\nSHARED_STYLE\n' > "$P/shared/rules/style.md"
printf '# Style\n\nPROJECT_STYLE\n' > "$P/intelligence/rules/style.md"
run "$P" sync
is "sync with an override" 0 "$RC"
is "style entries in AGENTS.md" 1 "$(grep -c '^- \[style\]' "$P/AGENTS.md")"
chk grep -Fq -- '- [style](intelligence/rules/style.md) (global)' "$P/AGENTS.md"
chk grep -q PROJECT_STYLE "$P/AGENTS.md"
chknot grep -q SHARED_STYLE "$P/AGENTS.md"
chk grep -q PROJECT_STYLE "$P/.claude/rules/style.md"

echo "== a skill a later source overrides is replaced whole =="
mkdir -p "$P/shared/skills/review/references" "$P/intelligence/skills/review"
printf -- '---\nname: review\ndescription: "Shared review"\n---\nSHARED_REVIEW\n' > "$P/shared/skills/review/SKILL.md"
printf 'shared only\n' > "$P/shared/skills/review/references/shared.md"
printf -- '---\nname: review\ndescription: "Project review"\n---\nPROJECT_REVIEW\n' > "$P/intelligence/skills/review/SKILL.md"
awk '{ print } /^  skills:/ && !done { print "    - \"shared/skills\""; done = 1 }' "$P/intelligence.yaml" > "$OUT/manifest"
cp "$OUT/manifest" "$P/intelligence.yaml"
run "$P" sync
is "sync with a skill override" 0 "$RC"
is "review entries in AGENTS.md" 1 "$(grep -c '^| \[review\]' "$P/AGENTS.md")"
chk grep -Fq '| [review](intelligence/skills/review/SKILL.md) | Project review |' "$P/AGENTS.md"
for tree in .claude/skills .cursor/skills .github/skills .agents/skills; do
    chk grep -q PROJECT_REVIEW "$P/$tree/review/SKILL.md"
    chknot test -e "$P/$tree/review/references/shared.md"
done

echo "== a dotfile source renders in every adapter under its name =="
# Regression: AGENTS.md read `.draft.md` while every other adapter's glob
# skipped it, so the rule reached AGENTS.md only.
printf '# Draft\n\nDRAFT_BODY\n' > "$P/intelligence/rules/.draft.md"
printf -- '---\npaths:\n  - "docs/**"\n---\n\nDOC_DRAFT_BODY\n' > "$P/intelligence/rules/.doc-draft.md"
run "$P" sync
is "sync with dotfile rules" 0 "$RC"
chk grep -Fq -- '- [draft](intelligence/rules/.draft.md) (global)' "$P/AGENTS.md"
chk grep -Fq -- '- [doc-draft](intelligence/rules/.doc-draft.md) (scoped)' "$P/AGENTS.md"
chk grep -q DRAFT_BODY "$P/AGENTS.md"
chk grep -q DRAFT_BODY "$P/.claude/rules/draft.md"
chk grep -q DOC_DRAFT_BODY "$P/.cursor/rules/doc-draft.mdc"
chk grep -q DOC_DRAFT_BODY "$P/.github/instructions/doc-draft.instructions.md"
chknot test -e "$P/.claude/rules/.draft.md"

echo "== a project content directory of its own name =="
D="$OUT/brain"
mkdir -p "$D"
git -C "$D" init --quiet
run "$D" init --bare --dir Brain --targets agents,claude
is "init --dir Brain" 0 "$RC"
for pattern in 'Brain/rules/*.local.md' 'Brain/agents/*.local.md' 'Brain/skills/*.local/'; do
    chk grep -Fqx "$pattern" "$D/.gitignore"
done
chknot grep -Fq 'intelligence/rules/*.local.md' "$D/.gitignore"

echo "== targeted artifacts: every always-on channel, and AGENTS.md left alone =="
Q="$OUT/targeted"
mkdir -p "$Q"
git -C "$Q" init --quiet
git -C "$Q" config user.email e2e@example.com
git -C "$Q" config user.name e2e
git -C "$Q" config core.autocrlf false
run "$Q" init --bare --targets "$TARGETS"
is "init of the targeted project" 0 "$RC"
run "$Q" adapter enable antigravity
is "enable antigravity" 0 "$RC"
run "$Q" adapter enable pi
is "enable pi" 0 "$RC"
chk grep -Fqx 'AGENTS.override.md' "$Q/.gitignore"
mkdir -p "$Q/intelligence/rules" "$Q/intelligence/agents" "$Q/intelligence/skills/ship"
printf '# Team\n\nTEAM_BODY\n' > "$Q/intelligence/rules/team.md"
run "$Q" sync
commit_all "$Q" start
printf -- '---\ntargets: [claude]\n---\n\nCLAUDE_ONLY_BODY\n' > "$Q/intelligence/rules/claude-only.md"
printf -- '---\ntargets: [codex]\n---\n\nCODEX_ONLY_BODY\n' > "$Q/intelligence/rules/codex-only.md"
printf -- '---\ndescription: "Tools"\nexclude_targets:\n  - agents\n---\n\nTOOLS_BODY "quoted" \\ back\n' > "$Q/intelligence/rules/tools.md"
printf -- '---\ntargets: []\n---\n\nNOWHERE_BODY\n' > "$Q/intelligence/rules/nowhere.md"
printf -- '---\nname: ship\ndescription: "Ship it"\ntargets: [codex]\n---\n\nSHIP_BODY\n' > "$Q/intelligence/skills/ship/SKILL.md"
printf -- '---\nname: reviewer\ndescription: "Reviews"\ntier: standard\nexclude_targets: [copilot]\n---\n\nREVIEWER_BODY\n' > "$Q/intelligence/agents/reviewer.md"
run "$Q" sync
is "sync of targeted artifacts" 0 "$RC"
for body in CLAUDE_ONLY_BODY CODEX_ONLY_BODY TOOLS_BODY NOWHERE_BODY SHIP_BODY; do
    chknot grep -q "$body" "$Q/AGENTS.md"
done
chknot grep -q 'claude-only\|codex-only\|nowhere\|ship' "$Q/AGENTS.md"
chk grep -Fq '[reviewer](intelligence/agents/reviewer.md)' "$Q/AGENTS.md"
# targets: [claude] reaches Claude only, without the field.
chk grep -q CLAUDE_ONLY_BODY "$Q/.claude/rules/claude-only.md"
chknot grep -q '^targets:' "$Q/.claude/rules/claude-only.md"
for f in .cursor/rules/claude-only.mdc .github/instructions/claude-only.instructions.md .agents/rules/claude-only.md; do
    chknot test -e "$Q/$f"
done
# exclude_targets: [agents] reaches every tool through its own always-on channel.
chk grep -q TOOLS_BODY "$Q/.claude/rules/tools.md"
chknot grep -q '^exclude_targets:\|^  - agents' "$Q/.claude/rules/tools.md"
chk grep -qx 'alwaysApply: true' "$Q/.cursor/rules/tools.mdc"
chk grep -qx 'description: "Tools"' "$Q/.cursor/rules/tools.mdc"
chk grep -qx 'applyTo: "\*\*"' "$Q/.github/instructions/tools.instructions.md"
chk grep -qx 'trigger: always_on' "$Q/.agents/rules/tools.md"
chk grep -Fq '{ name: "tools", body: "TOOLS_BODY \"quoted\" \\ back" }' "$Q/.pi/extensions/intelligence-sync-rules.ts"
chk grep -Fq 'const projectRules' "$Q/.pi/extensions/intelligence-sync-rules.ts"
chk grep -Fq "cannot reach opencode" "$LOG"
# Codex reads AGENTS.override.md instead of AGENTS.md: all of it, plus its rules.
chk test -f "$Q/AGENTS.override.md"
is "override starts with AGENTS.md" "$(cat "$Q/AGENTS.md")" "$(head -n "$(grep -c '' "$Q/AGENTS.md")" "$Q/AGENTS.override.md")"
chk grep -q CODEX_ONLY_BODY "$Q/AGENTS.override.md"
chk grep -q TOOLS_BODY "$Q/AGENTS.override.md"
chknot grep -q CLAUDE_ONLY_BODY "$Q/AGENTS.override.md"
chk git -C "$Q" check-ignore -q --no-index AGENTS.override.md
# targets: [] renders nowhere.
is "files holding NOWHERE_BODY" "" "$(cd "$Q" && grep -rl NOWHERE_BODY AGENTS.md AGENTS.override.md .claude .cursor .codex .github .agents .opencode .pi 2>/dev/null)"
# A skill for Codex lands in .agents/skills/, which three more tools read.
chk test -f "$Q/.agents/skills/ship/SKILL.md"
chknot grep -q '^targets:' "$Q/.agents/skills/ship/SKILL.md"
for tree in .claude/skills .cursor/skills .github/skills; do
    chknot test -e "$Q/$tree/ship"
done
chknot test -e "$Q/.opencode/commands/ship.md"
chk grep -Fq 'WARNING: intelligence/skills/ship/ still reaches antigravity, opencode, pi through .agents/skills/' "$LOG"
# exclude_targets: [copilot] keeps the agent out of Copilot's own channel.
chknot test -e "$Q/.github/agents/reviewer.agent.md"
chk test -f "$Q/.claude/agents/reviewer.md"
chknot grep -q '^exclude_targets:' "$Q/.claude/agents/reviewer.md"
chk test -f "$Q/.codex/agents/reviewer.toml"
chk grep -Fq 'WARNING: intelligence/agents/reviewer.md still reaches copilot through AGENTS.md' "$LOG"
# Only the reviewer agent, for AGENTS.md too, changed a tracked output.
is "tracked outputs after targeted sync" " M AGENTS.md" "$(git -C "$Q" status --porcelain --untracked-files=no)"

echo "== an untargeted project's Pi extension and outputs are unchanged by the fields' absence =="
rm "$Q/intelligence/rules/codex-only.md" "$Q/intelligence/rules/tools.md"
run "$Q" sync
is "sync after removing the Codex rules" 0 "$RC"
chknot test -e "$Q/AGENTS.override.md"
chknot test -e "$Q/.pi/extensions/intelligence-sync-rules.ts"

echo "== targets: [agents] with exclude_targets: [cursor] names cursor =="
printf -- '---\ntargets: [agents]\nexclude_targets: [cursor]\n---\n\nAGENTS_ONLY_BODY\n' > "$Q/intelligence/rules/agents-only.md"
run "$Q" sync
is "sync of an AGENTS.md-only rule" 0 "$RC"
chk grep -q AGENTS_ONLY_BODY "$Q/AGENTS.md"
chknot test -e "$Q/.claude/rules/agents-only.md"
chk grep -q 'WARNING: intelligence/rules/agents-only.md still reaches .*cursor.* through AGENTS.md' "$LOG"
rm "$Q/intelligence/rules/agents-only.md"
run "$Q" sync

echo "== a hand-written AGENTS.override.md is never touched =="
printf '# Mine\n' > "$Q/AGENTS.override.md"
run "$Q" sync
is "sync beside a hand-written override" 0 "$RC"
is "hand-written override kept" "# Mine" "$(cat "$Q/AGENTS.override.md")"
printf -- '---\ntargets: [codex]\n---\n\nCODEX_ONLY_BODY\n' > "$Q/intelligence/rules/codex-only.md"
before="$(snapshot "$Q")"
run "$Q" sync
is "a Codex rule needing the hand-written path" 1 "$RC"
chk grep -Fq 'AGENTS.override.md was not generated by intelligence-sync' "$LOG"
is "hand-written override still kept" "# Mine" "$(cat "$Q/AGENTS.override.md")"
is "outputs after the refusal" "$before" "$(snapshot "$Q")"
rm "$Q/AGENTS.override.md" "$Q/intelligence/rules/codex-only.md"

echo "== an unknown target, and a local artifact naming a committed output, refuse =="
run "$Q" sync
before="$(snapshot "$Q")"
printf -- '---\ntargets: [cursr]\n---\n' > "$Q/intelligence/rules/typo.md"
run "$Q" sync
is "unknown target" 1 "$RC"
chk grep -Fq "intelligence/rules/typo.md: targets names 'cursr', which is no adapter" "$LOG"
is "outputs after the unknown target" "$before" "$(snapshot "$Q")"
rm "$Q/intelligence/rules/typo.md"
for id in agents committed; do
    printf -- '---\ntargets: [%s]\n---\n' "$id" > "$Q/intelligence/rules/x.local.md"
    run "$Q" sync
    is "local rule with targets: [$id]" 1 "$RC"
    chk grep -Fq "intelligence/rules/x.local.md is local, but its targets name $id, whose output Git tracks" "$LOG"
    is "outputs after the local refusal ($id)" "$before" "$(snapshot "$Q")"
done
# A local rule may still narrow its set to an adapter whose output is ignored.
printf -- '---\ntargets: [claude]\n---\n\nX_LOCAL_BODY\n' > "$Q/intelligence/rules/x.local.md"
run "$Q" sync
is "local rule with targets: [claude]" 0 "$RC"
chk grep -q X_LOCAL_BODY "$Q/.claude/rules/x.md"
chknot test -e "$Q/.cursor/rules/x.mdc"
chknot test -e "$Q/AGENTS.override.md"
rm "$Q/intelligence/rules/x.local.md"

echo "== Codex routes scoped rules without changing other tools' instructions =="
printf -- '---\npaths:\n  - "src/**"\n  - "tests/**"\n---\n\nSHARED_SCOPED_BODY\n' > "$Q/intelligence/rules/backend.md"
printf -- '---\r\npaths: ["*.ts", "src/{one,two}/**"]\r\n---\r\n\r\nLOCAL_SCOPED_BODY\r\n' > "$Q/intelligence/rules/.local.md"
printf -- '---\npaths: ["private/**"]\ntargets: [claude]\n---\n\nEXCLUDED_SCOPED_BODY\n' > "$Q/intelligence/rules/excluded.md"
run "$Q" sync
is "scoped-only Codex sync" 0 "$RC"
chknot grep -Fq 'cannot reach codex' "$LOG"
chk grep -Fq 'Before working on files matching these repo-relative patterns' "$Q/AGENTS.override.md"
chk grep -Fq '`"src/**" "tests/**"` → [backend](<intelligence/rules/backend.md>)' "$Q/AGENTS.override.md"
chk grep -Fq '`["*.ts", "src/{one,two}/**"]` → [local](<intelligence/rules/.local.md>)' "$Q/AGENTS.override.md"
for word in SHARED_SCOPED_BODY LOCAL_SCOPED_BODY EXCLUDED_SCOPED_BODY excluded.md; do
    chknot grep -Fq "$word" "$Q/AGENTS.override.md"
done
chknot grep -Fq '.local.md' "$Q/AGENTS.md"
chknot grep -Fq 'Before working on files matching' "$Q/AGENTS.md" "$Q/.claude/rules/backend.md" "$Q/.cursor/rules/backend.mdc"
is "scoped override keeps the whole base" "$(cat "$Q/AGENTS.md")" "$(head -n "$(grep -c '' "$Q/AGENTS.md")" "$Q/AGENTS.override.md")"
cp "$Q/AGENTS.override.md" "$OUT/scoped-override"
run "$Q" sync --force
is "second scoped sync" 0 "$RC"
chk cmp -s "$OUT/scoped-override" "$Q/AGENTS.override.md"
run "$Q" status --check
is "scoped project status" 0 "$RC"
run "$Q" sync --check
is "scoped project check" 0 "$RC"

echo "== scoped routing preserves a hand-written override and rolls back =="
printf '# Personal override\n' > "$Q/AGENTS.override.md"
before="$(snapshot "$Q")"
run "$Q" sync --force
is "scoped rule needs occupied override" 1 "$RC"
chk grep -Fq 'AGENTS.override.md was not generated by intelligence-sync' "$LOG"
is "scoped refusal preserves override" '# Personal override' "$(cat "$Q/AGENTS.override.md")"
is "scoped refusal restores other outputs" "$before" "$(snapshot "$Q")"
rm "$Q/AGENTS.override.md"
run "$Q" sync
is "restore scoped routing" 0 "$RC"

echo "== disabling Codex retains its override; removing scoped sources cleans it =="
run "$Q" adapter disable codex
is "disable Codex" 0 "$RC"
chk test -f "$Q/AGENTS.override.md"
run "$Q" adapter enable codex
is "enable Codex again" 0 "$RC"
rm "$Q/intelligence/rules/backend.md" "$Q/intelligence/rules/.local.md" "$Q/intelligence/rules/excluded.md"
run "$Q" sync
is "remove last scoped rules" 0 "$RC"
chknot test -e "$Q/AGENTS.override.md"

[ "$fail" -eq 0 ] && echo "E2E-LOCAL-ARTIFACTS: ALL OK"
exit "$fail"
