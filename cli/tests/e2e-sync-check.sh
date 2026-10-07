#!/bin/bash
# `sync --check` says whether sync would change generated files and changes
# none itself: 0 up to date, 2 sync needed, any other status an error. A valid
# record from the same tooling answers without rendering; otherwise the engine
# renders inside its snapshot transaction and restores every path.
# Fixtures stay outside the checkout so project discovery cannot select it.
set -euo pipefail
unset CI
REPO="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
REPO="$(cd "$REPO" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/runtime/packages" "$TMP/project/intelligence/rules"
cp -R "$REPO/cli" "$REPO/engine" "$TMP/runtime/"
cp -R "$REPO/packages/sync" "$TMP/runtime/packages/sync"
CLI="$TMP/runtime/cli/intelligence"
PROJECT="$TMP/project"
STATE="$PROJECT/.intelligence/sync-cache/state"
VERSION="$(tr -d ' \r\n' < "$REPO/engine/VERSION")"

# The engine runs through `bash .../engine/sync.sh`: a wrapper records every
# render, and can stand in for a renderer that fails with status 2.
mkdir "$TMP/instrumentation"
{
    printf '#!/bin/bash\nLOG=%q\nREAL=%q\n' "$TMP/operations" "$(command -v bash)"
    cat <<'WRAPPER'
case "${1:-}" in
    */engine/sync.sh)
        echo engine >> "$LOG"
        if [ -e "$LOG.exit2" ]; then echo 'Simulated renderer status 2' >&2; exit 2; fi
        ;;
esac
exec "$REAL" "$@"
WRAPPER
} > "$TMP/instrumentation/bash"
chmod +x "$TMP/instrumentation/bash"
export PATH="$TMP/instrumentation:$PATH"

OUT=""; ERR=""; RC=0; checks=0
fail() { printf 'FAIL: %s\n--- stdout\n%s\n--- stderr\n%s\n' "$1" "$OUT" "$ERR" >&2; exit 1; }
check() { checks=$((checks + 1)); "$@" || fail "$*"; }
has() { grep -qF -- "$1" <<< "$OUT"; }
err_has() { grep -qF -- "$1" <<< "$ERR"; }
one_line() { [ -n "$OUT" ] && [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" -eq 1 ]; }
rendered() { grep -qx engine "$TMP/operations"; }
not_rendered() { ! rendered; }
run_in() {
    local dir="$1"
    shift
    RC=0
    : > "$TMP/operations"
    OUT="$(cd "$dir" && bash "$CLI" sync "$@" 2> "$TMP/stderr")" || RC=$?
    ERR="$(cat "$TMP/stderr")"
}
run() { run_in "$PROJECT" "$@"; }
OUTPUTS=(AGENTS.md .claude .codex .agents)
# Keep a copy of every generated path, then age them, so a later check can
# prove it left both bytes and modification times alone.
save_outputs() {
    rm -rf "$TMP/saved"
    mkdir "$TMP/saved"
    (cd "$PROJECT" && cp -R "${OUTPUTS[@]}" "$TMP/saved/")
    (cd "$PROJECT" && find "${OUTPUTS[@]}" -type f -exec touch -t 200101010000 {} +)
    touch -t 200201010000 "$TMP/marker"
}
outputs_kept() {
    local path
    for path in "${OUTPUTS[@]}"; do
        diff -r "$TMP/saved/$path" "$PROJECT/$path" > /dev/null || return 1
    done
    [ -z "$(cd "$PROJECT" && find "${OUTPUTS[@]}" -type f -newer "$TMP/marker")" ]
}
# replace_line <file> <old> <new> — same-size edits keep the old timestamp.
replace_line() {
    awk -v old="$2" -v new="$3" '$0 == old { $0 = new } { print }' "$1" > "$TMP/edited"
    cat "$TMP/edited" > "$1"
}

cat > "$PROJECT/intelligence.yaml" <<EOF
schema_version: "$VERSION"
project:
  name: check-test
sources:
  rules:
    - intelligence/rules
  agents:
    - intelligence/agents
  skills:
    - intelligence/skills
targets:
  agents:
    enabled: true
    output: AGENTS.md
  claude:
    enabled: true
    output: .claude
  codex:
    enabled: true
    output: .codex
EOF
mkdir -p "$PROJECT/intelligence/agents" "$PROJECT/intelligence/skills/demo/assets"
printf '%s\n' '---' 'description: Local rule' '---' 'Alpha' > "$PROJECT/intelligence/rules/base.md"
printf '%s\n' '---' 'description: A skill' '---' '# Demo' > "$PROJECT/intelligence/skills/demo/SKILL.md"
printf 'asset\n' > "$PROJECT/intelligence/skills/demo/assets/data.txt"
printf '%s\n' '---' 'description: A reviewer' 'tier: standard' 'access: readonly' '---' '# Review' > "$PROJECT/intelligence/agents/review.md"
cp "$PROJECT/intelligence.yaml" "$TMP/manifest"
run
check test "$RC" -eq 0
check test -f "$STATE"

echo '== Up to date: one status line, no render, nothing touched =='
save_outputs
run --check
check test "$RC" -eq 0
check one_line
check test "$OUT" = 'IS_STATUS=ok IS_DETAIL=generated files are up to date'
check not_rendered
check outputs_kept
check test ! -e "$PROJECT/.intelligence/sync.lock"
run --check --compact
check test "$RC" -eq 0
check test "$OUT" = 'IS_STATUS=ok IS_DETAIL=generated files are up to date'
check not_rendered

echo '== A same-size source edit with its old timestamp is reported without rendering =='
rule="$PROJECT/intelligence/rules/base.md"
cp -p "$rule" "$TMP/rule-before"
replace_line "$rule" Alpha Bravo
touch -r "$TMP/rule-before" "$rule"
run --check
check test "$RC" -eq 2
check one_line
check has 'IS_STATUS=out-of-date'
check has 'sources changed'
check not_rendered
check outputs_kept
check grep -qx Bravo "$rule"
cp -p "$TMP/rule-before" "$rule"
run --check
check test "$RC" -eq 0
check not_rendered

echo '== A hand-edited generated file is reported and kept =='
printf '<!-- hand edit -->\n' >> "$PROJECT/AGENTS.md"
run --check
check test "$RC" -eq 2
check has 'generated files changed'
check not_rendered
check test "$(tail -n 1 "$PROJECT/AGENTS.md")" = '<!-- hand edit -->'
replace_line "$rule" Alpha Bravo
run --check
check test "$RC" -eq 2
check has 'sources and generated files changed'
cp -p "$TMP/rule-before" "$rule"
run
check test "$RC" -eq 0
run --check
check test "$RC" -eq 0

echo '== Without a record the check renders, compares, restores and records =='
save_outputs
rm -rf "$PROJECT/.intelligence/sync-cache"
run --check
check test "$RC" -eq 0
check one_line
check has 'IS_STATUS=ok'
check has 'rendered to compare'
check rendered
check outputs_kept
check test -f "$STATE"
run --check
check test "$RC" -eq 0
check not_rendered
check test "$OUT" = 'IS_STATUS=ok IS_DETAIL=generated files are up to date'
# The record a check publishes serves sync too.
run
check test "$RC" -eq 0
check has 'Unchanged: generated files are up to date.'
check not_rendered

echo '== Without a record a source change renders, restores and records nothing =='
rm -rf "$PROJECT/.intelligence/sync-cache"
replace_line "$rule" Alpha Charlie
run --check
check test "$RC" -eq 2
check has 'rendering would change generated files'
check rendered
check outputs_kept
check test ! -e "$STATE"
check grep -qx Charlie "$rule"
cp -p "$TMP/rule-before" "$rule"
run --check
check test "$RC" -eq 0
check rendered

echo '== --force always renders: strict mode =='
run --check --force
check test "$RC" -eq 0
check rendered
check outputs_kept
replace_line "$rule" Alpha Bravo
run --check --force
check test "$RC" -eq 2
check has 'rendering would change generated files'
check rendered
check outputs_kept
cp -p "$TMP/rule-before" "$rule"

echo '== Filtered and full checks never stand in for each other =='
run --check agents
check test "$RC" -eq 0
check rendered
run --check agents
check test "$RC" -eq 0
check not_rendered
run --check
check test "$RC" -eq 0
check rendered
run --check
check not_rendered
run --check missing
check test "$RC" -eq 1
check err_has "Adapter 'missing' not found"

echo '== Changed tooling renders instead of claiming sync is needed =='
cp "$TMP/runtime/engine/lib/common.sh" "$TMP/common-before"
printf '\n# changed runtime\n' >> "$TMP/runtime/engine/lib/common.sh"
run --check
check test "$RC" -eq 0
check rendered
cp "$TMP/common-before" "$TMP/runtime/engine/lib/common.sh"
run --check
check test "$RC" -eq 0
check rendered

echo '== A damaged record authorizes nothing =='
printf 'damaged\n' >> "$STATE"
run --check
check test "$RC" -eq 0
check rendered
run --check
check not_rendered
printf 'intelligence-sync-cache-v1 0 0 0\n' > "$STATE"
run --check
check test "$RC" -eq 0
check rendered

echo '== Executable bits count, when the host exposes them =='
generated="$PROJECT/.claude/rules/base.md"
chmod +x "$generated"
if [ -x "$generated" ]; then
    run --check
    check test "$RC" -eq 2
    check has 'generated files changed'
    rm -rf "$PROJECT/.intelligence/sync-cache"
    run --check
    check test "$RC" -eq 2
    check has 'rendering would change generated files'
    check test -x "$generated"
    chmod -x "$generated"
    run --check
    check test "$RC" -eq 0
    # A generated path that is a single file a render recreates. Built-ins
    # rewrite their files in place, so a project adapter (always the render
    # path) supplies one.
    mkdir -p "$PROJECT/intelligence/adapters"
    cat > "$PROJECT/intelligence/adapters/extra.sh" <<'ADAPTER'
adapter_contract_extra() { adapter_contract_version 1; adapter_contract_owned extra.txt; }
sync_to_extra() { rm -f "$1/extra.txt"; printf custom > "$1/extra.txt"; }
ADAPTER
    printf '\n  extra:\n    enabled: true\n    output: extra.txt\n' >> "$PROJECT/intelligence.yaml"
    run
    check test "$RC" -eq 0
    chmod +x "$PROJECT/extra.txt"
    run --check
    check test "$RC" -eq 2
    check rendered
    check test -x "$PROJECT/extra.txt"
    chmod -x "$PROJECT/extra.txt"
    run --check
    check test "$RC" -eq 0
    rm -rf "$PROJECT/intelligence/adapters" "$PROJECT/extra.txt"
    cp "$TMP/manifest" "$PROJECT/intelligence.yaml"
    run
    check test "$RC" -eq 0
else
    echo 'SKIP executable-bit cases: filesystem derives executable bits from content'
fi

echo '== Renderer failures keep their status, restore outputs and record nothing =='
run --check
check test "$RC" -eq 0
save_outputs
cp "$STATE" "$TMP/state-before"
awk '{ print; if ($0 == "  codex:") print "    warn_project_doc_limit: 0" }' "$TMP/manifest" > "$PROJECT/intelligence.yaml"
run --check --force
check test "$RC" -eq 1
check err_has 'restored to their pre-sync state'
check outputs_kept
check cmp "$TMP/state-before" "$STATE"
cp "$TMP/manifest" "$PROJECT/intelligence.yaml"
: > "$TMP/operations.exit2"
run --check --force
check test "$RC" -eq 1
check err_has 'Simulated renderer status 2'
rm "$TMP/operations.exit2"
run --check
check test "$RC" -eq 0

echo '== Alignment is reported, never applied, in CI or not =='
cp "$PROJECT/intelligence.yaml" "$TMP/manifest-current"
awk '/^schema_version:/ { print "schema_version: \"0.1.0\""; next } { print }' "$TMP/manifest-current" > "$PROJECT/intelligence.yaml"
cp "$PROJECT/intelligence.yaml" "$TMP/manifest-behind"
run --check
check test "$RC" -eq 2
check one_line
check has 'IS_STATUS=out-of-date'
check has "intelligence init"
check cmp "$TMP/manifest-behind" "$PROJECT/intelligence.yaml"
check not_rendered
CI=true run --check
check test "$RC" -eq 2
check has "intelligence init"
check cmp "$TMP/manifest-behind" "$PROJECT/intelligence.yaml"
cp "$TMP/manifest-current" "$PROJECT/intelligence.yaml"

echo '== Errors are distinct from "sync needed" =='
awk '/^schema_version:/ { print "schema_version: \"99.0.0\""; next } { print }' "$TMP/manifest-current" > "$PROJECT/intelligence.yaml"
run --check
check test "$RC" -eq 4
check has 'IS_STATUS=ahead-of-engine'
cp "$TMP/manifest-current" "$PROJECT/intelligence.yaml"
printf 'lockfile_version: 99\npackages:\n' > "$PROJECT/intelligence.lock"
run --check
check test "$RC" -eq 1
check err_has 'invalid intelligence.lock'
check not_rendered
rm "$PROJECT/intelligence.lock"
mkdir "$TMP/empty"
run_in "$TMP/empty" --check
check test "$RC" -eq 1
check err_has 'no intelligence project found'
LOCK="$PROJECT/.intelligence/sync.lock"
mkdir "$LOCK"
printf '%s %s %s\n' "$$" "${HOSTNAME:-unknown}" "$(date +%s)" > "$LOCK/owner"
run --check
check test "$RC" -eq 1
check err_has 'another intelligence sync is running in this project'
rm -rf "$LOCK"
run --check
check test "$RC" -eq 0

echo '== A missing store is restored from the lock before the check =='
STORE_PROJECT="$TMP/store"
mkdir "$STORE_PROJECT"
OUT="$(cd "$STORE_PROJECT" && bash "$CLI" init --targets agents --no-sync 2>&1)" || fail 'offline init'
REAL_GIT="$(command -v git)"
mkdir "$TMP/no-network"
cat > "$TMP/no-network/git" <<EOF
#!/bin/bash
case "\$1" in clone|fetch|ls-remote) echo 'forbidden network acquisition' >&2; exit 91 ;; esac
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$TMP/no-network/git"
ORIGINAL_PATH="$PATH"
export PATH="$TMP/no-network:$PATH"
run_in "$STORE_PROJECT"
check test "$RC" -eq 0
cp "$STORE_PROJECT/intelligence.yaml" "$TMP/store-manifest"
cp "$STORE_PROJECT/intelligence.lock" "$TMP/store-lock"
cp "$STORE_PROJECT/AGENTS.md" "$TMP/store-agents"
rm -rf "$STORE_PROJECT/.intelligence"
run_in "$STORE_PROJECT" --check
check test "$RC" -eq 0
check one_line
check has 'IS_STATUS=ok'
check err_has 'restoring package store from intelligence.lock'
check test -d "$STORE_PROJECT/.intelligence/packages/@ainova-systems/sync"
check cmp "$TMP/store-manifest" "$STORE_PROJECT/intelligence.yaml"
check cmp "$TMP/store-lock" "$STORE_PROJECT/intelligence.lock"
check cmp "$TMP/store-agents" "$STORE_PROJECT/AGENTS.md"
# A restore that cannot finish is an error, never a verdict.
rm -rf "$STORE_PROJECT/.intelligence/packages"
printf 'not a directory\n' > "$STORE_PROJECT/.intelligence/packages"
run_in "$STORE_PROJECT" --check
check test "$RC" -ne 0
check test "$RC" -ne 2
check cmp "$TMP/store-agents" "$STORE_PROJECT/AGENTS.md"
export PATH="$ORIGINAL_PATH"

echo "== sync-check: $checks checks passed =="
