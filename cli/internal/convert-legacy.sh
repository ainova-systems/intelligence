#!/bin/bash
# Internal conversion from legacy Intelligence Sync to Intelligence CLI.
# to the CLI setup: root intelligence.yaml, .intelligence/ store,
# intelligence.lock, no vendored engine.
#
# Transactional: STAGE everything next to the
# project, VERIFY the staged state, then COMMIT in an order where every
# destructive step happens only after a real sync of the new state reported
# IS_STATUS=ok. Any earlier failure leaves the project untouched.
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

dry_run=0 force=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) dry_run=1 ;;
        --force) force=1 ;;
        *) die "unknown option '$1'" ;;
    esac
    shift || true
done

# ---- Preconditions (fail closed, nothing written) -------------------------
detect_project
case "$IP_MODE" in
    legacy) ;;
    cli) die "already an Intelligence project ($IP_ROOT/intelligence.yaml)" ;;
    *) die "no legacy Intelligence Sync project found here — 'intelligence init' starts a fresh project" ;;
esac
root="$IP_ROOT"
umbrella="$IP_UMBRELLA"
module_dir="$IP_MODULE_DIR"
config="$umbrella/config.yaml"
module_rel="${module_dir#"$root"/}"
umbrella_rel="${umbrella#"$root"/}"

for existing in intelligence.yaml intelligence.lock .intelligence; do
    if [ -e "$root/$existing" ] || [ -L "$root/$existing" ]; then
        die "$existing already exists at the root — conflicting Intelligence CLI state; move it aside or restore the project before converting"
    fi
done
if [ "$dry_run" -eq 0 ] && [ "$force" -eq 0 ]; then
    if [ -n "$(git -C "$root" status --porcelain 2>/dev/null)" ]; then
        die "working tree is not clean — commit or stash first (or --force); conversion produces a one-commit diff you can review and revert"
    fi
fi

# `sync_version` belongs to the legacy Intelligence Sync format. Intelligence uses
# `schema_version`, so conversion reads the legacy scalar explicitly.
stamp="$(top_scalar "$config" "sync_version")"
eng="$(bundled_engine_version)"
[ -n "$stamp" ] && _ver_gt "$stamp" "$eng" && die "project schema $stamp is newer than this CLI's engine $eng — update the CLI first"

# The legacy `packs:` block is the one Intelligence Sync shape conversion still reads, and the
# engine no longer knows it — the reader lives here, with its only consumer.
get_pack_field() {
    get_nested_yaml_value "$1" "packs" "$2" "$3"
}

paths_overlap() {
    case "$1" in "$2"|"$2"/*) return 0 ;; esac
    case "$2" in "$1"|"$1"/*) return 0 ;; esac
    return 1
}

validate_mirror_path() {
    local pack="$1" mirror="$2" canon rel src src_canon src_rel target output protected mirror_phys
    [ -n "$mirror" ] || return 0
    case "$mirror" in
        .|/*|*..*|*\\*|[A-Za-z]:*) die "pack '$pack' has unsafe mirror path '$mirror'" ;;
    esac
    canon="$(normalize_path "$root/$mirror")"
    case "$canon" in "$root"/*) ;; *) die "pack '$pack' mirror escapes the repository: '$mirror'" ;; esac
    rel="${canon#"$root"/}"

    # A legacy mirror may live below the content directory (the normal location is
    # intelligence/external/<pack>), but it must never own the directory itself,
    # the vendored module, CLI state, authored sources, or generated outputs.
    case "$umbrella_rel" in "$rel"|"$rel"/*) die "pack '$pack' mirror '$mirror' contains the legacy content directory" ;; esac
    for protected in .git .intelligence "$module_rel"; do
        paths_overlap "$rel" "$protected" && die "pack '$pack' mirror '$mirror' overlaps protected path '$protected'"
    done
    for section in rules agents skills; do
        while IFS= read -r src; do
            case "$src" in ""|git+*|@*) continue ;; esac
            src_canon="$(normalize_path "$root/$src")"
            case "$src_canon" in "$root"/*) src_rel="${src_canon#"$root"/}" ;; *) continue ;; esac
            paths_overlap "$rel" "$src_rel" \
                && die "pack '$pack' mirror '$mirror' overlaps configured source '$src'"
        done < <(read_yaml_list "$config" "$section")
    done
    while IFS= read -r target; do
        [ -n "$target" ] || continue
        output="$(get_target_output "$config" "$target")"
        [ -n "$output" ] || continue
        case "$output" in /*|*..*) continue ;; esac
        paths_overlap "$rel" "${output%/}" \
            && die "pack '$pack' mirror '$mirror' overlaps target '$target' output '$output'"
    done < <(read_yaml_keys "$config" "targets")

    if [ -d "$canon" ]; then
        mirror_phys="$(cd "$canon" && pwd -P)"
        case "$mirror_phys" in "$root"|"$root"/*) ;; *) die "pack '$pack' mirror resolves outside the repository: '$mirror'" ;; esac
        [ -f "$canon/.pack" ] || die "pack '$pack' mirror '$mirror' has no .pack ownership stamp — refusing to copy or delete project-owned content"
    fi
}

# ---- Stage ----------------------------------------------------------------
if [ "$dry_run" -eq 1 ]; then
    stage="$(mktemp -d -t intelligence-migrate-XXXXXX 2>/dev/null || mktemp -d)"
else
    stage="$(mktemp -d "$root/.intelligence-migrate-stage.XXXXXX")"
fi
cleanup_stage() { rm -rf "$stage"; }
trap cleanup_stage EXIT INT TERM
mkdir -p "$stage/.intelligence/packages"

# Intelligence carries no legacy migration chain: the archived Intelligence Sync
# engine knows how to walk an old project forward. Conversion accepts only a
# project already at the final legacy schema and names the exact remedy otherwise —
# a remedy that keeps working indefinitely, because the archive stays at the
# URL the project's own update.sh already clones.
LEGACY_FINAL_SCHEMA="0.10.0"
if [ -z "$stamp" ] || _ver_gt "$LEGACY_FINAL_SCHEMA" "$stamp"; then
    echo "ERROR: project schema is ${stamp:-absent (pre-0.3.1)}, older than the final legacy Intelligence Sync schema $LEGACY_FINAL_SCHEMA." >&2
    echo "       Bring it forward with its own engine first — that still works:" >&2
    echo "         bash $module_rel/scripts/update.sh --yes" >&2
    echo "       then re-run: intelligence init" >&2
    exit 1
fi

echo "== staging =="
# Engine content arrives as the @ainova-systems/sync package, seeded from the
# bundle (fetch_package's guard — no network).
sync_pkg_sha="$(fetch_package "$SYNC_PKG_URL" "v$eng" "$SYNC_PKG_PATH" "$stage/$SYNC_PKG_STORE")"

# Legacy pack name -> Intelligence package name (@org/repo derived from the url), plus
# per-pack source facts. Recorded as rows for the config rewrite and the lock.
pack_rows="$stage/packs.rows"
: > "$pack_rows"
seen_names=" "
seen_mirrors=" "
while IFS= read -r pack; do
    [ -n "$pack" ] || continue
    url="$(get_pack_field "$config" "$pack" "url")"
    ref="$(get_pack_field "$config" "$pack" "ref")"
    mirror="$(get_pack_field "$config" "$pack" "mirror")"
    [ -n "$url" ] || die "pack '$pack' has no url in config.yaml"
    assert_safe_source_url "$url"
    assert_safe_ref "$ref"
    validate_mirror_path "$pack" "$mirror"
    if [ -n "$mirror" ]; then
        mirror_key="$(normalize_path "$root/$mirror")"
        case "$seen_mirrors" in *" $mirror_key "*) die "pack '$pack' shares mirror '$mirror' with another pack" ;; esac
        seen_mirrors="$seen_mirrors$mirror_key "
    fi
    base="${url%.git}"; base="${base%/}"
    repo="$(basename "$base")"
    org="$(basename "$(dirname "$base")")"
    case "$org" in ""|*[!A-Za-z0-9._-]*) org="local" ;; esac
    case "$repo" in ""|*[!A-Za-z0-9._-]*) repo="$(printf '%s' "$repo" | tr -c 'A-Za-z0-9._-' '-')" ;; esac
    name="@$org/$repo"
    assert_valid_pkg_name "$name"
    # Two packs deriving the same @org/repo would overwrite one store dir and
    # duplicate the lock key — fail closed, the user renames a source.
    case "$seen_names" in
        *" $name "*) die "packs '$pack' and another both derive package name '$name' — sources must map to distinct names" ;;
    esac
    seen_names="$seen_names $name "
    printf '%s\n' "$pack$LOCK_SEP$name$LOCK_SEP$url$LOCK_SEP$ref$LOCK_SEP$mirror"
done < <(read_yaml_keys "$config" "packs") >> "$pack_rows"

# Stage the store: mirrored packs are COPIED from their mirrors (content the
# repo already holds — the network is not consulted, and the mirror is not
# touched); transient packs are fetched.
lock_rows="$stage/lock.rows"
: > "$lock_rows"
while IFS="$LOCK_SEP" read -r pack name url ref mirror; do
    [ -n "$pack" ] || continue
    dest="$stage/.intelligence/packages/$name"
    sha=""
    if [ -n "$mirror" ] && [ -d "$root/$mirror" ]; then
        mkdir -p "$dest"
        cp -R "$root/$mirror/." "$dest/"
        if [ -f "$dest/.pack" ]; then
            sha="$(awk -F= '$1 == "sha" {print $2; exit}' "$dest/.pack")"
            rm -f "$dest/.pack"
        fi
        echo "  pack '$pack' -> $name (from mirror $mirror)"
    else
        sha="$(fetch_package "$url" "$ref" "" "$dest")"
        echo "  pack '$pack' -> $name (fetched)"
    fi
    if [ -z "$sha" ] || [ "$sha" = "unknown" ]; then
        sha="$(GIT_TERMINAL_PROMPT=0 git ls-remote -- "$url" "$ref" 2>/dev/null | awk '{print $1; exit}')"
    fi
    [ -n "$ref" ] || ref="HEAD"
    printf '%s\037%s\037%s\037%s\037%s\037%s\n' \
        "$name" "" "$url" "" "$ref" "$sha" >> "$lock_rows"
done < "$pack_rows"

# The manifest: config.yaml transformed line by line — comments and unknown
# blocks survive verbatim; `sync_version` and `packs:` are dropped (restamped
# / converted); sources entries are rewritten onto the store.
manifest_stage="$stage/intelligence.yaml"
rewrite_source_value() {
    local v="$1" pack name rest
    case "$v" in
        "$module_rel"/rules|"$module_rel"/agents|"$module_rel"/skills)
            printf '%s/%s' "$SYNC_PKG_STORE" "${v##*/}"
            return 0 ;;
        @*)
            rest="${v#@}"
            pack="${rest%%/*}"
            while IFS="$LOCK_SEP" read -r p name _ _ _; do
                if [ "$p" = "$pack" ]; then
                    if [ "$rest" = "$pack" ]; then
                        printf '.intelligence/packages/%s' "$name"
                    else
                        printf '.intelligence/packages/%s/%s' "$name" "${rest#*/}"
                    fi
                    return 0
                fi
            done < "$pack_rows"
            ;;
    esac
    printf '%s' "$v"
}
in_packs=0 in_sources=0
while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
        sync_version:*) continue ;;
        packs:*) in_packs=1; continue ;;
        sources:*) in_sources=1; in_packs=0; echo "$line"; continue ;;
        [!\ \#]*) in_packs=0; in_sources=0 ;;
    esac
    [ "$in_packs" -eq 1 ] && continue
    if [ "$in_sources" -eq 1 ]; then
        case "$line" in
            *"- "*)
                indent="${line%%-*}"
                v="${line#*- }"
                # A trailing inline comment survives the rewrite — split it
                # off before touching quotes, or it would be mangled into the
                # value.
                trail=""
                case "$v" in
                    *[[:space:]]"#"*)
                        trail=" #${v#*[[:space:]]#}"
                        v="${v%%[[:space:]]#*}"
                        ;;
                esac
                v="${v%"${v##*[![:space:]]}"}"
                v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
                echo "$indent- \"$(rewrite_source_value "$v")\"$trail"
                continue
                ;;
        esac
    fi
    echo "$line"
done < "$config" > "$manifest_stage"
stamp_schema_version "$manifest_stage" "$eng"

# packages: requested pins only; resolved source details live in the lock.
while IFS="$LOCK_SEP" read -r pack name url ref mirror; do
    [ -n "$pack" ] || continue
    qmap_set "$manifest_stage" "packages" "$name" "ref" "${ref:-HEAD}"
done < "$pack_rows"

# The engine's own content rides along as a package, pinned to the engine.
qmap_set "$manifest_stage" "packages" "$SYNC_PKG_NAME" "version" "$eng"
printf '%s\037%s\037%s\037%s\037%s\037%s\n' \
    "$SYNC_PKG_NAME" "$eng" "$SYNC_PKG_URL" "$SYNC_PKG_PATH" "v$eng" "$sync_pkg_sha" >> "$lock_rows"

# ---- Verify ---------------------------------------------------------------
echo "== verifying staged state =="
fail=0
for section in rules agents skills; do
    while IFS= read -r src; do
        [ -n "$src" ] || continue
        case "$src" in
            .intelligence/*) [ -d "$stage/$src" ] || { echo "  MISSING (staged): $src"; fail=1; } ;;
            git+*|@*) echo "  UNCONVERTED source token: $src"; fail=1 ;;
            *) [ -d "$root/$src" ] || echo "  NOTE: local source '$src' does not exist (kept — same as before)" ;;
        esac
    done < <(read_yaml_list "$manifest_stage" "$section")
done
target_keys() {
    awk '
        /^targets:[[:space:]]*$/ { in_targets=1; next }
        in_targets && /^[^[:space:]#]/ { exit }
        in_targets && /^  [A-Za-z_][A-Za-z0-9_]*:/ {
            line=$0; sub(/^  /, "", line); sub(/:.*/, "", line); print line
        }
    ' "$1"
}
while IFS= read -r adapter; do
    [ -n "$adapter" ] || continue
    old_e="$(is_target_enabled "$config" "$adapter")"
    new_e="$(is_target_enabled "$manifest_stage" "$adapter")"
    [ "$old_e" = "$new_e" ] || { echo "  TARGET DRIFT: $adapter enabled '$old_e' -> '$new_e'"; fail=1; }
    old_o="$(get_target_output "$config" "$adapter")"
    new_o="$(get_target_output "$manifest_stage" "$adapter")"
    [ "$old_o" = "$new_o" ] || { echo "  TARGET DRIFT: $adapter output '$old_o' -> '$new_o'"; fail=1; }
done < <({ target_keys "$config"; target_keys "$manifest_stage"; } | sort -u)
[ "$fail" -eq 0 ] || die "staged state failed verification — nothing changed"

if [ "$dry_run" -eq 1 ]; then
    echo ""
    echo "== dry run — the project is untouched. Staged manifest: =="
    cat "$manifest_stage"
    echo ""
    echo "Would: write intelligence.yaml + intelligence.lock, move the store in,"
    echo "sync, then remove $module_rel/, config.yaml and the pack mirrors."
    exit 0
fi

# ---- Commit ---------------------------------------------------------------
echo "== committing =="
# .gitignore is part of the transaction: rollback must leave it exactly as
# found, absent included.
gitignore_existed=0
if [ -f "$root/.gitignore" ]; then
    gitignore_existed=1
    cp "$root/.gitignore" "$stage/gitignore.orig"
fi
commit_active=1
rollback() {
    [ "$commit_active" -eq 1 ] || return 0
    commit_active=0
    set +e
    rm -rf "$root/.intelligence" "$root/intelligence.yaml" "$root/intelligence.lock"
    if [ "$gitignore_existed" -eq 1 ]; then
        cp "$stage/gitignore.orig" "$root/.gitignore"
    else
        rm -f "$root/.gitignore"
    fi
    rm -rf "$stage"
    echo "rolled back — the vendored setup is untouched" >&2
}
rollback_on_exit() {
    local rc=$?
    rollback
    exit "$rc"
}
# Every live write through verified sync is covered by rollback, including a
# plain set -e/EXIT failure rather than only an explicit sync refusal.
trap rollback_on_exit EXIT
trap 'rollback; exit 130' INT TERM
if [ ! -f "$root/.gitignore" ] || ! grep -q '^\.intelligence/' "$root/.gitignore"; then
    {
        [ -f "$root/.gitignore" ] && [ -n "$(tail -c 1 "$root/.gitignore" 2>/dev/null)" ] && echo ""
        echo "# intelligence CLI package store (restored automatically by 'intelligence sync')"
        echo ".intelligence/"
    } >> "$root/.gitignore"
fi
mv "$stage/.intelligence" "$root/.intelligence"
cp "$manifest_stage" "$root/intelligence.yaml"
lock_write_from_tsv "$root/intelligence.lock" "$lock_rows"

sync_out="$(cd "$root" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI_DIR/commands/sync.sh" 2>&1)" || {
    echo "$sync_out"
    die "sync of the migrated state failed"
}
echo "$sync_out" | grep -q '^IS_STATUS=ok' || {
    echo "$sync_out"
    die "sync of the migrated state did not report ok"
}
# Point of no return: the new state is verified. From here an interrupt must
# NOT roll back (the old setup is being removed) — only clean the stage.
commit_active=0
trap cleanup_stage EXIT INT TERM

# Only now is anything of the old setup removed — and config.yaml is kept as
# a reviewable backup inside the store.
mkdir -p "$root/.intelligence/backup"
cp "$config" "$root/.intelligence/backup/config.yaml"
while IFS="$LOCK_SEP" read -r pack name url ref mirror; do
    # Containment before deletion: a mirror value is config input, and rm -rf
    # must never follow it out of the repository.
    case "$mirror" in
        ""|/*|*..*) [ -n "$mirror" ] && echo "  WARN: mirror '$mirror' not repo-contained — left in place" >&2; continue ;;
    esac
    if [ -d "$root/$mirror" ]; then
        rm -rf "${root:?}/$mirror"
        # An emptied legacy mirror parent (for example intelligence/external/) goes with it.
        rmdir "$(dirname "$root/$mirror")" 2>/dev/null || true
    fi
done < "$pack_rows"
rm -rf "$module_dir"
rm -f "$config"
# An emptied umbrella dir (config-only setups) is dropped; one with project
# content stays.
rmdir "$umbrella" 2>/dev/null || true

echo ""
echo "migrated. Review the diff, then commit. The old config.yaml is kept at .intelligence/backup/config.yaml."
echo "From now on: intelligence sync | package | update | status."
echo "Next: ask your agent to run /intelligence-learn-from-repository to review the migrated project context."
