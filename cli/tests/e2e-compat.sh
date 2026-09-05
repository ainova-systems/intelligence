#!/bin/bash
# Hermetic e2e for the schema-compatibility gate: a CLI OLDER than the project.
# A project stamped a newer minor or patch within the same major syncs with one
# warning and is never restamped or re-pinned downward; a newer major is refused
# with the `ahead-of-engine` status and exit 4. No network: the engine-content
# store is seeded from this tree.
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

RC=0
OUTPUT=""
run_in() {
    local d="$1"; shift
    RC=0
    OUTPUT="$( (cd "$d" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI" "$@") 2>&1 )" || RC=$?
}

# xfail <fragment> <dir> <cli-args…> — must exit nonzero AND say why.
xfail() {
    local frag="$1" d="$2"; shift 2
    run_in "$d" "$@"
    if [ "$RC" -eq 0 ]; then echo "FAIL: expected nonzero rc: $*"; fail=1; fi
    if ! printf '%s\n' "$OUTPUT" | grep -qF -- "$frag"; then
        echo "FAIL: output of '$*' lacks '$frag'"
        printf '%s\n' "$OUTPUT" | head -6
        fail=1
    fi
}

# xok <fragment-or-empty> <dir> <cli-args…> — must exit 0 (fragment optional).
xok() {
    local frag="$1" d="$2"; shift 2
    run_in "$d" "$@"
    if [ "$RC" -ne 0 ]; then
        echo "FAIL: expected rc=0 (got $RC): $*"
        printf '%s\n' "$OUTPUT" | tail -8
        fail=1
    fi
    if [ -n "$frag" ] && ! printf '%s\n' "$OUTPUT" | grep -qF -- "$frag"; then
        echo "FAIL: output of '$*' lacks '$frag'"
        printf '%s\n' "$OUTPUT" | tail -8
        fail=1
    fi
}

# has <fragment> / hasnot <fragment> — assertions over the last OUTPUT.
has() {
    printf '%s\n' "$OUTPUT" | grep -qF -- "$1" || { echo "FAIL: output lacks '$1'"; fail=1; }
}
hasnot() {
    if printf '%s\n' "$OUTPUT" | grep -qF -- "$1"; then echo "FAIL: output has '$1'"; fail=1; fi
}

# Compact success keeps one-line warnings; everything else stays out.
compact_contract_ok() {
    printf '%s\n' "$1" | awk '
        /^WARNING:/ { next }
        /^CONTEXT:/ { context++; next }
        /^IS_STATUS=ok($| )/ { status++; next }
        /^=== Done:/ { done++; next }
        NF { bad=1 }
        END { exit bad || context != 1 || status != 1 || done != 1 }
    '
}

ENGINE_VER="$(tr -d ' \t\r\n' < "$REPO/engine/VERSION")"
IFS=. read -r MAJ MIN PAT <<< "$ENGINE_VER"
PATCH_AHEAD="$MAJ.$MIN.$((PAT + 1))"
MINOR_AHEAD="$MAJ.$((MIN + 1)).0"
MAJOR_AHEAD="$((MAJ + 1)).0.0"
WARN_LINE="WARNING: project schema"

echo "== _ver_major =="
# shellcheck source=../../engine/lib/contract.sh
source "$REPO/engine/lib/contract.sh"
for pair in "0.11.6:0" "1.2.3:1" "12.0.0:12" "v2.0.0:2" "3:3" ":0"; do
    v="${pair%%:*}"; want="${pair#*:}"
    got="$(_ver_major "$v")"
    [ "$got" = "$want" ] || { echo "FAIL: _ver_major '$v' -> '$got' want '$want'"; fail=1; }
done

# make_project <dir> <stamp> — a project authoring its own rules, no packages.
make_project() {
    local d="$1" stamp="$2"
    mkdir -p "$d/intelligence/rules"
    cat > "$d/intelligence.yaml" <<MANIFEST
project:
  name: compat

schema_version: "$stamp"

sources:
  rules:
    - "intelligence/rules"
  agents:
  skills:

targets:
  agents: { enabled: true, output: "AGENTS.md" }
  claude: { enabled: true, output: ".claude" }
MANIFEST
    printf '# Ctx\n\nCOMPAT_MARKER\n' > "$d/intelligence/rules/context.md"
    cat > "$d/.gitignore" <<'IGNORE'
.intelligence/
CLAUDE.md
.claude/*
!.claude/settings.json
IGNORE
    git -C "$d" init --quiet
}

echo "== 1. a newer patch syncs with one warning and stays stamped =="
P1="$OUT/patch-ahead"
make_project "$P1" "$PATCH_AHEAD"
xok "$WARN_LINE $PATCH_AHEAD is newer than this CLI's engine $ENGINE_VER" "$P1" sync
has "IS_STATUS=ok"
# Preflight and the engine both check; the user reads the warning once.
warn_count="$(printf '%s\n' "$OUTPUT" | grep -c "^$WARN_LINE" || true)"
[ "$warn_count" -eq 1 ] || { echo "FAIL: expected exactly one warning, got $warn_count"; fail=1; }
chk grep -q "^schema_version: \"$PATCH_AHEAD\"" "$P1/intelligence.yaml"
chk grep -q "COMPAT_MARKER" "$P1/AGENTS.md"
chknot test -f "$P1/intelligence.lock"
# Compact mode keeps the warning and its contract.
xok "$WARN_LINE $PATCH_AHEAD" "$P1" sync --compact
compact_contract_ok "$OUTPUT" || { echo "FAIL: compact output broke its contract"; printf '%s\n' "$OUTPUT"; fail=1; }
# Deep check reports it as a note, not a problem.
xok "all good." "$P1" status --check
has "  ! manifest schema $PATCH_AHEAD is newer than this CLI's engine $ENGINE_VER"

echo "== 2. previews and apply name the state and never align downward =="
xok "schema $PATCH_AHEAD is ahead of engine $ENGINE_VER — left as is" "$P1" init --preview
xok "schema $PATCH_AHEAD is ahead of engine $ENGINE_VER — left as is" "$P1" update --preview
hasnot "lifecycle alignment required"
xok "$WARN_LINE $PATCH_AHEAD" "$P1" init --apply
warn_count="$(printf '%s\n' "$OUTPUT" | grep -c "^$WARN_LINE" || true)"
[ "$warn_count" -eq 1 ] || { echo "FAIL: init --apply printed $warn_count warnings"; fail=1; }
hasnot "schema_version ->"
chk grep -q "^schema_version: \"$PATCH_AHEAD\"" "$P1/intelligence.yaml"

echo "== 3. a newer minor behaves the same =="
P2="$OUT/minor-ahead"
make_project "$P2" "$MINOR_AHEAD"
xok "$WARN_LINE $MINOR_AHEAD is newer than this CLI's engine $ENGINE_VER" "$P2" sync
has "IS_STATUS=ok"
chk grep -q "^schema_version: \"$MINOR_AHEAD\"" "$P2/intelligence.yaml"
chk grep -q "COMPAT_MARKER" "$P2/AGENTS.md"

echo "== 4. engine content pinned ahead stays as locked =="
# The manifest, lock and store all say the newer version: an older CLI renders
# that content and leaves every tracked file byte-identical.
P3="$OUT/pinned-ahead"
make_project "$P3" "$PATCH_AHEAD"
cat > "$P3/intelligence.yaml" <<MANIFEST
project:
  name: compat

schema_version: "$PATCH_AHEAD"

sources:
  rules:
    - ".intelligence/packages/@ainova-systems/sync/rules"
    - "intelligence/rules"
  agents:
    - ".intelligence/packages/@ainova-systems/sync/agents"
  skills:
    - ".intelligence/packages/@ainova-systems/sync/skills"

targets:
  agents: { enabled: true, output: "AGENTS.md" }
  claude: { enabled: true, output: ".claude" }

packages:
  "@ainova-systems/sync":
    version: "$PATCH_AHEAD"
MANIFEST
cat > "$P3/intelligence.lock" <<LOCK
# Generated by the intelligence CLI. Do not edit.
lockfile_version: 1
engine_version: "$PATCH_AHEAD"
packages:
  "@ainova-systems/sync":
    requested: "$PATCH_AHEAD"
    url: "https://github.com/ainova-systems/intelligence.git"
    path: "packages/sync"
    resolved: "v$PATCH_AHEAD"
    sha: ""
LOCK
mkdir -p "$P3/.intelligence/packages/@ainova-systems"
cp -r "$REPO/packages/sync" "$P3/.intelligence/packages/@ainova-systems/sync"
cp "$P3/intelligence.yaml" "$OUT/p3.yaml"
cp "$P3/intelligence.lock" "$OUT/p3.lock"
xok "$WARN_LINE $PATCH_AHEAD" "$P3" sync
has "IS_STATUS=ok"
hasnot "@ainova-systems/sync: $PATCH_AHEAD -> $ENGINE_VER"
chk cmp -s "$OUT/p3.yaml" "$P3/intelligence.yaml"
chk cmp -s "$OUT/p3.lock" "$P3/intelligence.lock"
chk grep -q "COMPAT_MARKER" "$P3/AGENTS.md"
xok "all good." "$P3" status --check
has "  ! @ainova-systems/sync at v$PATCH_AHEAD (matches the project schema; the engine is $ENGINE_VER)"
xok "Nothing to apply" "$P3" update --apply
chk cmp -s "$OUT/p3.yaml" "$P3/intelligence.yaml"
chk cmp -s "$OUT/p3.lock" "$P3/intelligence.lock"

echo "== 5. a newer major is refused with exit 4 =="
P4="$OUT/major-ahead"
make_project "$P4" "$MAJOR_AHEAD"
xfail "a newer major schema; refusing" "$P4" sync
[ "$RC" -eq 4 ] || { echo "FAIL: expected rc=4 for a newer major, got $RC"; fail=1; }
has "IS_STATUS=ahead-of-engine IS_DETAIL=stamp=$MAJOR_AHEAD engine=$ENGINE_VER"
hasnot "$WARN_LINE"
chknot test -f "$P4/AGENTS.md"
xfail "a newer major schema; refusing" "$P4" sync --compact
[ "$RC" -eq 4 ] || { echo "FAIL: compact sync lost the rc (got $RC)"; fail=1; }
xfail "a newer major schema; refusing" "$P4" init --preview
xfail "a newer major schema; refusing" "$P4" init --apply
xfail "a newer major schema; refusing" "$P4" update --preview
xfail "is a newer major than this CLI's engine $ENGINE_VER" "$P4" status --check
chk grep -q "^schema_version: \"$MAJOR_AHEAD\"" "$P4/intelligence.yaml"
chknot test -f "$P4/AGENTS.md"

echo "== 6. a project behind the engine still aligns upward =="
BEHIND=""
if [ "$PAT" -gt 0 ]; then BEHIND="$MAJ.$MIN.$((PAT - 1))"
elif [ "$MIN" -gt 0 ]; then BEHIND="$MAJ.$((MIN - 1)).0"
fi
if [ -n "$BEHIND" ]; then
    P5="$OUT/behind"
    make_project "$P5" "$BEHIND"
    xok "schema_version -> $ENGINE_VER" "$P5" sync
    hasnot "$WARN_LINE"
    chk grep -q "^schema_version: \"$ENGINE_VER\"" "$P5/intelligence.yaml"
else
    echo "  (engine $ENGINE_VER has no lower version to stamp; skipped)"
fi

if [ "$fail" -eq 0 ]; then
    echo "e2e-compat: OK"
else
    echo "e2e-compat: FAILED"
    exit 1
fi
