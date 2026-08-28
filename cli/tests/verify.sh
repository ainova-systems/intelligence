#!/bin/bash
# The repository's single verification gate.
#
# One runner owns the gate list so the local flow, CONTRIBUTING, the pull-request
# template and CI cannot drift: adding a gate means editing this file, never a
# workflow. Without a scope argument it reads the diff against the default branch
# and runs only the gates that diff can affect, cheapest first, then prints every
# gate it skipped — a run that verified nothing must never look green.
#
#   bash cli/tests/verify.sh              gates the current diff can affect
#   bash cli/tests/verify.sh all          every gate
#   bash cli/tests/verify.sh lint         shellcheck over cli/ and engine/
#   bash cli/tests/verify.sh lint-cli     shellcheck over cli/ only
#   bash cli/tests/verify.sh lint-engine  shellcheck over engine/ only
#   bash cli/tests/verify.sh tests        the five CLI suites
#
# Suites take a repository root so CI can point them at its workspace; they
# default to the tree this script lives in, which is what the local flow wants.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"

SUITES=(unit-semver unit-manifest e2e-packages e2e-lifecycle e2e-negative)

failed=0
skipped=()

banner() { printf '\n=== %s ===\n' "$1"; }

require_shellcheck() {
    if command -v shellcheck >/dev/null 2>&1; then
        return 0
    fi
    echo "shellcheck is not installed, so the lint gate cannot run." >&2
    echo "Install it and re-run: brew install shellcheck | scoop install shellcheck | apt-get install shellcheck" >&2
    return 1
}

lint_engine() {
    require_shellcheck || return 1
    # The adapter template is invalid shell until it is scaffolded: `<name>`
    # parses as input redirection.
    find engine -name '*.sh' -not -path '*/adapters/_template.sh' \
        -print0 | xargs -0 shellcheck --severity=warning
}

lint_cli() {
    local rc=0
    require_shellcheck || return 1
    shellcheck --severity=warning cli/intelligence || rc=1
    find cli -name '*.sh' -print0 | xargs -0 shellcheck --severity=warning || rc=1
    return "$rc"
}

run_suites() {
    local rc=0 suite
    for suite in "${SUITES[@]}"; do
        banner "test: $suite"
        bash "cli/tests/$suite.sh" "$REPO" || rc=1
    done
    return "$rc"
}

# gate <label> <function>
gate() {
    local label="$1" fn="$2"
    banner "$label"
    if "$fn"; then
        printf 'ok: %s\n' "$label"
    else
        printf 'FAILED: %s\n' "$label" >&2
        failed=1
    fi
}

# The diff this branch adds on top of the default branch, plus whatever is still
# uncommitted. Git failing to answer is a refusal, not an empty answer.
changed_paths() {
    local base="" upstream
    for upstream in origin/main main; do
        if git rev-parse --verify -q "$upstream" >/dev/null 2>&1; then
            base="$(git merge-base HEAD "$upstream" 2>/dev/null || true)"
            if [ -n "$base" ]; then
                break
            fi
        fi
    done
    [ -n "$base" ] || base="$(git rev-parse --verify -q HEAD 2>/dev/null || true)"
    [ -n "$base" ] || return 1

    git diff --name-only "$base" || return 1
    git status --porcelain=1 | awk 'NF { print $NF }' || return 1
}

main() {
    local scope="${1:-auto}" paths="" want_lint=0 want_tests=0

    case "$scope" in
        lint)        gate "lint: engine" lint_engine; gate "lint: cli" lint_cli ;;
        lint-engine) gate "lint: engine" lint_engine ;;
        lint-cli)    gate "lint: cli" lint_cli ;;
        tests)       gate "tests: CLI suites" run_suites ;;
        all)
            gate "lint: engine" lint_engine
            gate "lint: cli" lint_cli
            gate "tests: CLI suites" run_suites
            ;;
        auto)
            if ! paths="$(changed_paths)"; then
                echo "git could not report the changed files — refusing to report success." >&2
                return 1
            fi
            # Shell sources decide the lint gate; anything the engine renders or
            # the CLI resolves decides the suites.
            if grep -Eq '^(cli|engine)/.*\.sh$|^cli/intelligence$' <<< "$paths"; then
                want_lint=1
            fi
            if grep -Eq '^(cli|engine|packages/sync|examples|npm)/' <<< "$paths"; then
                want_tests=1
            fi

            if [ "$want_lint" -eq 1 ]; then
                gate "lint: engine" lint_engine
                gate "lint: cli" lint_cli
            else
                skipped+=("lint — no shell source changed")
            fi

            if [ "$want_tests" -eq 1 ]; then
                gate "tests: CLI suites" run_suites
            else
                skipped+=("tests — no cli/, engine/, packages/sync/, examples/ or npm/ change")
            fi
            ;;
        *)
            echo "unknown scope '$scope' (use: auto | all | lint | lint-cli | lint-engine | tests)" >&2
            return 2
            ;;
    esac

    if [ "${#skipped[@]}" -gt 0 ]; then
        banner "skipped"
        printf '  %s\n' "${skipped[@]}"
    fi

    if [ "$failed" -ne 0 ]; then
        banner "verify FAILED"
        return 1
    fi
    banner "verify ok"
}

main "$@"
