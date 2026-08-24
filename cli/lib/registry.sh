#!/bin/bash
# Name -> source resolution and package fetching.
#
# Resolution order (first hit wins):
#   1. project `registries:` — a scope bound to a registry repo (a git repo
#      holding index.yaml); private orgs override anything shipped
#   2. the bundled default index (registry/index.yaml next to the CLI)
#   3. convention: @org/name -> https://github.com/org/name.git, content at
#      the repo root — the zero-infrastructure default
#
# An index is itself fetched with git (never curl): auth, proxies and private
# hosting all come for free, and the CLI keeps the engine's bash+awk+git-only
# dependency footprint.

default_index_file() {
    local f="$CLI_DIR/../registry/index.yaml"
    [ -f "$f" ] && printf '%s' "$f"
    return 0
}

# _fetch_index <registry-repo-url> — clones the registry repo (shallow) and
# prints the path of its index.yaml; empty on failure. Cached per run+url.
_fetch_index() {
    local url="$1" cache key tmp
    cache="${TMPDIR:-/tmp}/intelligence-cli-index-$$"
    key="$(printf '%s' "$url" | cksum | awk '{print $1}')"
    if [ -f "$cache/$key/index.yaml" ]; then
        printf '%s' "$cache/$key/index.yaml"
        return 0
    fi
    mkdir -p "$cache"
    tmp="$cache/$key"
    if GIT_TERMINAL_PROMPT=0 git -c core.autocrlf=false clone --depth 1 --quiet "$url" "$tmp" 2>/dev/null \
        && [ -f "$tmp/index.yaml" ]; then
        printf '%s' "$tmp/index.yaml"
    fi
    return 0
}

# resolve_package_source <manifest-or-empty> <@scope/name>
# Sets RES_URL, RES_PATH (may be empty = repo root), RES_VIA — the caller's
# result contract, invisible to per-file shellcheck.
# shellcheck disable=SC2034
resolve_package_source() {
    local manifest="$1" name="$2"
    local scope="${name%%/*}" short="${name#*/}"
    RES_URL=""; RES_PATH=""; RES_VIA=""

    if [ -n "$manifest" ] && [ -f "$manifest" ]; then
        local reg_url index
        reg_url="$(qmap_value "$manifest" "registries" "$scope")"
        if [ -n "$reg_url" ]; then
            index="$(_fetch_index "${reg_url#git+}")"
            [ -n "$index" ] || die "registry for scope '$scope' is unreachable or has no index.yaml: $reg_url"
            RES_URL="$(qmap_field "$index" "packages" "$name" "url")"
            RES_PATH="$(qmap_field "$index" "packages" "$name" "path")"
            [ -n "$RES_URL" ] || die "package '$name' not found in the '$scope' registry ($reg_url)"
            RES_VIA="registry:$reg_url"
            return 0
        fi
    fi

    local bundled
    bundled="$(default_index_file)"
    if [ -n "$bundled" ]; then
        RES_URL="$(qmap_field "$bundled" "packages" "$name" "url")"
        if [ -n "$RES_URL" ]; then
            RES_PATH="$(qmap_field "$bundled" "packages" "$name" "path")"
            RES_VIA="index"
            return 0
        fi
    fi

    RES_URL="https://github.com/${scope#@}/$short.git"
    RES_PATH=""
    RES_VIA="convention"
    return 0
}

# fetch_package <url> <ref> <subpath> <dest-dir>
# Shallow-clones url@ref (tag, branch, or SHA fallback), copies <subpath>
# (or the repo root) into <dest-dir>, prints the resolved commit sha.
# The clone pins autocrlf/eol/symlinks exactly like the engine does, so the
# store holds the bytes the package published.
fetch_package() {
    local url="$1" ref="$2" subpath="$3" dest="$4"
    local tmp sha src
    local -a branch_arg=()
    [ -n "$ref" ] && branch_arg=(--branch "$ref")
    tmp="$(mktemp -d -t intelligence-pkg-XXXXXX 2>/dev/null || mktemp -d)"
    if ! GIT_TERMINAL_PROMPT=0 git -c core.symlinks=false -c core.autocrlf=false -c core.eol=lf \
            clone --depth 1 "${branch_arg[@]+"${branch_arg[@]}"}" --quiet "$url" "$tmp/clone" 2>/dev/null; then
        # A SHA is not clonable with --branch — fall back to a full clone + checkout.
        rm -rf "$tmp/clone"
        GIT_TERMINAL_PROMPT=0 git -c core.symlinks=false -c core.autocrlf=false -c core.eol=lf \
            clone --quiet "$url" "$tmp/clone" 2>/dev/null \
            || { rm -rf "$tmp"; die "cannot clone $url"; }
        [ -z "$ref" ] || git -C "$tmp/clone" checkout --quiet "$ref" \
            || { rm -rf "$tmp"; die "ref '$ref' not found in $url"; }
    fi
    sha="$(git -C "$tmp/clone" rev-parse HEAD)"
    src="$tmp/clone"
    if [ -n "$subpath" ]; then
        case "$subpath" in
            *..*) rm -rf "$tmp"; die "unsafe path '$subpath'" ;;
        esac
        src="$tmp/clone/$subpath"
        [ -d "$src" ] || { rm -rf "$tmp"; die "path '$subpath' not found in $url${ref:+@$ref}" ; }
    fi
    rm -rf "$dest"
    mkdir -p "$dest"
    cp -R "$src/." "$dest/"
    # A nested repository would land as an untracked .git — the store must
    # hold plain files only.
    rm -rf "$dest/.git"
    rm -rf "$tmp"
    printf '%s' "$sha"
}

# wire_package_sources <manifest> <@scope/name> <store-rel-dir>
# The provides convention: whichever of rules/agents/skills the installed
# package has becomes a sources entry. Reuses the engine's idempotent,
# comment-preserving _mig_add_source.
wire_package_sources() {
    local manifest="$1" name="$2" rel="$3" root="$4"
    local section
    for section in rules agents skills; do
        if [ -d "$root/$rel/$section" ]; then
            _mig_add_source "$manifest" "$section" "$rel/$section"
        fi
    done
}

# unwire_package_sources <manifest> <store-rel-dir>
unwire_package_sources() {
    local manifest="$1" rel="$2"
    local section
    for section in rules agents skills; do
        sources_remove_entry "$manifest" "$section" "$rel/$section"
    done
}
