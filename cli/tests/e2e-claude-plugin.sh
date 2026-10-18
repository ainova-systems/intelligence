#!/bin/bash
# e2e: the Claude Code plugin the Claude adapter renders behind
# targets.claude.plugin (decision 0022). The flag is off by default, takes only
# true or false, renders the mod from engine/adapters/claude-plugin/ with the
# engine version stamped, stays idempotent, is removed when the flag goes, is
# ignored by Git through the existing `.claude/*` policy, and refuses a source
# skill that would render under the plugin's directory name.
set -euo pipefail
unset CI
REPO="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
REPO="$(cd "$REPO" && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
CLI="$REPO/cli/intelligence"
TEMPLATE="$REPO/engine/adapters/claude-plugin"
VERSION="$(tr -d ' \t\r\n' < "$REPO/engine/VERSION")"
fail=0
RC=0
OUTPUT=""
chk() { if ! "$@" >/dev/null 2>&1; then echo "FAIL: $*"; fail=1; fi; }
chknot() { if "$@" >/dev/null 2>&1; then echo "FAIL(not): $*"; fail=1; fi; }
has() { printf '%s\n' "$OUTPUT" | grep -Fq -- "$1" || { echo "FAIL: output lacks '$1'"; printf '%s\n' "$OUTPUT" | tail -8; fail=1; }; }

run_in() {
    local dir="$1"
    shift
    RC=0
    OUTPUT="$( (cd "$dir" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" "$@") 2>&1 )" || RC=$?
}

PROJ="$OUT/proj"
PLUGIN="$PROJ/.claude/skills/intelligence"
mkdir -p "$PROJ"
git -C "$PROJ" init --quiet

# set_claude_target <inline fields after output> — rewrite the Claude entry
# through a temp file; BSD sed -i takes a suffix argument.
set_claude_target() {
    awk -v extra="$1" '{
        sub(/\r$/, "")
        if ($0 ~ /^  claude:/) print "  claude: { enabled: true, output: \".claude\"" extra " }"
        else print
    }' "$PROJ/intelligence.yaml" > "$PROJ/intelligence.yaml.tmp"
    mv "$PROJ/intelligence.yaml.tmp" "$PROJ/intelligence.yaml"
}

# generated_digest — one line per generated file with its content hash, so a
# refused sync can be shown to have changed nothing.
generated_digest() {
    (cd "$PROJ" && find AGENTS.md .claude -type f | LC_ALL=C sort | while IFS= read -r f; do
        printf '%s %s\n' "$f" "$(cksum < "$f")"
    done)
}

echo "== off by default: init with the Claude target renders no plugin =="
run_in "$PROJ" init --targets claude --bare
chk test "$RC" -eq 0
chk grep -Fq 'claude: { enabled: true, output: ".claude" }' "$PROJ/intelligence.yaml"
chknot test -e "$PLUGIN"
mkdir -p "$PROJ/intelligence/skills/demo" "$PROJ/intelligence/rules"
printf -- '---\nname: demo\ndescription: "A skill"\n---\n\n# Demo\n' > "$PROJ/intelligence/skills/demo/SKILL.md"
printf -- '---\ndescription: "A rule"\n---\n\n# Rule\n' > "$PROJ/intelligence/rules/base.md"
run_in "$PROJ" sync
chk test "$RC" -eq 0
chk test -f "$PROJ/.claude/skills/demo/SKILL.md"
chknot test -e "$PLUGIN"

echo "== plugin: true renders the mod with the engine version stamped =="
set_claude_target ', plugin: true'
run_in "$PROJ" sync
chk test "$RC" -eq 0
has "plugin: intelligence (Claude Code mod $VERSION)"
has 'IS_STATUS=ok'
for f in .claude-plugin/plugin.json hooks/hooks.json hooks/register.js README.md; do
    chk test -f "$PLUGIN/$f"
done
chk grep -Fq '"name": "intelligence"' "$PLUGIN/.claude-plugin/plugin.json"
chk grep -Fq "\"version\": \"$VERSION\"" "$PLUGIN/.claude-plugin/plugin.json"
chknot grep -Fq '__INTELLIGENCE_VERSION__' "$PLUGIN/.claude-plugin/plugin.json"
chk grep -Fq '"modules": ["./register.js"]' "$PLUGIN/hooks/hooks.json"
# Every file but the stamped manifest is the template byte for byte.
chk cmp -s "$TEMPLATE/hooks/hooks.json" "$PLUGIN/hooks/hooks.json"
chk cmp -s "$TEMPLATE/hooks/register.js" "$PLUGIN/hooks/register.js"
chk cmp -s "$TEMPLATE/README.md" "$PLUGIN/README.md"
chknot grep -q $'\r' "$PLUGIN/hooks/register.js"
# The mod hooks the three events the status, the command and the band need.
chk grep -Fq "on('session.start'" "$PLUGIN/hooks/register.js"
chk grep -Fq "on('command.run', { command: 'intelligence' }" "$PLUGIN/hooks/register.js"
chk grep -Fq "on('ui.render', { component: 'AbovePrompt' }" "$PLUGIN/hooks/register.js"
# The plugin is not a skill: the count still reports only the real ones.
has 'Skills: 1,'
chk test -f "$PROJ/.claude/skills/demo/SKILL.md"

echo "== Git ignores the plugin through the existing Claude policy =="
chk git -C "$PROJ" check-ignore -q .claude/skills/intelligence/hooks/register.js
chk git -C "$PROJ" check-ignore -q .claude/skills/intelligence/.claude-plugin/plugin.json
chknot git -C "$PROJ" check-ignore -q AGENTS.md

echo "== a second sync changes nothing; check and status pass =="
generated_digest > "$OUT/digest-on"
run_in "$PROJ" sync
chk test "$RC" -eq 0
has 'IS_STATUS=ok'
generated_digest > "$OUT/digest-on-again"
chk cmp -s "$OUT/digest-on" "$OUT/digest-on-again"
run_in "$PROJ" sync --check
chk test "$RC" -eq 0
has 'IS_STATUS=ok'
run_in "$PROJ" sync --check --force
chk test "$RC" -eq 0
has 'IS_STATUS=ok'
run_in "$PROJ" status --check
chk test "$RC" -eq 0
has 'all good.'

echo "== a hand edit inside the plugin is a change sync --check reports and sync repairs =="
printf '// edited\n' >> "$PLUGIN/hooks/register.js"
run_in "$PROJ" sync --check
chk test "$RC" -eq 2
has 'IS_STATUS=out-of-date'
run_in "$PROJ" sync
chk test "$RC" -eq 0
chk cmp -s "$TEMPLATE/hooks/register.js" "$PLUGIN/hooks/register.js"

echo "== plugin: false removes the directory; omission does the same =="
set_claude_target ', plugin: false'
run_in "$PROJ" sync
chk test "$RC" -eq 0
chknot test -e "$PLUGIN"
chk test -f "$PROJ/.claude/skills/demo/SKILL.md"
set_claude_target ', plugin: true'
run_in "$PROJ" sync
chk test "$RC" -eq 0
chk test -f "$PLUGIN/hooks/register.js"
set_claude_target ''
run_in "$PROJ" sync
chk test "$RC" -eq 0
chknot test -e "$PLUGIN"
run_in "$PROJ" sync --check
chk test "$RC" -eq 0

echo "== any value but true or false refuses the sync and changes nothing =="
set_claude_target ', plugin: true'
run_in "$PROJ" sync
chk test "$RC" -eq 0
generated_digest > "$OUT/digest-before-refusal"
for bad in yes 1 on enabled; do
    set_claude_target ", plugin: $bad"
    run_in "$PROJ" sync
    chk test "$RC" -ne 0
    has 'ERROR: targets.claude.plugin must be true or false'
    has 'restored to their pre-sync state'
    generated_digest > "$OUT/digest-after-refusal"
    chk cmp -s "$OUT/digest-before-refusal" "$OUT/digest-after-refusal"
done
set_claude_target ', plugin: true'

echo "== a source skill named like the plugin refuses the sync, naming both =="
mkdir -p "$PROJ/intelligence/skills/intelligence"
printf -- '---\nname: intelligence\ndescription: "Clashes with the plugin"\n---\n\n# Clash\n' \
    > "$PROJ/intelligence/skills/intelligence/SKILL.md"
run_in "$PROJ" sync
chk test "$RC" -ne 0
has 'intelligence/skills/intelligence/SKILL.md'
has 'targets.claude.plugin'
has 'restored to their pre-sync state'
generated_digest > "$OUT/digest-after-collision"
chk cmp -s "$OUT/digest-before-refusal" "$OUT/digest-after-collision"
# A local or dotted spelling renders under the same name and collides too.
rm -rf "$PROJ/intelligence/skills/intelligence"
mkdir -p "$PROJ/intelligence/skills/intelligence.local"
printf -- '---\nname: intelligence\ndescription: "Local clash"\n---\n\n# Clash\n' \
    > "$PROJ/intelligence/skills/intelligence.local/SKILL.md"
run_in "$PROJ" sync
chk test "$RC" -ne 0
has 'intelligence/skills/intelligence.local/SKILL.md'
has 'targets.claude.plugin'
rm -rf "$PROJ/intelligence/skills/intelligence.local"
# Without the flag the skill is an ordinary skill of that name.
set_claude_target ''
mkdir -p "$PROJ/intelligence/skills/intelligence"
printf -- '---\nname: intelligence\ndescription: "Just a skill"\n---\n\n# Skill\n' \
    > "$PROJ/intelligence/skills/intelligence/SKILL.md"
run_in "$PROJ" sync
chk test "$RC" -eq 0
chk test -f "$PLUGIN/SKILL.md"
chknot test -e "$PLUGIN/hooks"
rm -rf "$PROJ/intelligence/skills/intelligence"
set_claude_target ', plugin: true'
run_in "$PROJ" sync
chk test "$RC" -eq 0
chk test -f "$PLUGIN/hooks/register.js"
chknot test -e "$PLUGIN/SKILL.md"

echo "== the template itself is what a validator would read =="
chk test -f "$TEMPLATE/.claude-plugin/plugin.json"
chk grep -Fq '"version": "__INTELLIGENCE_VERSION__"' "$TEMPLATE/.claude-plugin/plugin.json"
chk grep -Fq '"name": "intelligence"' "$TEMPLATE/.claude-plugin/plugin.json"
chk grep -Fq '"modules": ["./register.js"]' "$TEMPLATE/hooks/hooks.json"
chk grep -Fq 'export function register(on)' "$TEMPLATE/hooks/register.js"
# No Node.js API and no timer global: a hooks module has neither.
chknot grep -Eq "require\(|from 'node:|setTimeout|setInterval" "$TEMPLATE/hooks/register.js"

if [ "$fail" -ne 0 ]; then
    echo "e2e-claude-plugin: FAILED"
    exit 1
fi
echo "e2e-claude-plugin: all checks passed"
