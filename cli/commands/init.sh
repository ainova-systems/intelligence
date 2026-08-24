#!/bin/bash
# intelligence init [--targets a,b,c] [--no-sync]
#
# Set up a project: root manifest, content skeleton, .gitignore, staged
# engine content, first sync. Targets are detected from IDE markers unless
# named explicitly; `agents` and `claude` are always on (AGENTS.md is the
# canonical carrier of always-on rules, Claude Code does not read it).
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

targets_arg="" no_sync=0
while [ $# -gt 0 ]; do
    case "$1" in
        --targets) shift; targets_arg="${1:-}" ;;
        --no-sync) no_sync=1 ;;
        *) die "unknown option '$1'" ;;
    esac
    shift || true
done

detect_project
case "$IP_MODE" in
    v2) die "already set up — manifest at $IP_ROOT/intelligence.yaml (use 'intelligence status')" ;;
    legacy) die "this is a vendored (v1) setup at $IP_UMBRELLA — run 'intelligence migrate' instead" ;;
esac

root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
root="$(cd "$root" && pwd)"

targets="agents claude"
if [ -n "$targets_arg" ]; then
    targets="agents $(printf '%s' "$targets_arg" | tr ',' ' ')"
else
    [ -d "$root/.cursor" ] && targets="$targets cursor"
    [ -d "$root/.codex" ] && targets="$targets codex"
    [ -d "$root/.pi" ] && targets="$targets pi"
    [ -d "$root/.opencode" ] && targets="$targets opencode"
    [ -d "$root/.github" ] && [ -d "$root/.github/instructions" ] && targets="$targets copilot"
fi

manifest="$root/intelligence.yaml"
{
    echo "# Intelligence manifest — what this project's AI tooling knows and where it goes."
    echo "# Managed by the intelligence CLI (https://github.com/ainova-systems/intelligence-sync)."
    echo "project:"
    echo "  name: \"$(basename "$root")\""
    echo ""
    echo "sync_version: \"$(bundled_engine_version)\""
    echo ""
    echo "sources:"
    echo "  rules:"
    echo "    - \"intelligence/rules\""
    echo "    - \".intelligence/engine/rules\""
    echo "  agents:"
    echo "    - \"intelligence/agents\""
    echo "    - \".intelligence/engine/agents\""
    echo "  skills:"
    echo "    - \"intelligence/skills\""
    echo "    - \".intelligence/engine/skills\""
    echo ""
    echo "targets:"
    for t in $targets; do
        case "$t" in
            agents) echo "  agents: { enabled: true, output: \"AGENTS.md\" }" ;;
            *) echo "  $t: { enabled: true, output: \".$t\" }" ;;
        esac
    done
} > "$manifest"

mkdir -p "$root/intelligence/rules" "$root/intelligence/agents" "$root/intelligence/skills"
if [ ! -f "$root/intelligence/rules/context.md" ]; then
    cat > "$root/intelligence/rules/context.md" <<EOF
# Project Context

<!-- Always-on context every AI tool receives. Describe what this project is,
     its stack, and the constraints an agent must respect. -->
EOF
fi

# The package store is restorable state, never committed — the npm model.
if [ ! -f "$root/.gitignore" ] || ! grep -q '^\.intelligence/' "$root/.gitignore"; then
    {
        [ -f "$root/.gitignore" ] && [ -n "$(tail -c 1 "$root/.gitignore" 2>/dev/null)" ] && echo ""
        echo "# intelligence CLI package store (restored by 'intelligence install')"
        echo ".intelligence/"
    } >> "$root/.gitignore"
fi

ensure_engine_staged "$root"
echo "initialized: intelligence.yaml (targets:$(printf ' %s' $targets))"
echo "next: add intelligence packages — e.g. 'intelligence add @ainova-systems/core'"

if [ "$no_sync" -eq 0 ]; then
    cd "$root"
    exec bash "$CLI_DIR/commands/sync.sh"
fi
