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
# A CR belongs to the pattern Git matches, so presence must ignore it while the
# append keeps it: comparing with the CR attached made every existing line look
# absent on Linux and macOS, and alignment appended an LF copy every run.
chk ignore_file_has_line "$D/.gitignore" '!.claude/'
chk ignore_file_has_line "$D/.gitignore" "$HEADER"
gitignore_add_line "$D" '!.claude/'
is "existing line not duplicated" "1" "$(count_of "$D" '!.claude/')"
gitignore_add_line "$D" '.codex/*'
is "new line appended as CRLF" "5" "$(crlf_lines "$D/.gitignore")"
is "no LF-only line introduced" "5" "$(total_lines "$D/.gitignore")"

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

[ "$fail" -eq 0 ] && echo "CLI-UNIT-GITIGNORE: ALL OK"
exit "$fail"
