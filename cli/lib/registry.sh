#!/bin/bash
# Name -> source resolution and package fetching.
#
# Resolution order (first registry to DECLARE the name wins):
#   1. project `registries:` — a trust LIST of registry repos (git repos
#      holding index.yaml), consulted in manifest order; adding one is an
#      explicit, committed act of trust in the names it declares
#   2. the bundled default index (registry/index.yaml next to the CLI)
#   3. convention: @org/name -> https://github.com/org/name.git, content at
#      the repo root — the zero-infrastructure default
#
# The NAME is the trust anchor a developer reasons with; source integrity is
# a separate mechanism: the lock pins url+sha, a project-registry hit that
# shadows a bundled name with a different url warns loudly, and doctor flags
# resolution/lock url drift.
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

    local reg_url index bundled burl
    bundled="$(default_index_file)"
    if [ -n "$manifest" ] && [ -f "$manifest" ]; then
        while IFS= read -r reg_url; do
            [ -n "$reg_url" ] || continue
            index="$(_fetch_index "${reg_url#git+}")"
            if [ -z "$index" ]; then
                echo "  WARN: registry unreachable or missing index.yaml, skipped: $reg_url" >&2
                continue
            fi
            RES_URL="$(qmap_field "$index" "packages" "$name" "url")"
            if [ -n "$RES_URL" ]; then
                RES_PATH="$(qmap_field "$index" "packages" "$name" "path")"
                RES_VIA="registry:$reg_url"
                # Shadowing a bundled name with a DIFFERENT source is legal
                # (that is what overriding means) but never silent.
                if [ -n "$bundled" ]; then
                    burl="$(qmap_field "$bundled" "packages" "$name" "url")"
                    if [ -n "$burl" ] && [ "$burl" != "$RES_URL" ]; then
                        echo "  WARN: $name from this registry overrides the bundled source ($burl)" >&2
                    fi
                fi
                return 0
            fi
        done < <(registries_list "$manifest")
    fi

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

# suggest_similar <manifest-or-empty> <@scope/name> — "Did you mean" lines to
# stderr, matched on the short name (singular/plural tolerant) across every
# project registry and the bundled index.
suggest_similar() {
    local manifest="$1" name="$2"
    local want cand cshort reg_url index seen=" "
    want="${name#*/}"; want="${want%s}"
    _suggest_from() {
        local idx="$1"
        [ -n "$idx" ] && [ -f "$idx" ] || return 0
        while IFS= read -r cand; do
            [ -n "$cand" ] || continue
            case "$seen" in *" $cand "*) continue ;; esac
            cshort="${cand#*/}"; cshort="${cshort%s}"
            if [ "$cshort" = "$want" ] && [ "$cand" != "$name" ]; then
                seen="$seen$cand "
                echo "  Did you mean: intelligence add $cand" >&2
            fi
        done < <(qmap_keys "$idx" "packages")
    }
    if [ -n "$manifest" ] && [ -f "$manifest" ]; then
        while IFS= read -r reg_url; do
            [ -n "$reg_url" ] || continue
            index="$(_fetch_index "${reg_url#git+}")"
            _suggest_from "$index"
        done < <(registries_list "$manifest")
    fi
    _suggest_from "$(default_index_file)"
}

# fetch_package <url> <ref> <subpath> <dest-dir>
# Shallow-clones url@ref (tag, branch, or SHA fallback), copies <subpath>
# (or the repo root) into <dest-dir>, prints the resolved commit sha.
# The clone pins autocrlf/eol/symlinks exactly like the engine does, so the
# store holds the bytes the package published.
fetch_package() {
    local url="$1" ref="$2" subpath="$3" dest="$4"
    # Bundle seed: the engine-content package at the CLI's own version copies
    # from the npm bundle — no network, which keeps init / fresh-clone install
    # / migrate offline exactly like the staging they replace. Keyed on the
    # full (url, path, ref) triple; any other version or source falls through
    # to the normal clone.
    if [ "$url" = "$SYNC_PKG_URL" ] && [ "$subpath" = "$SYNC_PKG_PATH" ] \
        && [ "${ref#v}" = "$(bundled_engine_version)" ]; then
        rm -rf "$dest"
        mkdir -p "$dest"
        cp -R "$IS_ENGINE_DIR/." "$dest/"
        rm -rf "$dest/.git"
        if [ -f "$IS_ENGINE_DIR/scripts/ENGINE_SHA" ]; then
            tr -d ' \t\r\n' < "$IS_ENGINE_DIR/scripts/ENGINE_SHA"
        fi
        return 0
    fi
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
# package has becomes a sources entry — inserted FIRST in its section, so
# project-owned entries come later and win on same-named artifacts.
wire_package_sources() {
    local manifest="$1" name="$2" rel="$3" root="$4"
    local section
    for section in rules agents skills; do
        if [ -d "$root/$rel/$section" ]; then
            sources_add_entry_first "$manifest" "$section" "$rel/$section"
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
