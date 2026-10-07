#!/bin/bash
# Unit suite for the Windows delegation in cli/tests/verify.sh (decision 0014):
# when a run moves to WSL, which tree it ships there, and how the verdict comes
# back. `uname`, `wsl.exe` and `shellcheck` are stubs, and the stub `wsl.exe` runs
# its command with the local bash, so the suite needs no Windows host and no WSL.
set -euo pipefail
REPO="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
fail=0

mkdir -p "$OUT/bin"
cat > "$OUT/bin/uname" <<'EOF'
#!/bin/bash
echo "MINGW64_NT-10.0-26100"
EOF
# Records every call, refuses the tool probe when FAKE_WSL_BROKEN is set, and
# runs what follows --exec here. The delegated runner strips /mnt/ entries from
# PATH, which leaves this stub directory, and the stubs, in place.
cat > "$OUT/bin/wsl.exe" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_WSL_LOG"
while [ $# -gt 0 ] && [ "$1" != --exec ]; do shift; done
shift
if [ -n "${FAKE_WSL_BROKEN:-}" ]; then exit 1; fi
exec "$@"
EOF
# Lists the files it checked; any file containing BAD is a finding.
cat > "$OUT/bin/shellcheck" <<'EOF'
#!/bin/bash
rc=0
for arg; do
    case "$arg" in -*) continue ;; esac
    printf '%s\n' "$arg" >> "$FAKE_SHELLCHECK_LOG"
    if grep -q BAD "$arg"; then echo "finding in $arg"; rc=1; fi
done
exit "$rc"
EOF
chmod +x "$OUT/bin/uname" "$OUT/bin/wsl.exe" "$OUT/bin/shellcheck"

# A project the runner can verify: its own copy of verify.sh, one engine script,
# and a lint scope small enough to run here.
PROJ="$OUT/proj"
mkdir -p "$PROJ/cli/tests" "$PROJ/engine"
cp "$REPO/cli/tests/verify.sh" "$PROJ/cli/tests/verify.sh"
printf '#!/bin/bash\necho tracked\n' > "$PROJ/engine/tracked.sh"
printf '#!/bin/bash\necho doomed\n' > "$PROJ/engine/deleted.sh"
printf 'engine/ignored.sh\n' > "$PROJ/.gitignore"
git -C "$PROJ" init --quiet
git -C "$PROJ" config core.autocrlf false
git -C "$PROJ" -c user.email=t@t -c user.name=t add -A
git -C "$PROJ" -c user.email=t@t -c user.name=t commit --quiet -m fixture
rm "$PROJ/engine/deleted.sh"
printf '#!/bin/bash\necho untracked\n' > "$PROJ/engine/untracked.sh"
printf '#!/bin/bash\necho ignored\n' > "$PROJ/engine/ignored.sh"

export FAKE_WSL_LOG="$OUT/wsl.log" FAKE_SHELLCHECK_LOG="$OUT/shellcheck.log"
RC=0
OUTPUT=""
# verify [NAME=value...] [scope] — run the fixture's runner on a Windows-looking
# PATH, with CI and every switch cleared unless the case sets one.
verify() {
    local arg scope=""
    local -a assignments=()
    for arg; do
        case "$arg" in
            *=*) assignments+=("$arg") ;;
            *) scope="$arg" ;;
        esac
    done
    : > "$FAKE_WSL_LOG"
    : > "$FAKE_SHELLCHECK_LOG"
    RC=0
    OUTPUT="$(cd "$PROJ" && env -u CI -u VERIFY_DELEGATED -u INTELLIGENCE_VERIFY_NATIVE \
        -u INTELLIGENCE_VERIFY_WSL_DISTRO -u FAKE_WSL_BROKEN PATH="$OUT/bin:$PATH" \
        ${assignments[@]+"${assignments[@]}"} bash cli/tests/verify.sh ${scope:+"$scope"} 2>&1)" || RC=$?
}
expect() { if ! grep -qF -- "$2" <<< "$OUTPUT"; then echo "FAIL: $1 — output lacks '$2'"; printf '%s\n' "$OUTPUT" | tail -8; fail=1; fi; }
expect_not() { if grep -qF -- "$2" <<< "$OUTPUT"; then echo "FAIL: $1 — output has '$2'"; fail=1; fi; }
expect_rc() { if [ "$RC" -ne "$2" ]; then echo "FAIL: $1 — exit $RC, want $2"; printf '%s\n' "$OUTPUT" | tail -8; fail=1; fi; }
checked() { grep -q -- "engine/$1\$" "$FAKE_SHELLCHECK_LOG"; }
delegated() { grep -qF 'tar -xf - -C' "$FAKE_WSL_LOG"; }

echo "== a Git Bash run moves to WSL with the tree git sees =="
verify lint-engine
expect_rc "delegated run" 0
expect "delegated run" "=== WSL: 'lint-engine'"
expect "delegated run" "ok: lint: engine"
delegated || { echo "FAIL: the scope never reached wsl.exe"; fail=1; }
checked tracked.sh || { echo "FAIL: tracked file missing from the copy"; fail=1; }
checked untracked.sh || { echo "FAIL: untracked file missing from the copy"; fail=1; }
if checked ignored.sh; then echo "FAIL: ignored file reached the copy"; fail=1; fi
if checked deleted.sh; then echo "FAIL: deleted file reached the copy"; fail=1; fi
if [ "$(grep -c '=== verify ok ===' <<< "$OUTPUT")" -ne 1 ]; then
    echo "FAIL: the verdict must be printed once, by the caller"
    fail=1
fi

echo "== a finding inside WSL fails the caller =="
printf '#!/bin/bash\necho BAD\n' > "$PROJ/engine/untracked.sh"
verify lint-engine
expect_rc "finding in WSL" 1
expect "finding in WSL" "finding in"
expect "finding in WSL" "=== verify FAILED ==="
expect_not "finding in WSL" "=== verify ok ==="
printf '#!/bin/bash\necho untracked\n' > "$PROJ/engine/untracked.sh"

echo "== a named distribution reaches wsl.exe =="
verify INTELLIGENCE_VERIFY_WSL_DISTRO=Fixture-Distro lint-engine
expect_rc "named distribution" 0
grep -q -- '^-d Fixture-Distro --exec' "$FAKE_WSL_LOG" || { echo "FAIL: -d Fixture-Distro not passed"; fail=1; }

echo "== a distribution without the tools keeps Git Bash and says so =="
verify FAKE_WSL_BROKEN=1 lint-engine
expect_rc "broken distribution" 0
expect "broken distribution" "NOTE: WSL distribution 'default' cannot run git awk tar mktemp shellcheck"
expect_not "broken distribution" "=== WSL:"
delegated && { echo "FAIL: delegated to a distribution that failed its probe"; fail=1; }
checked untracked.sh || { echo "FAIL: the Git Bash run did not lint"; fail=1; }

echo "== INTELLIGENCE_VERIFY_NATIVE=1 and CI never delegate =="
for switch in INTELLIGENCE_VERIFY_NATIVE=1 CI=true; do
    verify "$switch" lint-engine
    expect_rc "$switch" 0
    expect_not "$switch" "=== WSL:"
    expect_not "$switch" "NOTE:"
    [ ! -s "$FAKE_WSL_LOG" ] || { echo "FAIL: $switch still called wsl.exe"; fail=1; }
done

echo "== a bare run with nothing to verify never starts WSL =="
git -C "$PROJ" -c user.email=t@t -c user.name=t add -A
git -C "$PROJ" -c user.email=t@t -c user.name=t commit --quiet -m settle
git -C "$PROJ" branch --quiet -M main
verify
expect_rc "nothing applicable" 0
expect "nothing applicable" "lint — no shell source changed"
[ ! -s "$FAKE_WSL_LOG" ] || { echo "FAIL: a run with nothing to verify called wsl.exe"; fail=1; }

if [ "$fail" -ne 0 ]; then
    echo "unit-verify: FAILED"
    exit 1
fi
echo "unit-verify: all checks passed"
