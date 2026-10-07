#!/bin/bash
# `sync --check` says whether sync would change generated files and changes
# none itself: 0 up to date, 2 sync needed, any other status an error. A valid
# record from the same tooling answers without rendering; otherwise the engine
# renders in a private project copy without touching live output.
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
        if [ -e "$LOG.warnings" ]; then printf 'WARNING: Probe warning\n    Probe continuation\n' >&2; fi
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
check has 'rendering would change generated files'
check rendered
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

echo '== A never-synced check leaves no output directories behind =='
FRESH="$TMP/fresh"
mkdir "$FRESH"
cp -a "$PROJECT/intelligence" "$FRESH/"
cp "$TMP/manifest" "$FRESH/intelligence.yaml"
run_in "$FRESH" --check --force
check test "$RC" -eq 2
check test ! -e "$FRESH/AGENTS.md"
check test ! -e "$FRESH/.claude"
check test ! -e "$FRESH/.agents"
check test ! -e "$FRESH/.codex"

echo '== A trailing slash in a source keeps cache checks usable =='
replace_line "$PROJECT/intelligence.yaml" '    - intelligence/rules' '    - intelligence/rules/'
run
check test "$RC" -eq 0
run --check
check test "$RC" -eq 0
check not_rendered
cp "$TMP/manifest" "$PROJECT/intelligence.yaml"
run
check test "$RC" -eq 0

echo '== Warnings from a successful check reach stderr =='
awk '{ print; if ($0 == "  codex:") print "    warn_project_doc_limit: 1" }' "$TMP/manifest" > "$PROJECT/intelligence.yaml"
run --check --force
check test "$RC" -eq 0
check err_has 'WARNING: Codex'
cp "$TMP/manifest" "$PROJECT/intelligence.yaml"

echo '== External relative adapter inputs retain their resolution =='
LINK_PROJECT="$TMP/link-project"
mkdir -p "$LINK_PROJECT/intelligence/adapters" "$LINK_PROJECT/intelligence/rules"
cp "$PROJECT/intelligence/rules/base.md" "$LINK_PROJECT/intelligence/rules/base.md"
cat > "$LINK_PROJECT/intelligence.yaml" <<EOF
schema_version: "$VERSION"
sources:
  rules:
    - intelligence/rules
targets:
  probe: { enabled: true, output: ".probe" }
EOF
cat > "$TMP/probe.sh" <<'EOF'
adapter_contract_probe() { adapter_contract_version 1; adapter_contract_owned .probe; }
sync_to_probe() {
    mkdir -p "$1/.probe"
    ln -sf ../../../outside "$1/.probe/link"
    printf 'probe\n' > "$1/.probe/value"
}
EOF
if MSYS=winsymlinks:nativestrict ln -s ../../../probe.sh "$LINK_PROJECT/intelligence/adapters/probe.sh" 2>/dev/null; then
    run_in "$LINK_PROJECT"
    check test "$RC" -eq 0
    run_in "$LINK_PROJECT" --check --force
    check test "$RC" -eq 0
    check test "$(readlink "$LINK_PROJECT/.probe/link")" = ../../../outside
    # Resolved target equality is insufficient: link spelling is part of output.
    ln -sf "$TMP/../outside" "$LINK_PROJECT/.probe/link"
    run_in "$LINK_PROJECT" --check --force
    check test "$RC" -eq 2
    check test "$(readlink "$LINK_PROJECT/.probe/link")" = "$TMP/../outside"
    # A root link used as an output ancestor remains inside the private project.
    ln -s "$LINK_PROJECT" "$LINK_PROJECT/root-link"
    sed 's/output: ".probe"/output: "root-link\/.probe"/' "$LINK_PROJECT/intelligence.yaml" > "$TMP/link-manifest"
    cp "$TMP/link-manifest" "$LINK_PROJECT/intelligence.yaml"
    cat > "$TMP/probe.sh" <<'EOF'
adapter_contract_probe() { adapter_contract_version 1; adapter_contract_owned "$1"; }
sync_to_probe() { mkdir -p "$1/$3"; printf 'probe\n' > "$1/$3/value"; }
EOF
    run_in "$LINK_PROJECT"
    check test "$RC" -eq 0
    run_in "$LINK_PROJECT" --check --force
    check test "$RC" -eq 0
else
    echo '  (native symlinks unavailable ? external-input cases skipped)'
fi

echo '== Cached and rendered checks keep indented warning continuations =='
touch "$TMP/operations.warnings"
run --force
check test "$RC" -eq 0
run --check
check test "$RC" -eq 0
check not_rendered
check err_has 'WARNING: Probe warning'
check err_has '    Probe continuation'
run --check --force
check test "$RC" -eq 0
check err_has 'WARNING: Probe warning'
check err_has '    Probe continuation'
rm "$TMP/operations.warnings"
run --force
check test "$RC" -eq 0

echo '== Preserved managed siblings do not make a check report generated changes =='
printf '# Hand-written skills notes\n' > "$PROJECT/.agents/skills/README.md"
run
check test "$RC" -eq 0
printf 'Edited notes\n' >> "$PROJECT/.agents/skills/README.md"
run --check
check test "$RC" -eq 0
check grep -qx 'Edited notes' "$PROJECT/.agents/skills/README.md"
run --check --force
check test "$RC" -eq 0
check grep -qx 'Edited notes' "$PROJECT/.agents/skills/README.md"

echo '== Inherited check state cannot turn a normal sync into a check =='
replace_line "$rule" Alpha Bravo
export IS_SYNC_CHECK="$TMP/inherited-verdict"
run --force
unset IS_SYNC_CHECK
check test "$RC" -eq 0
check grep -q Bravo "$PROJECT/AGENTS.md"
check test ! -e "$TMP/inherited-verdict"
cp -p "$TMP/rule-before" "$rule"
run
check test "$RC" -eq 0

echo '== Doubled slash dispatcher invocation finds the bundled engine =='
OUT="$(bash "$TMP/runtime/cli//intelligence" version 2> "$TMP/stderr")"
check has "$VERSION"

echo '== A concurrent write during a check is preserved =='
cp "$TMP/runtime/engine/sync.sh" "$TMP/engine-before"
# The private render writes only its tree; simulate a user writing the real
# project's preserved sibling after the check copied it.
printf '\nprintf "Concurrent edit\\n" >> %q\n' "$PROJECT/.agents/skills/README.md" >> "$TMP/runtime/engine/sync.sh"
run --check --force
check test "$RC" -eq 0
check grep -qx 'Concurrent edit' "$PROJECT/.agents/skills/README.md"
cp "$TMP/engine-before" "$TMP/runtime/engine/sync.sh"

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
    check has 'rendering would change generated files'
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

echo '== Links in generated paths come back as links, when links are available =='
mkdir "$TMP/link-target"
printf external > "$TMP/link-target/file"
source_link="$PROJECT/intelligence/skills/demo/assets/link"
if MSYS=winsymlinks:nativestrict ln -s "$TMP/link-target/file" "$source_link" 2>/dev/null && [ -L "$source_link" ]; then
    run
    check test "$RC" -eq 0
    check test ! -e "$PROJECT/.claude/skills/demo/assets/link"
    check test ! -e "$PROJECT/.agents/skills/demo/assets/link"
    # Skills never emit escaping links; a hand-edited generated link still
    # belongs to the rollback snapshot and must come back untouched.
    ln -s "$TMP/link-target/file" "$PROJECT/.claude/skills/demo/assets/link"
    ln -s "$TMP/link-target/file" "$PROJECT/.agents/skills/demo/assets/link"
    save_outputs
    # The fingerprint cannot carry a link, so every check takes the render path.
    run --check
    check test "$RC" -eq 2
    check rendered
    check outputs_kept
    check test "$(readlink "$PROJECT/.claude/skills/demo/assets/link")" = "$TMP/link-target/file"
    check test "$(readlink "$PROJECT/.agents/skills/demo/assets/link")" = "$TMP/link-target/file"
    rm "$source_link"
    ln -s "$PROJECT/intelligence/skills/demo/assets/data.txt" "$source_link"
    run
    check test "$RC" -eq 0
    run --check --force
    check test "$RC" -eq 0
    rm "$source_link"
    run
    check test "$RC" -eq 0
    check test ! -e "$PROJECT/.claude/skills/demo/assets/link"
else
    rm -f "$source_link"
    echo 'SKIP link cases: host cannot create native symlinks'
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
# A hand-edited sources list must remain byte-identical even after restore.
awk '!/packages\/@ainova-systems\/sync\/rules/' "$STORE_PROJECT/intelligence.yaml" > "$TMP/omitted-source"
cp "$TMP/omitted-source" "$STORE_PROJECT/intelligence.yaml"
rm -rf "$STORE_PROJECT/.intelligence"
run_in "$STORE_PROJECT" --check
check test "$RC" -eq 2
check cmp "$TMP/omitted-source" "$STORE_PROJECT/intelligence.yaml"
cp "$TMP/store-manifest" "$STORE_PROJECT/intelligence.yaml"

# A restore that cannot finish is an error, never a verdict.
rm -rf "$STORE_PROJECT/.intelligence/packages"
printf 'not a directory\n' > "$STORE_PROJECT/.intelligence/packages"
run_in "$STORE_PROJECT" --check
check test "$RC" -ne 0
check test "$RC" -ne 2
check cmp "$TMP/store-agents" "$STORE_PROJECT/AGENTS.md"
export PATH="$ORIGINAL_PATH"

# Decision 0019: sources: may name a package's directory by full name or by
# alias, and both render from the store path. The cache must fingerprint that
# directory, or a change to the package's content would read as up to date.
REFS="$TMP/references"
mkdir "$REFS"
OUT="$(cd "$REFS" && bash "$CLI" init --targets claude 2>&1)" || fail 'init of the references project'
STORE_SYNC=".intelligence/packages/@ainova-systems/sync"
package_rule="$REFS/$STORE_SYNC/rules/intelligence-authoring.md"
rendered_rule="$REFS/.claude/rules/intelligence-authoring.md"
check test -f "$package_rule"
check test -f "$rendered_rule"
# respell <from> <to> — e2e-sources.sh's: the first quoted "<from>… on each
# manifest line becomes "<to>…; nothing else moves.
respell() {
    awk -v from="\"$1" -v to="\"$2" '
        { i = index($0, from); if (i) $0 = substr($0, 1, i - 1) to substr($0, i + length(from)); print }
    ' "$REFS/intelligence.yaml" > "$TMP/respelled"
    cat "$TMP/respelled" > "$REFS/intelligence.yaml"
}
# package_content_change <marker> — edit the package's rule in the store, then
# prove neither a check nor a sync answers from the record made before it.
package_content_change() {
    run_in "$REFS"
    check test "$RC" -eq 0
    run_in "$REFS" --check
    check test "$RC" -eq 0
    check not_rendered
    printf '\n%s\n' "$1" >> "$package_rule"
    run_in "$REFS" --check
    check test "$RC" -eq 2
    check has 'sources changed'
    check not_rendered
    run_in "$REFS"
    check test "$RC" -eq 0
    check rendered
    check grep -qx "$1" "$rendered_rule"
    run_in "$REFS" --check
    check test "$RC" -eq 0
    check not_rendered
}

echo '== A package source named by full name is fingerprinted at its store path =='
respell "$STORE_SYNC/" "@ainova-systems/sync/"
check grep -q '"@ainova-systems/sync/rules"' "$REFS/intelligence.yaml"
check test "$(grep -c "$STORE_SYNC" "$REFS/intelligence.yaml" || true)" -eq 0
package_content_change FULL_NAME_MARKER

echo '== A package source named by alias is fingerprinted at its store path =='
OUT="$(cd "$REFS" && bash "$CLI" package alias @ainova-systems/sync sync 2>&1)" || fail 'package alias'
respell "@ainova-systems/sync/" "sync:"
check grep -q '"sync:rules"' "$REFS/intelligence.yaml"
package_content_change ALIAS_MARKER

echo "== sync-check: $checks checks passed =="
