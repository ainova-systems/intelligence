#!/bin/bash
# Shared plumbing for every CLI command. Each command is its own script (the
# dispatcher execs it, or sources `sync`), so each one sources this file first.
#
# All YAML reading goes through the engine's lib/common.sh — the CLI never
# grows a parallel parser for shapes the engine can already read. The only
# CLI-owned parsing lives in lib/manifest.sh (quoted-key `packages:` /
# `registries:` blocks, which the engine deliberately never reads).

# Engine libraries (readers, is_status, IS_RC_*, engine_version). CLI_DIR /
# IS_ENGINE_DIR come exported from the dispatcher.
source "$IS_ENGINE_DIR/lib/common.sh"
source "$IS_ENGINE_DIR/lib/contract.sh"
source "$IS_ENGINE_DIR/lib/adapter-contract.sh"

die() {
    echo "ERROR: ${CLI_INPUT_CONTEXT:-}$*" >&2
    exit 1
}

# --- Untrusted-input guards ----------------------------------------------
# Manifest, lock and registry indexes arrive with a cloned repo: every value
# they carry is attacker-adjacent. URLs and refs reach git argv (a leading
# `-` would be an option — `--upload-pack=<cmd>` is code execution), names
# become store paths fed to rm -rf. Guard at the choke points, loudly.

# assert_safe_source_url <url> — scheme allowlist (the engine's own list) or
# scp-like user@host:path; never option-shaped, never quote-bearing.
assert_safe_source_url() {
    local url="$1"
    case "$url" in
        ""|-*) die "unsafe source url '$url' — option-shaped or empty" ;;
        *[\"\'\ ]*|*[[:cntrl:]]*) die "unsafe source url '$url' — quotes or whitespace" ;;
        https://*|http://*|ssh://*|git://*|file://*) ;;
        *@*:*) ;;
        *) die "unsafe source url '$url' — allowed: https, http, ssh, git, file, or user@host:path" ;;
    esac
}

# assert_safe_ref <ref-or-empty> — tags/branches/SHAs; never option-shaped.
assert_safe_ref() {
    local ref="$1"
    [ -z "$ref" ] && return 0
    case "$ref" in
        -*) die "unsafe git ref '$ref' — option-shaped" ;;
        *[\"\'\ \\]*|*[[:cntrl:]]*) die "unsafe git ref '$ref'" ;;
    esac
}

# Lexical package-subdirectory validation shared by acquisition and lock
# preflight. Physical containment of acquired content is a separate boundary.
assert_safe_package_path() {
    # Preserve literal Git paths, but also guard Windows separator semantics.
    local normalized="${1//\\//}"
    case "$normalized" in
        *..*|/*|[A-Za-z]:*|*[\"\']*|*[[:cntrl:]]*) die "unsafe path '$1'" ;;
    esac
}

# --- Resolved-pin display ------------------------------------------------
# A `ref:` pin's resolved column holds the ref NAME, which never changes: the
# sha is the only field that says which commit is installed. Every surface
# reporting such a pin prints both, so a branch that stopped moving is visible
# without asking the remote.

short_sha() {
    [ -n "$1" ] || { printf '<none>'; return 0; }
    printf '%s' "${1:0:7}"
}

# pin_label <ref-or-empty> <resolved> <sha>
pin_label() {
    local ref="$1" resolved="$2" sha="$3"
    if [ -n "$ref" ]; then
        printf '%s@%s' "${resolved:-$ref}" "$(short_sha "$sha")"
    else
        printf '%s' "${resolved:-<none>}"
    fi
}

source "$CLI_DIR/lib/manifest.sh"
source "$CLI_DIR/lib/semver.sh"
source "$CLI_DIR/lib/cli-install.sh"
source "$CLI_DIR/lib/registry.sh"
source "$CLI_DIR/lib/lockfile.sh"
source "$CLI_DIR/lib/adapter-lifecycle.sh"
source "$CLI_DIR/lib/gitignore.sh"
source "$CLI_DIR/lib/onboarding.sh"
source "$CLI_DIR/lib/sync-cache.sh"
source "$CLI_DIR/lib/sync-lock.sh"

# The engine-content package: OPTIONAL but auto-selected at init. Package by
# UX (manifest entry, lockfile row, list/search/remove), bundle by mechanics —
# at the version the CLI ships, it materializes from the npm bundle without
# network; only a cross-version acquisition reaches git. The pin is held
# exactly at the bundled engine version and moved by lifecycle alignment.
#
# Its identity is DATA shipped with the distribution (cli/engine-package.yaml),
# never a name compiled into cli code — a fork edits the file.
_EPKG="$CLI_DIR/engine-package.yaml"
_EPKG_FIELDS='name url path default_registry'
SYNC_PKG_NAME="" SYNC_PKG_URL="" SYNC_PKG_PATH="" SYNC_PKG_STORE=""
# Read by commands (init seeds it) — per-file shellcheck cannot see that.
# shellcheck disable=SC2034
DEFAULT_REGISTRY_URL=""

# load_sync_package_identity — read the four fields in one pass. Every command
# loads this file first and gets them at once; `sync` sets CLI_DEFER_SYNC_PKG
# before sourcing and reads them in the same awk pass as the project's manifest
# and lock (project_reads_preload), once it holds the project lock.
# shellcheck disable=SC2034  # DEFAULT_REGISTRY_URL is read by commands, as above
load_sync_package_identity() {
    local key value
    _qmap_read_var tops "$_EPKG" '' "$_EPKG_FIELDS" || true
    while IFS="$LOCK_SEP" read -r key value; do
        case "$key" in
            name) SYNC_PKG_NAME="$value" ;;
            url) SYNC_PKG_URL="$value" ;;
            path) SYNC_PKG_PATH="$value" ;;
            default_registry) DEFAULT_REGISTRY_URL="$value" ;;
        esac
    done <<< "$IS_QMAP_OUT"
    [ -n "$SYNC_PKG_NAME" ] || die "corrupt CLI installation: $_EPKG is missing or has no 'name'"
    SYNC_PKG_STORE=".intelligence/packages/$SYNC_PKG_NAME"
}
[ "${CLI_DEFER_SYNC_PKG:-0}" = 1 ] || load_sync_package_identity

# --- Project detection ---------------------------------------------------
# Sets: IP_MODE (cli|legacy|none), IP_ROOT, IP_UMBRELLA, IP_MODULE_DIR.
# These ARE this lib's public API — every command reads them after calling
# detect_project, which per-file shellcheck cannot see.
# shellcheck disable=SC2034
# The CLI product wins: the nearest ancestor holding intelligence.yaml. Legacy is a git
# repo holding an umbrella (a dir with config.yaml) whose module is identified
# by role — scripts/sync.sh + scripts/VERSION — never by name.
detect_project() {
    IP_MODE="none"; IP_ROOT=""; IP_UMBRELLA=""; IP_MODULE_DIR=""
    # PWD is already the logical `pwd` spelling, and so is each textual parent.
    local dir="$PWD" parent
    while :; do
        if [ -f "$dir/intelligence.yaml" ]; then
            IP_MODE="cli"
            IP_ROOT="$dir"
            return 0
        fi
        parent="${dir%/*}"
        [ -n "$parent" ] || parent="/"
        [ "$dir" = "$parent" ] && break
        dir="$parent"
    done
    local root
    root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$root" ] || return 0
    root="$(cd "$root" && pwd)"
    local cf umbrella mod
    while IFS= read -r cf; do
        [ -n "$cf" ] || continue
        umbrella="$(cd "$(dirname "$cf")" && pwd)"
        for mod in "$umbrella"/*/; do
            [ -d "$mod" ] || continue
            if [ -f "${mod}scripts/sync.sh" ] && [ -f "${mod}scripts/VERSION" ]; then
                IP_MODE="legacy"; IP_ROOT="$root"; IP_UMBRELLA="$umbrella"
                IP_MODULE_DIR="${mod%/}"
                return 0
            fi
        done
    done < <(find "$root" -maxdepth 2 -name 'config.yaml' -not -path '*/.*' 2>/dev/null)
    return 0
}

require_cli_project() {
    detect_project
    case "$IP_MODE" in
        cli) ;;
        legacy) die "this is a legacy Intelligence Sync project — run 'intelligence init' to convert it, or keep using its own flow" ;;
        *) die "no intelligence project found here — run 'intelligence init'" ;;
    esac
}

# --- Manifest basics (engine-readable shapes) ----------------------------

# normalize_source_dir_var <dir> — set IS_SOURCE_DIR to the spelling the
# manifest stores: `.` and empty segments dropped, no trailing slash. A path
# that reduces to nothing named the repository root, which is spelled `.` — so
# the caller judges one shape instead of several.
#
# Rebuilt segment by segment rather than with `${dir//\/.\//\/}`: bash 3.2, which
# is what macOS ships and CI runs, keeps the backslash of an escaped separator in
# the REPLACEMENT and produced `intelligence\/rules`, while bash 5 consumed it.
# shellcheck disable=SC2034
normalize_source_dir_var() {
    local dir="$1" out="" seg rest lead=""
    # A leading slash is meaning, not an empty segment: dropping it would turn
    # an absolute path into a relative one and hide it from the classifier.
    case "$dir" in /*) lead="/" ;; esac
    rest="$dir"
    while [ -n "$rest" ]; do
        seg="${rest%%/*}"
        if [ "$seg" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
        case "$seg" in ""|".") continue ;; esac
        out="${out:+$out/}$seg"
    done
    if [ -n "$lead" ]; then
        IS_SOURCE_DIR="$lead$out"
    else
        IS_SOURCE_DIR="${out:-.}"
    fi
}

normalize_source_dir() {
    normalize_source_dir_var "$1"
    printf '%s' "$IS_SOURCE_DIR"
}

# source_entry_problem <root> <entry> — one line naming why the engine cannot
# render this `sources:` entry, or nothing when the entry is sound. Most cases
# here are invisible at sync time: the engine resolves an entry as
# `$REPO_ROOT/<entry>` and skips whatever is not a directory, so a bad entry is
# a silent omission from a run that still reports ok. `source add` refuses one
# before it is written; `status --check` reports one already in the manifest.
source_entry_problem() {
    local root="$1" entry="$2" seg rest norm
    case "$entry" in
        "") printf 'is empty'; return 0 ;;
        *\\*) printf 'uses backslashes — manifest paths use "/"'; return 0 ;;
        /*|[A-Za-z]:/*)
            printf 'is an absolute path — the engine resolves every entry as $REPO_ROOT/<entry>, so it renders nothing'
            return 0
            ;;
    esac
    # The root is the loud failure rather than the silent one: it IS a
    # directory, so the engine reads every top-level *.md in it — README,
    # CHANGELOG, docs — as an artifact of this section.
    normalize_source_dir_var "$entry"
    norm="$IS_SOURCE_DIR"
    if [ "$norm" = "." ]; then
        printf 'is the repository root — every top-level *.md there would be read as an artifact of this section'
        return 0
    fi
    rest="$norm"
    while [ -n "$rest" ]; do
        seg="${rest%%/*}"
        if [ "$seg" = ".." ]; then
            printf 'leaves the repository — its artifacts render, but with bare names instead of links in AGENTS.md'
            return 0
        fi
        [ "$seg" = "$rest" ] && break
        rest="${rest#*/}"
    done
    # The entry is stored as a double-quoted YAML scalar and read back by a
    # parser that strips quotes and a trailing ` # comment`.
    case "$entry" in
        *[\"\'\#\$\`]*|*:*)
            printf 'holds a character the manifest cannot carry verbatim — allowed: letters, digits, . _ - / @'
            return 0
            ;;
    esac
    # A symlink leaves the repository without a '..' anywhere in the path.
    # repo_rel_dir compares by device+inode, so it answers for the real target.
    if [ -d "$root/$entry" ] && [ -z "$(repo_rel_dir "$root" "$root/$entry")" ]; then
        printf 'resolves outside the repository root'
        return 0
    fi
    return 0
}

manifest_intelligence_dir() {
    manifest_intelligence_dir_var "$1"
    printf '%s' "$IS_CONTENT_DIR"
}

# manifest_intelligence_dir_var <manifest> — the same answer in IS_CONTENT_DIR.
manifest_intelligence_dir_var() {
    get_yaml_field_var "$1" "project" "intelligence_dir"
    IS_CONTENT_DIR="${IS_YAML_FIELD:-intelligence}"
}

default_target_output() {
    case "$1" in
        agents) printf '%s' "AGENTS.md" ;;
        antigravity) printf '%s' ".agents" ;;
        copilot) printf '%s' ".github" ;;
        *) printf '.%s' "$1" ;;
    esac
}

# bundled_engine_version_var sets IS_BUNDLED_ENGINE_VERSION, reading VERSION
# once per process; lifecycle preflight compares against it several times.
bundled_engine_version_var() {
    [ -z "${IS_BUNDLED_ENGINE_VERSION_READ:-}" ] || return 0
    local version=""
    [ -r "$IS_ENGINE_DIR/VERSION" ] || {
        echo "ERROR: cannot read $IS_ENGINE_DIR/VERSION" >&2
        return 1
    }
    IFS= read -r -d '' version < "$IS_ENGINE_DIR/VERSION" || true
    IS_BUNDLED_ENGINE_VERSION="${version//[$' \t\r\n']/}"
    IS_BUNDLED_ENGINE_VERSION_READ=1
}

bundled_engine_version() {
    bundled_engine_version_var
    printf '%s' "$IS_BUNDLED_ENGINE_VERSION"
}

# --- The sync package's manifest/lock plumbing ---------------------------
# sync_pkg_entry <manifest> — write/refresh only the requested exact pin.
# The built-in source lives in engine-package.yaml and resolved source state
# belongs exclusively to intelligence.lock.
sync_pkg_entry() {
    local manifest="$1"
    qmap_set "$manifest" "packages" "$SYNC_PKG_NAME" "version" "$(bundled_engine_version)"
}

# sync_pkg_install <root> — materialize the package into the store and lock
# it (offline at the bundled version — fetch_package's bundle-seed guard).
sync_pkg_install() {
    local root="$1" ver sha
    ver="$(bundled_engine_version)"
    store_record_remove "$root" "$SYNC_PKG_NAME"
    sha="$(fetch_package "$SYNC_PKG_URL" "v$ver" "$SYNC_PKG_PATH" "$root/$SYNC_PKG_STORE")"
    wire_package_sources "$root/intelligence.yaml" "$SYNC_PKG_NAME" "$SYNC_PKG_STORE" "$root"
    lock_upsert "$root/intelligence.lock" "$SYNC_PKG_NAME" "$ver" "$SYNC_PKG_URL" "$SYNC_PKG_PATH" "v$ver" "$sha"
    store_record_set "$root" "$SYNC_PKG_NAME" "$SYNC_PKG_URL" "$SYNC_PKG_PATH" "v$ver" "$sha"
    echo "  engine content installed: $SYNC_PKG_STORE (v$ver)"
}

# --- The engine env contract ---------------------------------------------
# Everything the IS_CLI mode of sync.sh needs, derived from the manifest.
export_engine_env() {
    local root="$1"
    local content_rel
    manifest_intelligence_dir_var "$root/intelligence.yaml"
    content_rel="$IS_CONTENT_DIR"
    export IS_CLI=1
    export CONFIG_FILE="$root/intelligence.yaml"
    export REPO_ROOT="$root"
    export IS_CONTENT_REL="$content_rel"
    export IS_MODULE_REL="$SYNC_PKG_STORE"
    export IS_SYNC_CMD="intelligence sync"
    export IS_MANIFEST_NAME="intelligence.yaml"
    export IS_PROTECTED_DIRS="$content_rel:.intelligence"
}

# --- Project lifecycle preflight -----------------------------------------
# Public commands are intentionally few. They share this state gate so a CLI
# installed at a newer engine version brings the current Intelligence project forward
# before a mutating operation. The npm install itself cannot do that: it runs
# outside any project and does not know which repositories the user owns.

is_ci_environment() {
    case "${CI:-}" in
        1|true|TRUE|True|yes|YES|Yes|on|ON|On) return 0 ;;
        *) return 1 ;;
    esac
}

# Validate a repository-relative project content directory, including every
# existing symlinked path component. Call before writing a new manifest.
assert_safe_content_dir() {
    local root="$1" content_dir="$2" repo_phys probe old_ifs part probe_phys
    local -a parts
    case "$content_dir" in
        ""|/*|.|..|../*|*/../*|*/..|.git|.git/*|.intelligence|.intelligence/*|*\\*|[A-Za-z]:*)
            die "unsafe content directory '$content_dir'"
            ;;
    esac
    repo_phys="$(cd "$root" && pwd -P)"
    probe="$root"
    old_ifs="$IFS"; IFS='/'; read -r -a parts <<< "$content_dir"; IFS="$old_ifs"
    for part in "${parts[@]}"; do
        [ -n "$part" ] || continue
        probe="$probe/$part"
        if [ -e "$probe" ] || [ -L "$probe" ]; then
            probe_phys="$(cd "$probe" 2>/dev/null && pwd -P)" \
                || die "cannot resolve project content path '$content_dir'"
            case "$probe_phys" in
                "$repo_phys"|"$repo_phys"/*) ;;
                *) die "project content directory resolves outside the repository: '$content_dir'" ;;
            esac
        fi
    done
}

# project_stamped_ahead <root> — the manifest is stamped newer than this CLI's
# engine, at any SemVer level. Every caller runs check_version_compat first,
# which has already refused a newer major, so what reaches this predicate is
# the admitted minor/patch gap; the predicate itself does not re-judge the gap.
project_stamped_ahead() {
    local stamp
    read_schema_version_var "$1/intelligence.yaml"
    stamp="$IS_SCHEMA_VERSION"
    bundled_engine_version_var
    [ -n "$stamp" ] && _ver_gt "$stamp" "$IS_BUNDLED_ENGINE_VERSION"
}

project_needs_upgrade() {
    local root="$1" manifest="$1/intelligence.yaml" stamp eng pinned locked name url path rows
    local lname _requested _url _path resolved _sha
    [ -f "$manifest" ] || return 1
    read_schema_version_var "$manifest"
    stamp="$IS_SCHEMA_VERSION"
    bundled_engine_version_var
    eng="$IS_BUNDLED_ENGINE_VERSION"
    [ -z "$stamp" ] && return 0
    # A project stamped ahead belongs to a newer CLI. Aligning it here would
    # restamp the schema and re-pin the engine content DOWNWARD, and the next
    # teammate on the current CLI would move both back: leave it as found.
    project_stamped_ahead "$root" && return 1
    _qmap_read_var top "$manifest" '' sync_version || true
    [ -z "$IS_QMAP_OUT" ] || return 0
    _ver_gt "$eng" "$stamp" && return 0
    [ -d "$root/.intelligence/engine" ] && return 0

    # One manifest pass for every package's fields, not a reader per field.
    _qmap_read_var fieldrows "$manifest" packages '' 'url path version' || true
    rows="$IS_QMAP_OUT"
    while IFS="$LOCK_SEP" read -r name url path pinned; do
        [ -n "$name" ] || continue
        # Early RC manifests mixed requested intent with resolved source
        # details. Source URL/path now live only in the required lockfile.
        [ -n "$url" ] && return 0
        [ -n "$path" ] && return 0
        if [ "$name" = "$SYNC_PKG_NAME" ]; then
            # The first lock row for the name: what qmap_field would decode.
            locked=""
            _qmap_read_var rows "$root/intelligence.lock" packages || true
            while IFS="$LOCK_SEP" read -r lname _requested _url _path resolved _sha; do
                [ "$lname" = "$name" ] || continue
                locked="$resolved"
                break
            done <<< "$IS_QMAP_OUT"
            [ "$pinned" = "$eng" ] || return 0
            if [ -f "$root/intelligence.lock" ]; then
                [ -n "$locked" ] || return 0
                [ "${locked#v}" = "$eng" ] || return 0
            fi
        fi
    done <<< "$rows"
    return 1
}

# A manifest with packages but no lock has no trustworthy resolved state from
# which lifecycle alignment can proceed. Never manufacture a partial lock.
project_has_packages() {
    local root="$1" name found=1
    _qmap_read_var keys "$root/intelligence.yaml" "packages" || true
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        assert_valid_pkg_name "$name"
        found=0
    done <<< "$IS_QMAP_OUT"
    return "$found"
}

# project_preflight <root> — what every project-aware command checks before it
# may align or write: schema compatibility (a newer major refuses with 4), a
# valid lock, and a lock for whatever packages the manifest declares.
project_preflight() {
    local root="$1"
    check_version_compat "$root/intelligence.yaml" || return $?
    validate_project_lock "$root" || return $?
    if project_has_packages "$root" && [ ! -f "$root/intelligence.lock" ]; then
        die "manifest declares packages but intelligence.lock is absent — restore the committed lock before running project lifecycle commands"
    fi
}

ensure_project_current() {
    local root="$1" explicit="${2:-}" manifest="$1/intelligence.yaml" stamp eng
    project_preflight "$root" || return $?
    project_needs_upgrade "$root" || return 0
    read_schema_version_var "$manifest"
    stamp="$IS_SCHEMA_VERSION"
    bundled_engine_version_var
    eng="$IS_BUNDLED_ENGINE_VERSION"
    if is_ci_environment && [ "$explicit" != "--explicit" ]; then
        die "project lifecycle requires alignment (stamp ${stamp:-unstamped}, engine $eng) — run 'intelligence init --apply' locally, review and commit the diff"
    fi
    echo "  project alignment: stamp ${stamp:-unstamped}, engine $eng"
    bash "$CLI_DIR/internal/align-project.sh" --no-sync || return $?
    project_reads_refresh "$root"
}

# A present lock is validated even when there is no missing store to restore.
# Keep this before alignment: repairing the sync pin must not rewrite bad input.
validate_project_lock() {
    local lock="$1/intelligence.lock" output line rc=0
    if [ -e "$lock" ] || [ -L "$lock" ]; then
        # The capture is the subshell that contains the guards' `die`.
        output="$(lock_validate_checks "$lock" "${2---metadata}" "$1/intelligence.yaml" 2>&1)" || rc=$?
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            case "$line" in
                WARNING:*)
                    case "${IS_LOCK_WARNINGS:-}" in *"$line"*) continue ;; esac
                    # Suppress only duplicate messages across lifecycle children;
                    # the lock itself is always parsed and validated again.
                    export IS_LOCK_WARNINGS="${IS_LOCK_WARNINGS:-}$line"$'\n'
                    ;;
            esac
            echo "$line" >&2
        done <<< "$output"
        if [ "$rc" -ne 0 ]; then
            echo "ERROR: invalid intelligence.lock — recovery: https://github.com/ainova-systems/intelligence/blob/main/docs/cli.md#recovering-a-lock" >&2
            return 1
        fi
    fi
}

# --- Reads shared by one command's preflight -----------------------------
# A sync reads the CLI's package descriptor, the manifest and the lock several
# times on its way to the engine. Once it holds the project lock it answers all
# of those reads with one qmap pass and one pass of the engine's manifest
# readers; a child that may rewrite either document (alignment, restore) is
# followed by project_reads_refresh. Without a preload every reader takes its
# ordinary path.
IS_PROJECT_READS_ROOT=""

project_reads_preload() {
    local root="$1" manifest="$1/intelligence.yaml" lock="$1/intelligence.lock" s=$'\037'
    local qmap=0 view=0 out qmap_pid="" view_pid=""
    local -a view_args=("$manifest" project intelligence_dir rules agents skills)
    project_reads_reset
    qmap_preload_plan \
        "tops$s$_EPKG$s$s$_EPKG_FIELDS$s$s" \
        "keys$s$manifest${s}packages$s$s$s" \
        "fieldrows$s$manifest${s}packages$s${s}url path version$s" \
        "top$s$manifest$s${s}sync_version$s$s" \
        "lock$s$lock${s}packages$s$s$s$LOCKFILE_VERSION" \
        "rows$s$lock${s}packages$s$s$s" && qmap=1
    [ ! -f "$manifest" ] || [ ! -r "$manifest" ] || view=1
    if project_lock_scratch "$root"; then
        # Both passes at once: starting their processes is most of their cost.
        if [ "$qmap" = 1 ]; then
            qmap_preload_run > "$IS_LOCK_SCRATCH.qmap" &
            qmap_pid=$!
        fi
        if [ "$view" = 1 ]; then
            manifest_view_run "${view_args[@]}" > "$IS_LOCK_SCRATCH.view" &
            view_pid=$!
        fi
        if [ "$qmap" = 1 ] && wait "$qmap_pid"; then
            qmap_preload_store "$(< "$IS_LOCK_SCRATCH.qmap")"
        fi
        if [ "$view" = 1 ]; then
            if wait "$view_pid"; then
                manifest_view_store "$(< "$IS_LOCK_SCRATCH.view")" "${view_args[@]}"
            else
                manifest_view_reset
            fi
        fi
    else
        if [ "$qmap" = 1 ] && out="$(qmap_preload_run)"; then
            qmap_preload_store "$out"
        fi
        [ "$view" = 0 ] || load_manifest_view "${view_args[@]}" || manifest_view_reset
    fi
    IS_PROJECT_READS_ROOT="$root"
}

project_reads_reset() {
    qmap_memo_reset
    manifest_view_reset
    IS_PROJECT_READS_ROOT=""
}

# project_reads_refresh <root> — after a child may have rewritten the manifest
# or the lock: read them again if this process preloaded them.
project_reads_refresh() {
    [ "$IS_PROJECT_READS_ROOT" = "$1" ] || return 0
    project_reads_preload "$1"
}

# _yaml_list_var <file> <section> — read_yaml_list into IS_YAML_LIST: from the
# preloaded manifest view when there is one, otherwise read now and cache
# nothing, because this process may still edit the manifest.
_yaml_list_var() {
    local file_var="IS_YL_${2}_FILE" val_var="IS_YL_${2}_VAL"
    if [ "${!file_var:-}" = "$1" ]; then
        IS_YAML_LIST="${!val_var:-}"
    else
        IS_YAML_LIST="$(read_yaml_list "$1" "$2")"
    fi
}

# Read-only diagnosis must distinguish usable installed metadata from metadata
# which could actually restore a missing store.
check_project_lock() {
    local mode=--metadata
    if project_store_missing "$1"; then mode=--restore; fi
    validate_project_lock "$1" "$mode"
}

# --- What the store holds (decision 0012) ---------------------------------
# The store keeps plain files only, so which commit a package directory holds is
# recorded beside the packages, never inside one (the engine would render it):
# .intelligence/packages/.installed, one row per package — name, url, path,
# resolved, sha, separated like the lock's rows — written whenever a package is
# installed from the lock row it now satisfies. A directory without a row, or
# with one that differs from the lock, is not what the lock pins.
STORE_RECORD=".intelligence/packages/.installed"

# store_record_get <root> <name> — set IS_REC_URL / _PATH / _RESOLVED / _SHA;
# returns 1 when the store records nothing for <name>.
store_record_get() {
    local file="$1/$STORE_RECORD" name url path resolved sha
    IS_REC_URL="" IS_REC_PATH="" IS_REC_RESOLVED="" IS_REC_SHA=""
    [ -f "$file" ] || return 1
    while IFS="$LOCK_SEP" read -r name url path resolved sha; do
        [ "$name" = "$2" ] || continue
        IS_REC_URL="$url" IS_REC_PATH="$path" IS_REC_RESOLVED="$resolved" IS_REC_SHA="$sha"
        return 0
    done < "$file"
    return 1
}

# store_record_matches <root> <name> <url> <path> <resolved> <sha>
store_record_matches() {
    store_record_get "$1" "$2" || return 1
    [ "$IS_REC_URL" = "$3" ] && [ "$IS_REC_PATH" = "$4" ] \
        && [ "$IS_REC_RESOLVED" = "$5" ] && [ "$IS_REC_SHA" = "$6" ]
}

# store_record_set <root> <name> <url> <path> <resolved> <sha> — record what
# <name> now holds; store_record_remove <root> <name> forgets it. Both rewrite
# the file through a temp file, so a reader never sees half a row.
store_record_set() {
    _store_record_write "$@"
}

store_record_remove() {
    _store_record_write "$1" "$2"
}

_store_record_write() {
    local root="$1" target="$2" file="$1/$STORE_RECORD" tmp name rest
    mkdir -p "$root/.intelligence/packages" || die "cannot create $root/.intelligence/packages"
    tmp="$file.tmp.$$"
    {
        if [ -f "$file" ]; then
            while IFS="$LOCK_SEP" read -r name rest; do
                [ -n "$name" ] && [ "$name" != "$target" ] || continue
                printf '%s%s%s\n' "$name" "$LOCK_SEP" "$rest"
            done < "$file"
        fi
        [ "$#" -lt 6 ] || printf '%s%s%s%s%s%s%s%s%s\n' "$target" "$LOCK_SEP" "$3" "$LOCK_SEP" "$4" "$LOCK_SEP" "$5" "$LOCK_SEP" "$6"
    } > "$tmp" || { rm -f "$tmp"; die "cannot write $file"; }
    mv -f "$tmp" "$file" || { rm -f "$tmp"; die "cannot write $file"; }
}

# project_store_missing <root> — a package the manifest or lock names is absent
# from the store, or holds something other than its lock row pins.
project_store_missing() {
    local root="$1" manifest="$1/intelligence.yaml" name src section
    _qmap_read_var keys "$manifest" "packages" || true
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        assert_valid_pkg_name "$name"
        [ -d "$root/.intelligence/packages/$name" ] || return 0
    done <<< "$IS_QMAP_OUT"
    for section in rules agents skills; do
        _yaml_list_var "$manifest" "$section"
        while IFS= read -r src; do
            case "$src" in
                .intelligence/packages/*)
                    [ -d "$root/$src" ] || return 0
                    ;;
            esac
        done <<< "$IS_YAML_LIST"
    done
    # Present is not enough: a `git pull` moves the lock and leaves the ignored
    # store on the commit it held before.
    local rows _requested url path resolved sha
    [ -f "$root/intelligence.lock" ] || return 1
    _qmap_read_var rows "$root/intelligence.lock" packages || true
    rows="$IS_QMAP_OUT"
    while IFS="$LOCK_SEP" read -r name _requested url path resolved sha; do
        [ -n "$name" ] || continue
        assert_valid_pkg_name "$name"
        [ -d "$root/.intelligence/packages/$name" ] || return 0
        store_record_matches "$root" "$name" "$url" "$path" "$resolved" "$sha" || return 0
    done <<< "$rows"
    return 1
}

restore_project_store_if_missing() {
    local root="$1"
    project_store_missing "$root" || return 0
    [ -f "$root/intelligence.lock" ] || die "package store is missing and intelligence.lock is absent — run 'intelligence init'"
    echo "  restoring package store from intelligence.lock"
    bash "$CLI_DIR/internal/restore.sh" --frozen --no-sync || return $?
    project_reads_refresh "$root"
}
