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

[ "$fail" -eq 0 ] && echo "E2E-LOCAL-ARTIFACTS: ALL OK"
exit "$fail"
