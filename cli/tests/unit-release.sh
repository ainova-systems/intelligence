#!/bin/bash
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

mkdir -p "$OUT/bin"
cat > "$OUT/bin/npm" <<'EOF'
#!/bin/bash
set -euo pipefail
case "${1:-} ${2:-} ${3:-}" in
    "view @ainova-systems/intelligence dist-tags.latest")
        printf '%s\n' "${FAKE_LATEST:-}"
        ;;
    "view @ainova-systems/intelligence dist-tags.next")
        printf '%s\n' "${FAKE_NEXT:-}"
        ;;
    "dist-tag add "*)
        printf '%s\n' "$*" >> "$FAKE_LOG"
        ;;
    *)
        echo "unexpected npm invocation: $*" >&2
        exit 99
        ;;
esac
EOF
chmod +x "$OUT/bin/npm"

export PATH="$OUT/bin:$PATH"
export FAKE_LOG="$OUT/npm.log"

run_case() {
    : > "$FAKE_LOG"
    FAKE_LATEST="${1:-}" FAKE_NEXT="${2:-}" \
        bash "$ROOT/npm/align-dist-tags.sh" "$3" "$4" >/dev/null
}

expect_call() {
    grep -qxF "$1" "$FAKE_LOG" || {
        echo "expected npm call: $1" >&2
        echo "actual:" >&2
        cat "$FAKE_LOG" >&2
        exit 1
    }
}

expect_no_calls() {
    [ ! -s "$FAKE_LOG" ] || {
        echo "expected no npm mutation, got:" >&2
        cat "$FAKE_LOG" >&2
        exit 1
    }
}

echo "== stable release aligns stale next =="
run_case "0.11.2" "0.11.0-rc.14" latest "0.11.3"
expect_call "dist-tag add @ainova-systems/intelligence@0.11.3 next"

echo "== stable release creates missing next =="
run_case "0.11.3" "" latest "0.11.3"
expect_call "dist-tag add @ainova-systems/intelligence@0.11.3 next"

echo "== stable release leaves aligned next alone =="
run_case "0.11.3" "0.11.3" latest "0.11.3"
expect_no_calls

echo "== prerelease advances prerelease-only latest =="
run_case "0.12.0-rc.1" "0.12.0-rc.1" next "0.12.0-rc.2"
expect_call "dist-tag add @ainova-systems/intelligence@0.12.0-rc.2 latest"

echo "== prerelease preserves stable latest =="
run_case "0.11.3" "0.12.0-rc.1" next "0.12.0-rc.2"
expect_no_calls

echo "== unknown channel fails closed =="
if bash "$ROOT/npm/align-dist-tags.sh" beta "0.11.3" >/dev/null 2>&1; then
    echo "unknown channel unexpectedly succeeded" >&2
    exit 1
fi

echo "unit-release: ALL OK"
