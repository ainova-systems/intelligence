#!/bin/bash
# intelligence add <spec> [--name @scope/name] [--no-sync]
#
# Specs:
#   @scope/name[@range]            resolved via registries / index / convention
#   github:org/repo[#path]         direct from GitHub, no registry involved
#   git+<url>[@ref][#path]         direct from any git host
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

spec="${1:-}"
[ -n "$spec" ] || die "usage: intelligence add <@scope/name[@range] | github:org/repo[#path] | git+<url>[@ref][#path]>"
shift || true

no_sync=0
name_override=""
while [ $# -gt 0 ]; do
    case "$1" in
        --no-sync) no_sync=1 ;;
        --name) shift; name_override="${1:-}" ;;
        *) die "unknown option '$1'" ;;
    esac
    shift || true
done

require_v2
manifest="$IP_ROOT/intelligence.yaml"
lock="$IP_ROOT/intelligence.lock"

name="" range="" url="" path="" ref="" mode=""
case "$spec" in
    github:*)
        mode="direct"
        rest="${spec#github:}"
        case "$rest" in *#*) path="${rest#*#}"; rest="${rest%%#*}" ;; esac
        org="${rest%%/*}"; repo="${rest#*/}"
        { [ -n "$org" ] && [ -n "$repo" ] && [ "$repo" != "$rest" ]; } || die "bad spec '$spec' — expected github:org/repo[#path]"
        name="@$org/$repo"
        url="https://github.com/$org/$repo.git"
        ;;
    git+*)
        mode="direct"
        rest="${spec#git+}"
        case "$rest" in *#*) path="${rest#*#}"; rest="${rest%%#*}" ;; esac
        # ref = the part after the last `@` in the post-scheme URL, unless it
        # contains `/` (then it is a user@host, not a ref) — the engine's own
        # git+ grammar.
        base="${rest#*://}"
        case "$base" in
            *@*)
                tail="${base##*@}"
                case "$tail" in
                    */*) ;;
                    *) ref="$tail"; rest="${rest%@"$tail"}" ;;
                esac
                ;;
        esac
        url="$rest"
        repo="$(basename "${url%.git}")"
        org="$(basename "$(dirname "${url%.git}")")"
        name="@${org:-direct}/$repo"
        ;;
    @*)
        mode="registry"
        body="${spec#@}"
        case "$body" in
            *@*) range="${body##*@}"; body="${body%@"$range"}" ;;
        esac
        name="@$body"
        ;;
    *)
        die "unrecognized spec '$spec' — expected @scope/name, github:…, or git+…"
        ;;
esac
[ -n "$name_override" ] && name="$name_override"
assert_valid_pkg_name "$name"

if [ "$mode" = "registry" ]; then
    resolve_package_source "$manifest" "$name"
    url="$RES_URL"; path="$RES_PATH"
    echo "  resolving $name via $RES_VIA -> $url${path:+ ($path)}"
fi

# The source must exist before anything else is attempted — a name that fell
# through to the convention is often just a typo, and that must say so, not
# die mid-pipeline with no message.
if ! GIT_TERMINAL_PROMPT=0 git ls-remote "$url" >/dev/null 2>&1; then
    echo "ERROR: no reachable repository at $url" >&2
    if [ "${RES_VIA:-}" = "convention" ]; then
        echo "  No registry declares '$name', so it resolved by convention to github.com/${name#@}." >&2
        echo "  Either the name is misspelled ('intelligence search' lists what registries offer)," >&2
        echo "  the repo is private (check your git credentials), or its registry is not added yet:" >&2
        echo "    intelligence registry add <registry-repo-url>" >&2
        suggest_similar "$manifest" "$name"
    else
        echo "  Declared by ${RES_VIA:-the manifest} — check the URL and your git access." >&2
    fi
    exit 1
fi

# Pick the version: an explicit ref pins; otherwise the highest stable tag
# matching the range (npm's behaviour, `^highest` becoming the requested range
# when none was given).
resolved_tag="" requested="$range"
if [ -z "$ref" ]; then
    picked="$(list_remote_versions "$url" | semver_pick_highest "$range")"
    if [ -n "$picked" ]; then
        read -r resolved_tag _ <<< "$(remote_tag_for_version "$url" "$picked")"
        [ -n "$requested" ] || requested="^$picked"
    else
        if [ -n "$range" ]; then
            die "no tag of $url satisfies '$range' (stable x.y.z tags only)"
        fi
        if [ "$mode" = "registry" ]; then
            die "'$name' has no stable version tags at $url — a registry package must be versioned; use github:/git+ with @<ref> to pin a branch or commit"
        fi
        echo "  NOTE: no version tags at $url — pinning the default branch head" >&2
    fi
fi

rel=".intelligence/packages/$name"
sha="$(fetch_package "$url" "${ref:-$resolved_tag}" "$path" "$IP_ROOT/$rel")"

wire_package_sources "$manifest" "$name" "$rel" "$IP_ROOT"

# Manifest entry: a registry package records its range; a direct one records
# its source so resolution never has to guess it again.
if [ "$mode" = "registry" ]; then
    qmap_set "$manifest" "packages" "$name" "version" "$requested"
else
    qmap_set "$manifest" "packages" "$name" "url" "$url"
    [ -n "$path" ] && qmap_set "$manifest" "packages" "$name" "path" "$path"
    if [ -n "$ref" ]; then
        qmap_set "$manifest" "packages" "$name" "ref" "$ref"
    elif [ -n "$requested" ]; then
        qmap_set "$manifest" "packages" "$name" "version" "$requested"
    fi
fi

lock_upsert "$lock" "$name" "$requested" "$url" "$path" "${ref:-$resolved_tag}" "$sha"

sections=""
for s in rules agents skills; do
    [ -d "$IP_ROOT/$rel/$s" ] && sections="$sections $s"
done
echo "+ $name@${resolved_tag:-${ref:-HEAD}} (${sections# })"

if [ "$no_sync" -eq 0 ]; then
    exec bash "$CLI_DIR/commands/sync.sh"
fi
