#!/bin/bash
# Name -> source resolution and package fetching.
#
# A name resolves ONLY through the manifest's `registries:` trust list (git
# repos holding index.yaml, consulted in order; the first to declare the name
# wins). There is deliberately no built-in catalog and no name->github
# convention: the CLI core knows no vendor, and a name nobody explicitly
# trusted must never silently turn into an install from a guessed URL.
# Sources without a registry are always EXPLICIT: github:org/repo, git+<url>.
# Vendor defaults exist only as lines `init` writes into the manifest —
# visible, reviewable, deletable.
#
# The NAME is the trust anchor a developer reasons with; source integrity is
# a separate mechanism: the lock pins url+sha, and doctor flags
# resolution/lock url drift.
#
# An index is itself fetched with git (never curl): auth, proxies and private
# hosting all come for free, and the CLI keeps the engine's bash+awk+git-only
# dependency footprint.

# _fetch_index <registry-repo-url> — clones the registry repo (shallow) and
# prints the path of its index.yaml; empty on failure. Cached per run+url.
_fetch_index() {
    local url="$1" key tmp
    assert_safe_source_url "$url"
    # Per-run private cache dir under an UNPREDICTABLE mktemp path (a fixed
    # /tmp/...-$$ would be trusted on cache hit and pre-creatable by others).
    # No EXIT trap: _fetch_index is always called inside $( ), so a trap would
    # fire in that subshell and delete the dir before the caller reads it. The
    # dir is small and OS-reaped from the temp root; IS_REMOTE_CACHE-style
    # persistence is exported so repeated calls in one command share it.
    if [ -z "${IS_CLI_INDEX_CACHE:-}" ]; then
        IS_CLI_INDEX_CACHE="$(mktemp -d -t intelligence-cli-index-XXXXXX 2>/dev/null || mktemp -d)"
        export IS_CLI_INDEX_CACHE
    fi
    local cache="$IS_CLI_INDEX_CACHE"
    key="$(printf '%s' "$url" | cksum | awk '{print $1}')"
    if [ -f "$cache/$key/index.yaml" ]; then
        printf '%s' "$cache/$key/index.yaml"
        return 0
    fi
    tmp="$cache/$key"
    if GIT_TERMINAL_PROMPT=0 git -c core.autocrlf=false clone --depth 1 --quiet -- "$url" "$tmp" 2>/dev/null \
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
    RES_URL=""; RES_PATH=""; RES_VIA=""

    local reg_url index
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
                return 0
            fi
        done < <(registries_list "$manifest")
    fi
    # No trusted registry declares the name. Deliberately NOT an invented
    # URL: the caller reports it, with suggestions.
    return 0
}

# suggest_similar <manifest-or-empty> <@scope/name> — "Did you mean" lines to
# stderr, matched on the short name (singular/plural tolerant) across every
# trusted registry.
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
}

# fetch_package <url> <ref> <subpath> <dest-dir>
# Shallow-clones url@ref (tag, branch, or SHA fallback), copies <subpath>
# (or the repo root) into <dest-dir>, prints the resolved commit sha.
# The clone pins autocrlf/eol/symlinks exactly like the engine does, so the
# store holds the bytes the package published.
fetch_package() {
    local url="$1" ref="$2" subpath="$3" dest="$4"
    assert_safe_source_url "$url"
    assert_safe_ref "$ref"
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
            clone --depth 1 "${branch_arg[@]+"${branch_arg[@]}"}" --quiet -- "$url" "$tmp/clone" 2>/dev/null; then
        # A SHA is not clonable with --branch — fall back to a full clone + checkout.
        rm -rf "$tmp/clone"
        GIT_TERMINAL_PROMPT=0 git -c core.symlinks=false -c core.autocrlf=false -c core.eol=lf \
            clone --quiet -- "$url" "$tmp/clone" 2>/dev/null \
            || { rm -rf "$tmp"; die "cannot clone $url"; }
        [ -z "$ref" ] || git -C "$tmp/clone" checkout --quiet "$ref" -- \
            || { rm -rf "$tmp"; die "ref '$ref' not found in $url"; }
    fi
    sha="$(git -C "$tmp/clone" rev-parse HEAD)"
    src="$tmp/clone"
    if [ -n "$subpath" ]; then
        case "$subpath" in
            *..*|/*|*[\"\']*) rm -rf "$tmp"; die "unsafe path '$subpath'" ;;
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
