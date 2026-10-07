#!/bin/bash
# Unit suite for cli/lib/gitignore.sh — the duplicate collapse that clears the
# negation residue an older CLI appended, and the file bytes it must not touch.
set -euo pipefail
REPO="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
REPO="$(cd "$REPO" && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
fail=0
chk() { if ! "$@" >/dev/null 2>&1; then echo "FAIL: $*"; fail=1; fi; }
chknot() { if "$@" >/dev/null 2>&1; then echo "FAIL(not): $*"; fail=1; fi; }
# is <label> <want> <got>
is() { [ "$2" = "$3" ] || { echo "FAIL: $1 — want '$2', got '$3'"; fail=1; }; }

export CLI_DIR="$REPO/cli"
export IS_ENGINE_DIR="$REPO/engine"
# shellcheck source=/dev/null
source "$CLI_DIR/lib/cli-common.sh"

HEADER='# Intelligence generated state and tool output'
CHAIN=('!.claude/' '!.claude/settings.json')
CR=$'\r'
CRLF=$'\r\n'

# fixture <name> — a git repo at $OUT/<name> whose .gitignore the caller writes.
fixture() {
    local dir="$OUT/$1"
    rm -rf "$dir"
    mkdir -p "$dir"
    git -C "$dir" init --quiet
    printf '%s' "$dir"
}
# Counting goes through bash, never grep: under MSYS grep reads in text mode and
# never sees a CR, while on Linux and macOS a CR is part of the line — so the
# same `grep -Fx` count answers differently per platform for the same file. The
# CR is stripped for the comparison, which is exactly what the policy does.
count_of() {
    local file="$1/.gitignore" want="$2" n=0 l
    [ -f "$file" ] || { printf '0'; return 0; }
    while IFS= read -r l || [ -n "$l" ]; do
        [ "${l%"$CR"}" = "$want" ] && n=$((n + 1))
        l=""
    done < "$file"
    printf '%s' "$n"
}
# Count CR-terminated lines in bash, for the same reason — and because `$'\r'`
# written inside a command substitution is not expanded at all, so a grep-based
# check here is silently always true.
crlf_lines() {
    local n=0 l
    while IFS= read -r l || [ -n "$l" ]; do
        case "$l" in *"$CR") n=$((n + 1)) ;; esac
        l=""
    done < "$1"
    printf '%s' "$n"
}
total_lines() { grep -c '' "$1" || true; }

echo "== residue collapses onto the last occurrence =="
D="$(fixture residue)"
cat > "$D/.gitignore" <<EOF
# hand-written section
node_modules/
!.claude/

$HEADER
.intelligence/
.claude/*
!.claude/
!.claude/settings.json
!.claude/
!.claude/settings.json
!.claude/
!.claude/settings.json
EOF
gitignore_collapse_duplicates "$D" ".claude/settings.json" "${CHAIN[@]}"
# One copy below the header, plus the project's own line above it — which this
# policy never rewrites, because the project wrote it before Intelligence did.
is "negations after collapse" "2" "$(count_of "$D" '!.claude/')"
is "include after collapse" "1" "$(count_of "$D" '!.claude/settings.json')"
is "hand-written line kept" '!.claude/' "$(sed -n '3p' "$D/.gitignore" | tr -d "$CR")"
is "unmanaged lines kept" "1" "$(count_of "$D" '.claude/*')"
chknot git -C "$D" check-ignore -q --no-index .claude/settings.json

echo "== collapsing is idempotent =="
cp "$D/.gitignore" "$OUT/residue.once"
gitignore_collapse_duplicates "$D" ".claude/settings.json" "${CHAIN[@]}"
chk cmp -s "$OUT/residue.once" "$D/.gitignore"
chknot ls "$D/.gitignore.cli.tmp"
chknot ls "$D/.gitignore.cli.bak"

echo "== a file with nothing to collapse is left byte-identical =="
D="$(fixture clean)"
cat > "$D/.gitignore" <<EOF
$HEADER
.claude/*
!.claude/
!.claude/settings.json
EOF
cp "$D/.gitignore" "$OUT/clean.before"
gitignore_collapse_duplicates "$D" ".claude/settings.json" "${CHAIN[@]}"
chk cmp -s "$OUT/clean.before" "$D/.gitignore"

echo "== a file without the header is not this policy's to rewrite =="
D="$(fixture noheader)"
printf '%s\n' '.claude/*' '!.claude/' '!.claude/' > "$D/.gitignore"
cp "$D/.gitignore" "$OUT/noheader.before"
gitignore_collapse_duplicates "$D" ".claude/settings.json" "${CHAIN[@]}"
chk cmp -s "$OUT/noheader.before" "$D/.gitignore"

echo "== CRLF endings survive line for line =="
D="$(fixture crlf)"
printf '# hand\r\n\r\n%s\r\n.claude/*\r\n!.claude/\r\n!.claude/settings.json\r\n!.claude/\r\n!.claude/settings.json\r\n' "$HEADER" > "$D/.gitignore"
gitignore_collapse_duplicates "$D" ".claude/settings.json" "${CHAIN[@]}"
is "lines left" "6" "$(total_lines "$D/.gitignore")"
# Every remaining line still ends CRLF: awk on Windows reads in text mode and
# would have rewritten the whole file as LF.
is "CR endings kept" "6" "$(crlf_lines "$D/.gitignore")"

echo "== a missing final newline is not invented =="
D="$(fixture nonewline)"
printf '%s\n.claude/*\n!.claude/\n!.claude/settings.json\n!.claude/\n!.claude/settings.json' "$HEADER" > "$D/.gitignore"
gitignore_collapse_duplicates "$D" ".claude/settings.json" "${CHAIN[@]}"
is "still ends without a newline" "n" "$(tail -c 1 "$D/.gitignore")"
is "collapsed anyway" "1" "$(count_of "$D" '!.claude/')"

echo "== a CRLF file is recognized and appended to in its own ending =="
D="$(fixture crlf-append)"
printf '# hand\r\n%s\r\n.claude/*\r\n!.claude/\r\n' "$HEADER" > "$D/.gitignore"
ignore_file_eol_var "$D/.gitignore"
# Compared through a variable: `$'\r\n'` written inside a command substitution
# is not expanded by bash, so the check would silently always fail.
[ "$IS_IGNORE_EOL" = "$CRLF" ] || { echo "FAIL: CRLF ending not detected"; fail=1; }
# Git drops a line's trailing CR, so presence must ignore it while the append
# keeps it: comparing with the CR attached made every existing line look absent
# on Linux and macOS, and alignment appended an LF copy every run.
chk ignore_file_has_line "$D/.gitignore" '!.claude/'
chk ignore_file_has_line "$D/.gitignore" "$HEADER"
gitignore_add_line "$D" '!.claude/'
is "existing line not duplicated" "1" "$(count_of "$D" '!.claude/')"
gitignore_add_line "$D" '.codex/*'
is "new line appended as CRLF" "5" "$(crlf_lines "$D/.gitignore")"
is "no LF-only line introduced" "5" "$(total_lines "$D/.gitignore")"

echo "== presence is one exact line, ignoring only its trailing CR =="
D="$(fixture presence)"
printf '.claude/*\r\n!.claude/settings.json\r\nnested/dir/\r\r\nlast-line\r' > "$D/.gitignore"
chk ignore_file_has_line "$D/.gitignore" '.claude/*'
chk ignore_file_has_line "$D/.gitignore" '!.claude/settings.json'
# A final line without a newline is still a line, with or without its CR.
chk ignore_file_has_line "$D/.gitignore" 'last-line'
# Exact and literal: no prefix, substring or glob reading of either side.
chknot ignore_file_has_line "$D/.gitignore" '.claude/'
chknot ignore_file_has_line "$D/.gitignore" '!.claude/settings'
chknot ignore_file_has_line "$D/.gitignore" '.c*'
chknot ignore_file_has_line "$D/.gitignore" '.claude/x'
# Git drops exactly one CR, so a second one is part of that rule.
chknot ignore_file_has_line "$D/.gitignore" 'nested/dir/'
chknot ignore_file_has_line "$OUT/absent/.gitignore" '.claude/*'
printf 'last-line' > "$D/.gitignore"
chk ignore_file_has_line "$D/.gitignore" 'last-line'

echo "== repeated alignment leaves a CRLF file alone =="
D="$(fixture crlf-stable)"
printf '%s\r\n.claude/*\r\n!.claude/\r\n!.claude/settings.json\r\n' "$HEADER" > "$D/.gitignore"
cp "$D/.gitignore" "$OUT/crlf-stable.before"
for _ in 1 2 3; do gitignore_add_effective_include "$D" ".claude/settings.json"; done
chk cmp -s "$OUT/crlf-stable.before" "$D/.gitignore"

echo "== the full repair converges through the public entry point =="
D="$(fixture repair)"
cat > "$D/.gitignore" <<EOF
$HEADER
.claude/*
!.claude/
!.claude/settings.json
!.claude/
!.claude/settings.json
.claude/
EOF
# The trailing `.claude/` shadows the chain, so the repair must move it last
# AND clear the copies it leaves behind.
chk git -C "$D" check-ignore -q --no-index .claude/settings.json
gitignore_add_effective_include "$D" ".claude/settings.json"
chknot git -C "$D" check-ignore -q --no-index .claude/settings.json
is "one negation after repair" "1" "$(count_of "$D" '!.claude/')"
is "one include after repair" "1" "$(count_of "$D" '!.claude/settings.json')"
cp "$D/.gitignore" "$OUT/repair.once"
gitignore_add_effective_include "$D" ".claude/settings.json"
chk cmp -s "$OUT/repair.once" "$D/.gitignore"

# --- Copilot's Git policy (decision 0020) ------------------------------------
COPILOT_DIRS=(instructions prompts agents skills)
COPILOT_ADAPTER="$IS_ENGINE_DIR/adapters/copilot.sh"
# copilot_manifest <dir> <copilot entry> — the caller writes the target entry,
# so the inline and the block form both reach the contract.
copilot_manifest() {
    cat > "$1/intelligence.yaml" <<EOF
project:
  name: copilot-policy

targets:
  agents: { enabled: true, output: "AGENTS.md" }
$2
EOF
}
# A generated file in each owned directory, plus the hand-written neighbours
# `.github/` holds in every GitHub repository.
COPILOT_GENERATED=(.github/instructions/api.instructions.md .github/prompts/old.prompt.md
    .github/agents/reviewer.agent.md .github/skills/deploy/SKILL.md
    .github/copilot-instructions.md)
COPILOT_HANDWRITTEN=(.github/workflows/ci.yml .github/PULL_REQUEST_TEMPLATE.md)

echo "== Copilot output is ignored by default: its four directories, never .github/ =="
D="$(fixture copilot)"
copilot_manifest "$D" '  copilot: { enabled: true, output: ".github" }'
ensure_base_gitignore "$D"
ensure_target_gitignore "$D" "$D/intelligence.yaml" copilot
for sub in "${COPILOT_DIRS[@]}"; do
    is ".github/$sub/ listed once" "1" "$(count_of "$D" ".github/$sub/")"
done
is ".github/copilot-instructions.md listed once" "1" "$(count_of "$D" '.github/copilot-instructions.md')"
is ".github/ itself is not ignored" "0" "$(count_of "$D" '.github/')"
for path in "${COPILOT_GENERATED[@]}"; do
    chk git -C "$D" check-ignore -q --no-index "$path"
done
for path in "${COPILOT_HANDWRITTEN[@]}"; do
    chknot git -C "$D" check-ignore -q --no-index "$path"
done
cp "$D/.gitignore" "$OUT/copilot-default.once"
ensure_target_gitignore "$D" "$D/intelligence.yaml" copilot
chk cmp -s "$OUT/copilot-default.once" "$D/.gitignore"
chk grep -Fqx '.github/agents/' <(managed_gitignore_patterns "$D" "$D/intelligence.yaml")

echo "== commit_output: true withdraws exactly the lines the default wrote =="
# A project line above the header — here a copy of one of the four patterns —
# predates the policy and is the project's to keep.
{ printf '%s\n' '# kept by the project' '.github/skills/'; cat "$D/.gitignore"; } > "$D/.gitignore.tmp" \
    && mv "$D/.gitignore.tmp" "$D/.gitignore"
copilot_manifest "$D" '  copilot: { enabled: true, output: ".github", commit_output: true }'
ensure_target_gitignore "$D" "$D/intelligence.yaml" copilot
for sub in instructions/ prompts/ agents/ copilot-instructions.md; do
    is ".github/$sub withdrawn" "0" "$(count_of "$D" ".github/$sub")"
    chknot gitignore_managed_has_line "$D" ".github/$sub"
done
is "the project's own copy kept" ".github/skills/" "$(sed -n '2p' "$D/.gitignore" | tr -d "$CR")"
is "only the project's copy left" "1" "$(count_of "$D" '.github/skills/')"
chknot gitignore_managed_has_line "$D" '.github/skills/'
is "the rest of the policy kept" "1" "$(count_of "$D" '.intelligence/')"
chknot git -C "$D" check-ignore -q --no-index .github/agents/reviewer.agent.md
chknot git -C "$D" check-ignore -q --no-index .github/instructions/api.instructions.md
chknot git -C "$D" check-ignore -q --no-index .github/copilot-instructions.md
chknot grep -Fqx '.github/agents/' <(managed_gitignore_patterns "$D" "$D/intelligence.yaml")
cp "$D/.gitignore" "$OUT/copilot-commit.once"
ensure_target_gitignore "$D" "$D/intelligence.yaml" copilot
chk cmp -s "$OUT/copilot-commit.once" "$D/.gitignore"
chknot ls "$D/.gitignore.cli.tmp"

echo "== turning it back off restores the default once, in the block form too =="
copilot_manifest "$D" '  copilot:
    enabled: true
    output: ".github"
    commit_output: false'
ensure_target_gitignore "$D" "$D/intelligence.yaml" copilot
ensure_target_gitignore "$D" "$D/intelligence.yaml" copilot
for sub in instructions/ prompts/ agents/ skills/ copilot-instructions.md; do
    is ".github/$sub back once" "1" "$(count_of "$D" ".github/$sub")"
done
chk git -C "$D" check-ignore -q --no-index .github/agents/reviewer.agent.md

echo "== the withdrawal keeps CRLF endings and a missing final newline =="
D="$(fixture copilot-crlf)"
copilot_manifest "$D" '  copilot: { enabled: true, output: ".github", commit_output: true }'
printf '# hand\r\n%s\r\n.github/instructions/\r\n.github/prompts/\r\n.intelligence/\r\n.github/agents/\r\n.github/skills/\r\nAGENTS.local.md' \
    "$HEADER" > "$D/.gitignore"
ensure_target_gitignore "$D" "$D/intelligence.yaml" copilot
is "lines left" "4" "$(total_lines "$D/.gitignore")"
is "CR endings kept" "3" "$(crlf_lines "$D/.gitignore")"
is "still ends without a newline" "d" "$(tail -c 1 "$D/.gitignore")"
D="$(fixture copilot-last)"
copilot_manifest "$D" '  copilot: { enabled: true, output: ".github", commit_output: true }'
# The withdrawn line was the unterminated last one: the line before it keeps the
# CRLF it always had, rather than losing its LF and leaving a bare CR.
printf '%s\r\n.intelligence/\r\n.github/skills/' "$HEADER" > "$D/.gitignore"
ensure_target_gitignore "$D" "$D/intelligence.yaml" copilot
is "kept line keeps CRLF" "2" "$(crlf_lines "$D/.gitignore")"
is "kept lines" "2" "$(total_lines "$D/.gitignore")"

echo "== a file without the header holds nothing this policy may withdraw =="
D="$(fixture copilot-noheader)"
printf '%s\n' '.github/agents/' > "$D/.gitignore"
cp "$D/.gitignore" "$OUT/copilot-noheader.before"
gitignore_remove_managed_lines "$D" '.github/agents/'
chk cmp -s "$OUT/copilot-noheader.before" "$D/.gitignore"

echo "== the manifest decides Git policy only, never ownership =="
D="$(fixture copilot-contract)"
copilot_manifest "$D" '  copilot: { enabled: true, output: ".github", commit_output: true }'
own_default="$(adapter_contract_records copilot "$COPILOT_ADAPTER" .github | grep -Ev '^(un)?ignore')"
own_commit="$(adapter_contract_records copilot "$COPILOT_ADAPTER" .github "$D/intelligence.yaml" | grep -Ev '^(un)?ignore')"
is "ownership unchanged by commit_output" "$own_default" "$own_commit"
is "default policy ignores" "5" "$(adapter_contract_records copilot "$COPILOT_ADAPTER" .github | grep -c '^ignore')"
is "commit_output unignores" "5" "$(adapter_contract_records copilot "$COPILOT_ADAPTER" .github "$D/intelligence.yaml" | grep -c '^unignore')"
# A malformed value is sync's to refuse; the contract meanwhile declares the
# default rather than guessing the project meant to commit.
copilot_manifest "$D" '  copilot: { enabled: true, output: ".github", commit_output: yes }'
is "malformed value declares the default" "5" "$(adapter_contract_records copilot "$COPILOT_ADAPTER" .github "$D/intelligence.yaml" | grep -c '^ignore')"
# `unignore` names a pattern like `ignore` does, and is held to the same bounds.
cat > "$D/unsafe.sh" <<'EOF'
adapter_contract_unsafe() {
    adapter_contract_version 1
    adapter_contract_unignore "../outside/"
}
EOF
chknot adapter_contract_records unsafe "$D/unsafe.sh" .unsafe

[ "$fail" -eq 0 ] && echo "CLI-UNIT-GITIGNORE: ALL OK"
exit "$fail"
