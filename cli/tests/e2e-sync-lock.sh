#!/bin/bash
# One sync per project: a second run refuses while the first holds the lock, a
# lock whose holder is gone is taken over, and no run leaves one behind.
set -euo pipefail
unset CI
REPO="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
REPO="$(cd "$REPO" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/runtime"
cp -R "$REPO/cli" "$REPO/engine" "$TMP/runtime/"
CLI="$TMP/runtime/cli/intelligence"
VERSION="$(tr -d ' \r\n' < "$REPO/engine/VERSION")"
PROJECT="$TMP/project"
LOCK="$PROJECT/.intelligence/sync.lock"
fail=0
checks=0
check() { checks=$((checks + 1)); if ! "$@"; then echo "FAIL: $*"; printf '%s\n' "$OUTPUT" | tail -5; fail=1; fi; }
has() { grep -qF -- "$1" <<< "$OUTPUT"; }
run() {
    RC=0
    OUTPUT="$(cd "$PROJECT" && bash "$CLI" sync "$@" 2>&1)" || RC=$?
}

mkdir -p "$PROJECT/intelligence/rules" "$PROJECT/intelligence/adapters"
cat > "$PROJECT/intelligence.yaml" <<EOF
schema_version: "$VERSION"
project:
  name: lock-test
sources:
  rules:
    - intelligence/rules
targets:
  agents:
    enabled: true
    output: AGENTS.md
  claude:
    enabled: true
    output: .claude
EOF
printf '%s\n' '---' 'description: Base' '---' 'Alpha' > "$PROJECT/intelligence/rules/base.md"

echo '== a sync takes the lock and releases it =='
run --force
check test "$RC" -eq 0
check test ! -e "$LOCK"
check test -f "$PROJECT/AGENTS.md"

echo '== a live holder refuses a second run and keeps everything as it was =='
mkdir -p "$LOCK"
printf '%s %s %s\n' "$$" "${HOSTNAME:-unknown}" "$(date +%s)" > "$LOCK/owner"
cp "$PROJECT/AGENTS.md" "$TMP/agents-before"
printf 'Changed\n' >> "$PROJECT/intelligence/rules/base.md"
run --force
check test "$RC" -ne 0
check has 'another intelligence sync is running in this project'
check has "pid $$"
check has "$LOCK"
check cmp "$TMP/agents-before" "$PROJECT/AGENTS.md"
check test -f "$LOCK/owner"
run --force --compact
check test "$RC" -ne 0
check has 'another intelligence sync is running in this project'

echo '== a holder that no longer runs on this machine is taken over =='
bash -c 'exit 0' &
dead=$!
wait "$dead"
printf '%s %s %s\n' "$dead" "${HOSTNAME:-unknown}" "$(date +%s)" > "$LOCK/owner"
run --force
check test "$RC" -eq 0
check test ! -e "$LOCK"
check grep -q 'Changed' "$PROJECT/AGENTS.md"

echo '== a holder on another machine is never judged from here =='
mkdir -p "$LOCK"
printf '%s %s %s\n' "$dead" "another-host" "$(date +%s)" > "$LOCK/owner"
run --force
check test "$RC" -ne 0
check has 'on another-host'
rm -rf "$LOCK"

echo '== an ownerless lock is a run still starting, until it is an orphan =='
mkdir -p "$LOCK"
run --force
check test "$RC" -ne 0
check has 'another intelligence sync is starting'
touch -t 200001010000 "$LOCK"
run --force
check test "$RC" -eq 0
check test ! -e "$LOCK"

pgid_of() {
    local stat
    local -a f
    if [ -r "/proc/$1/stat" ] && IFS= read -r stat < "/proc/$1/stat"; then
        read -r -a f <<< "${stat##*) }"
        printf '%s' "${f[2]}"
    else
        ps -o pgid= -p "$1" | tr -d ' '
    fi
}

echo '== a dead holder whose process group still runs keeps its lock =='
# The engine and its jobs inherit the wrapper's group; a killed wrapper leaves
# them writing, so its pid alone proves nothing.
mkdir -p "$LOCK"
printf '%s %s %s %s %s\n' "$dead" "${HOSTNAME:-unknown}" "$(date +%s)" "$(pgid_of $$)" "token" > "$LOCK/owner"
run --force
check test "$RC" -ne 0
check has 'another intelligence sync is running in this project'
rm -rf "$LOCK"

echo '== a permission refusal is a live process, not a missing one =='
if LC_ALL=C kill -0 1 2>&1 | grep -q 'Operation not permitted'; then
    mkdir -p "$LOCK"
    printf '%s %s %s\n' 1 "${HOSTNAME:-unknown}" "$(date +%s)" > "$LOCK/owner"
    run --force
    check test "$RC" -ne 0
    check test -f "$LOCK/owner"
    rm -rf "$LOCK"
else
    echo '  (pid 1 is not another user'"'"'s process on this host; case not applicable)'
fi

echo '== an abandoned takeover is left to a person =='
mkdir -p "$LOCK" "$LOCK.takeover"
printf '%s %s %s\n' "$dead" "${HOSTNAME:-unknown}" "$(date +%s)" > "$LOCK/owner"
touch -t 200001010000 "$LOCK.takeover"
run --force
check test "$RC" -ne 0
check has 'abandoned'
check test -d "$LOCK.takeover"
rm -rf "$LOCK" "$LOCK.takeover"

echo '== a writing command honours the lock and leaves none behind =='
mkdir -p "$LOCK"
printf '%s %s %s\n' "$$" "${HOSTNAME:-unknown}" "$(date +%s)" > "$LOCK/owner"
cp "$PROJECT/intelligence.yaml" "$TMP/manifest-before"
RC=0
OUTPUT="$(cd "$PROJECT" && bash "$CLI" adapter enable cursor 2>&1)" || RC=$?
check test "$RC" -ne 0
check has 'another intelligence sync is running in this project'
check cmp "$TMP/manifest-before" "$PROJECT/intelligence.yaml"
rm -rf "$LOCK"
RC=0
OUTPUT="$(cd "$PROJECT" && bash "$CLI" adapter enable cursor 2>&1)" || RC=$?
check test "$RC" -eq 0
check test -d "$PROJECT/.cursor/rules"
check test ! -e "$LOCK"
RC=0
OUTPUT="$(cd "$PROJECT" && bash "$CLI" adapter disable cursor 2>&1)" || RC=$?
check test "$RC" -eq 0
check test ! -e "$LOCK"

echo '== a failed render releases the lock =='
cp "$PROJECT/intelligence.yaml" "$TMP/manifest-good"
awk '$0 == "    output: .claude" { print "    output: \".\""; next } { print }' "$TMP/manifest-good" > "$PROJECT/intelligence.yaml"
run --force
check test "$RC" -ne 0
check test ! -e "$LOCK"
cp "$TMP/manifest-good" "$PROJECT/intelligence.yaml"

echo '== two overlapping runs: the second refuses while the first renders =='
# A project adapter that waits for a release file holds the first run inside the
# render, so the second one starts while the lock is certainly held.
cat > "$PROJECT/intelligence/adapters/slow.sh" <<EOF
adapter_contract_slow() {
    adapter_contract_version 1
    adapter_contract_owned "\$1"
}
sync_to_slow() {
    : > "$TMP/slow-started"
    local waited=0
    until [ -e "$TMP/slow-release" ]; do
        waited=\$((waited + 1))
        [ "\$waited" -lt 600 ] || return 1
        sleep 0.1
    done
    mkdir -p "\$3"
    echo "=== Slow ==="
}
EOF
printf '  slow:\n    enabled: true\n    output: .slow\n' >> "$PROJECT/intelligence.yaml"
(cd "$PROJECT" && bash "$CLI" sync --force > "$TMP/first.out" 2>&1; echo "$?" > "$TMP/first.rc") &
first=$!
waited=0
until [ -e "$TMP/slow-started" ] || [ "$waited" -ge 600 ]; do waited=$((waited + 1)); sleep 0.1; done
check test -e "$TMP/slow-started"
run --force
check test "$RC" -ne 0
check has 'another intelligence sync is running in this project'
: > "$TMP/slow-release"
wait "$first"
check test "$(cat "$TMP/first.rc")" = 0
check grep -q '=== Slow ===' "$TMP/first.out"
check test ! -e "$LOCK"

echo '== a wrapper killed mid-render keeps the lock until its writers stop =='
rm -f "$TMP/slow-started" "$TMP/slow-release"
set -m
(cd "$PROJECT" && exec bash "$CLI" sync --force > "$TMP/killed.out" 2>&1) &
job=$!
set +m
waited=0
until [ -e "$TMP/slow-started" ] || [ "$waited" -ge 600 ]; do waited=$((waited + 1)); sleep 0.1; done
check test -e "$TMP/slow-started"
if [ "$(pgid_of "$job")" = "$job" ]; then
    read -r owner_pid _ < "$LOCK/owner"
    kill -9 "$owner_pid"
    wait "$job" 2>/dev/null || true
    run --force
    check test "$RC" -ne 0
    check has 'another intelligence sync is running in this project'
    : > "$TMP/slow-release"
    waited=0
    while kill -0 -- "-$job" 2>/dev/null && [ "$waited" -lt 600 ]; do waited=$((waited + 1)); sleep 0.1; done
    run --force
    check test "$RC" -eq 0
    check test ! -e "$LOCK"
else
    : > "$TMP/slow-release"
    wait "$job" || true
    echo '  (no separate process group for a background job here; case not applicable)'
fi

[ "$fail" -eq 0 ] && echo "== sync-lock: $checks checks passed =="
exit "$fail"
