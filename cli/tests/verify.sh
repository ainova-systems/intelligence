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
#   bash cli/tests/verify.sh lint-cli     shellcheck over cli/ and npm/ scripts
#   bash cli/tests/verify.sh lint-engine  shellcheck over engine/ only
#   bash cli/tests/verify.sh tests        the hermetic suites
#
# Suites take a repository root so CI can point them at its workspace; they
# default to the tree this script lives in, which is what the local flow wants.
#
# On Windows the scope runs in WSL when a distribution can run it (decision
# 0014); INTELLIGENCE_VERIFY_NATIVE=1 keeps it in Git Bash, and
# INTELLIGENCE_VERIFY_WSL_DISTRO names a distribution other than the default.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"

SUITES=(unit-semver unit-manifest unit-engine unit-gitignore unit-release unit-fetch unit-upgrade unit-verify e2e-sources e2e-packages e2e-lifecycle e2e-negative e2e-lock-validation e2e-compat e2e-sync-cache e2e-concurrency e2e-sync-lock e2e-store-sha)

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
    find npm -maxdepth 1 -name '*.sh' -print0 | xargs -0 shellcheck --severity=warning || rc=1
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

run_scope() {
    case "$1" in
        lint)        gate "lint: engine" lint_engine; gate "lint: cli" lint_cli ;;
        lint-engine) gate "lint: engine" lint_engine ;;
        lint-cli)    gate "lint: cli" lint_cli ;;
        tests)       gate "tests: CLI suites" run_suites ;;
        all)
            gate "lint: engine" lint_engine
            gate "lint: cli" lint_cli
            gate "tests: CLI suites" run_suites
            ;;
    esac
}

# --- Windows: the same scope in WSL (decision 0014) -------------------------
# Git Bash starts a process in 50-120 ms where Linux needs about one, and the
# suites start tens of thousands: the test scope takes close to an hour in
# Git Bash and under three in WSL. The copy lives in the distribution's own
# filesystem, because a /mnt/ path reaches the tree through 9P, which is slower
# than Git Bash itself. CI never delegates.

# wsl_cmd <args> - wsl.exe without Git Bash rewriting POSIX-looking arguments
# into Windows paths. The guarded expansion keeps an empty array legal under
# `set -u` on bash 3.2, where unit-verify runs this path on macOS.
wsl_cmd() {
    local -a distro=()
    if [ -n "${INTELLIGENCE_VERIFY_WSL_DISTRO:-}" ]; then
        distro=(-d "$INTELLIGENCE_VERIFY_WSL_DISTRO")
    fi
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' wsl.exe ${distro[@]+"${distro[@]}"} "$@"
}

# wsl_ready <scope> - the run is on Git Bash and a distribution has every tool
# <scope> needs. A run that could have moved but cannot says so.
wsl_ready() {
    local -a tools=(git awk tar mktemp)
    [ -z "${VERIFY_DELEGATED:-}" ] || return 1
    [ -z "${CI:-}" ] || return 1
    [ "${INTELLIGENCE_VERIFY_NATIVE:-}" != 1 ] || return 1
    case "$(uname -s)" in MINGW*|MSYS*) ;; *) return 1 ;; esac
    case "$1" in lint*|all) tools+=(shellcheck) ;; esac
    if command -v wsl.exe >/dev/null 2>&1 && wsl_cmd --exec bash -c \
        'for tool; do command -v "$tool" >/dev/null || exit 1; done' bash "${tools[@]}" >/dev/null 2>&1; then
        return 0
    fi
    echo "NOTE: WSL distribution '${INTELLIGENCE_VERIFY_WSL_DISTRO:-default}' cannot run ${tools[*]} — running in Git Bash, where the suites are slow. INTELLIGENCE_VERIFY_NATIVE=1 silences this." >&2
    return 1
}

# Runs inside the distribution: unpack the tree from stdin into a private
# directory and verify it there. One output stream, because wsl.exe relays
# stdout and stderr separately and a caller's `> log 2>&1` then overwrites one
# with the other. Interop puts Windows tools on PATH; the gates must find Linux
# ones only.
IFS= read -r -d '' WSL_RUNNER <<'EOF' || true
exec 2>&1
set -u
tree="$(mktemp -d)" || exit 1
trap 'rm -rf "$tree"' EXIT
trap 'exit 130' INT HUP TERM
tar -xf - -C "$tree" || exit 1
PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v '^/mnt/' | paste -sd: -)"
cd "$tree" && VERIFY_DELEGATED=1 bash cli/tests/verify.sh "$1" < /dev/null
EOF

# verify_in_wsl <scope> - the working tree as git sees it: tracked and untracked
# files, minus ignored ones (the package store, scratch fixtures) and deletions
# not yet staged.
verify_in_wsl() {
    local path
    banner "WSL: '$1' on a copy of this tree (INTELLIGENCE_VERIFY_NATIVE=1 keeps Git Bash)"
    git ls-files -z --cached --others --exclude-standard \
        | while IFS= read -r -d '' path; do
            if [ -e "$path" ]; then printf '%s\0' "$path"; fi
        done \
        | tar --null -T - -cf - \
        | wsl_cmd --exec bash -c "$WSL_RUNNER" bash "$1"
}

main() {
    local scope="${1:-auto}" paths="" want_lint=0 want_tests=0

    case "$scope" in
        lint|lint-engine|lint-cli|tests|all) ;;
        auto)
            if ! paths="$(changed_paths)"; then
                echo "git could not report the changed files — refusing to report success." >&2
                return 1
            fi
            # Shell sources decide the lint gate; anything the engine renders or
            # the CLI resolves decides the suites.
            if grep -Eq '^(cli|engine)/.*\.sh$|^npm/[^/]+\.sh$|^cli/intelligence$' <<< "$paths"; then
                want_lint=1
            fi
            if grep -Eq '^(cli|engine|packages/sync|examples|npm)/' <<< "$paths"; then
                want_tests=1
            fi
            [ "$want_lint" -eq 1 ] || skipped+=("lint — no shell source changed")
            [ "$want_tests" -eq 1 ] || skipped+=("tests — no cli/, engine/, packages/sync/, examples/ or npm/ change")
            case "$want_lint$want_tests" in
                11) scope=all ;;
                10) scope=lint ;;
                01) scope=tests ;;
                *)  scope="" ;;
            esac
            ;;
        *)
            echo "unknown scope '$scope' (use: auto | all | lint | lint-cli | lint-engine | tests)" >&2
            return 2
            ;;
    esac

    if [ -n "$scope" ]; then
        if wsl_ready "$scope"; then
            verify_in_wsl "$scope" || failed=1
        else
            run_scope "$scope"
        fi
    fi

    if [ "${#skipped[@]}" -gt 0 ]; then
        banner "skipped"
        printf '  %s\n' "${skipped[@]}"
    fi

    # A delegated run reports through its exit status; the caller prints the verdict.
    if [ -n "${VERIFY_DELEGATED:-}" ]; then
        return "$failed"
    fi
    if [ "$failed" -ne 0 ]; then
        banner "verify FAILED"
        return 1
    fi
    banner "verify ok"
}

main "$@"
