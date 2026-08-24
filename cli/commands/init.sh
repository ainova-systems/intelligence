#!/bin/bash
# intelligence init [--targets a,b,c] [--no-sync]
#
# Set up a project: root manifest, content skeleton, .gitignore, staged
# engine content, first sync. Targets are detected from IDE markers unless
# named explicitly; `agents` and `claude` are always on (AGENTS.md is the
# canonical carrier of always-on rules, Claude Code does not read it).
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

targets_arg="" no_sync=0 content_dir="intelligence" bare=0
while [ $# -gt 0 ]; do
    case "$1" in
        --targets) shift; targets_arg="${1:-}" ;;
        --dir) shift; content_dir="${1:-}" ;;
        --no-sync) no_sync=1 ;;
        --bare) bare=1 ;;
        *) die "unknown option '$1'" ;;
    esac
    shift || true
done
[ -n "$content_dir" ] || die "--dir needs a directory name"
case "$content_dir" in
    /*|*..*|.intelligence|.intelligence/*) die "--dir must be a plain directory inside the repo, and not the package store" ;;
esac

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
    echo "# Managed by the intelligence CLI. Reference: https://github.com/ainova-systems/intelligence-sync"
    echo "project:"
    echo "  name: \"$(basename "$root")\""
    [ "$content_dir" = "intelligence" ] || echo "  intelligence_dir: \"$content_dir\""
    echo ""
    echo "# Schema version of this manifest. The CLI keeps it in step with its engine."
    echo "sync_version: \"$(bundled_engine_version)\""
    echo ""
    echo "# Where content comes from. Nothing here has to exist: a directory that is"
    echo "# absent is skipped, so a project consuming only packages authors nothing of"
    echo "# its own. To write your own, create the directory and sync — no config edit:"
    echo "#   $content_dir/rules/context.md      an always-on rule; describe the project,"
    echo "#                                      its stack, and the constraints to respect"
    echo "#   $content_dir/agents/<name>.md      a persona (frontmatter: name, description,"
    echo "#                                      tier: heavy|standard|light, access: full|readonly)"
    echo "#   $content_dir/skills/<name>/SKILL.md  a procedure invoked as /<name>"
    echo "# '.intelligence/' is CLI-managed (packages + engine content) — never edit it."
    echo "sources:"
    echo "  rules:"
    echo "    - \"$content_dir/rules\""
    echo "  agents:"
    echo "    - \"$content_dir/agents\""
    echo "  skills:"
    echo "    - \"$content_dir/skills\""
    echo ""
    echo "# Generated output, one entry per tool. Add or drop tools freely."
    echo "targets:"
    for t in $targets; do
        case "$t" in
            agents) echo "  agents: { enabled: true, output: \"AGENTS.md\" }" ;;
            *) echo "  $t: { enabled: true, output: \".$t\" }" ;;
        esac
    done
    echo ""
    echo "# Packages are managed with 'intelligence add' / 'search' / 'list':"
    echo "#   intelligence add @ainova-systems/core       from the registry"
    echo "#   intelligence add github:org/repo            any repo with rules|agents|skills"
    echo "# packages:"
    echo "#   \"@ainova-systems/core\":"
    echo "#     version: \"^0.3.0\""
    echo ""
    echo "# Registries are a TRUST LIST: git repos holding an index.yaml, consulted"
    echo "# in order — the first to declare a name wins, then the CLI's bundled index,"
    echo "# then the @org/name -> github.com/org/name convention. Adding one is a"
    echo "# committed, reviewable act of trust in the names it declares; sources are"
    echo "# pinned by url+sha in intelligence.lock, and overriding a bundled name"
    echo "# warns loudly. Managed with 'intelligence registry add|remove'."
    echo "# registries:"
    echo "#   - \"https://github.com/acme/intelligence-registry.git\""
} > "$manifest"

# The package store is restorable state, never committed — the npm model.
if [ ! -f "$root/.gitignore" ] || ! grep -q '^\.intelligence/' "$root/.gitignore"; then
    {
        [ -f "$root/.gitignore" ] && [ -n "$(tail -c 1 "$root/.gitignore" 2>/dev/null)" ] && echo ""
        echo "# intelligence CLI package store (restored by 'intelligence install')"
        echo ".intelligence/"
    } >> "$root/.gitignore"
fi

# The engine's own content (meta-skills, authoring rule, engine agents) is an
# ordinary package: auto-selected, opted out with --bare, removable later with
# 'intelligence remove @ainova-systems/sync --force'.
if [ "$bare" -eq 0 ]; then
    sync_pkg_entry "$manifest"
    sync_pkg_install "$root"
fi

echo "initialized: intelligence.yaml (targets:$(printf ' %s' $targets))"
[ "$bare" -eq 1 ] && echo "  bare setup: no packages — engine meta-skills not installed"
echo "  add packages:  intelligence add @ainova-systems/core   (browse: intelligence search)"
echo "  write your own: create $content_dir/rules/context.md, then intelligence sync"
echo "  docs: https://github.com/ainova-systems/intelligence-sync#readme"

if [ "$no_sync" -eq 0 ]; then
    cd "$root"
    exec bash "$CLI_DIR/commands/sync.sh"
fi
