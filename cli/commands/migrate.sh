#!/bin/bash
# intelligence migrate [--dry-run] [--force] — convert a vendored (v1) setup
# to the CLI setup: root intelligence.yaml, .intelligence/ store,
# intelligence.lock, no vendored engine.
#
# Transactional in the migrations.sh spirit: STAGE everything next to the
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
    v2) die "already on the CLI setup ($IP_ROOT/intelligence.yaml)" ;;
    *) die "no vendored setup found here — 'intelligence init' starts a fresh project" ;;
esac
root="$IP_ROOT"
umbrella="$IP_UMBRELLA"
module_dir="$IP_MODULE_DIR"
config="$umbrella/config.yaml"
module_rel="${module_dir#"$root"/}"

[ -f "$root/intelligence.yaml" ] && die "intelligence.yaml already exists at the root — half-migrated state; resolve it manually"
if [ "$dry_run" -eq 0 ] && [ "$force" -eq 0 ]; then
    if [ -n "$(git -C "$root" status --porcelain 2>/dev/null)" ]; then
        die "working tree is not clean — commit or stash first (or --force); migrate wants a one-commit diff you can review and revert"
    fi
fi

stamp="$(read_engine_stamp "$config")"
eng="$(bundled_engine_version)"
[ -n "$stamp" ] && _ver_gt "$stamp" "$eng" && die "project schema $stamp is newer than this CLI's engine $eng — update the CLI first"

# A schema gap is closed by the engine's own proven chain before conversion.
if [ "$dry_run" -eq 0 ] && { [ -z "$stamp" ] || _ver_gt "$eng" "$stamp"; }; then
    echo "== applying the engine migration chain ($stamp -> $eng) =="
    run_migrations "$umbrella" "$(basename "$module_dir")" "" || die "engine migration chain failed (IS_STATUS above) — nothing converted"
    stamp_version "$config" "$eng"
fi

# ---- Stage ----------------------------------------------------------------
stage="$root/.intelligence-migrate-stage.$$"
[ "$dry_run" -eq 1 ] && stage="$(mktemp -d -t intelligence-migrate-XXXXXX 2>/dev/null || mktemp -d)"
cleanup_stage() { rm -rf "$stage"; }
trap cleanup_stage EXIT INT TERM
mkdir -p "$stage/.intelligence/packages"

echo "== staging =="
stage_engine_content "$stage/.intelligence/engine"

# Legacy pack name -> v2 package name (@org/repo derived from the url), plus
# per-pack source facts. Recorded as rows for the config rewrite and the lock.
pack_rows="$stage/packs.rows"
: > "$pack_rows"
while IFS= read -r pack; do
    [ -n "$pack" ] || continue
    url="$(get_pack_field "$config" "$pack" "url")"
    ref="$(get_pack_field "$config" "$pack" "ref")"
    mirror="$(get_pack_field "$config" "$pack" "mirror")"
    [ -n "$url" ] || die "pack '$pack' has no url in config.yaml"
    base="${url%.git}"; base="${base%/}"
    repo="$(basename "$base")"
    org="$(basename "$(dirname "$base")")"
    case "$org" in ""|*[!A-Za-z0-9._-]*) org="local" ;; esac
    case "$repo" in ""|*[!A-Za-z0-9._-]*) repo="$(printf '%s' "$repo" | tr -c 'A-Za-z0-9._-' '-')" ;; esac
    name="@$org/$repo"
    assert_valid_pkg_name "$name"
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
        sha="$(GIT_TERMINAL_PROMPT=0 git ls-remote "$url" "$ref" 2>/dev/null | awk '{print $1; exit}')"
    fi
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
            printf '.intelligence/engine/%s' "${v##*/}"
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
                v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
                echo "$indent- \"$(rewrite_source_value "$v")\""
                continue
                ;;
        esac
    fi
    echo "$line"
done < "$config" > "$manifest_stage"
stamp_version "$manifest_stage" "$eng"

# packages: entries (pin preserved — no invented ranges).
while IFS="$LOCK_SEP" read -r pack name url ref mirror; do
    [ -n "$pack" ] || continue
    qmap_set "$manifest_stage" "packages" "$name" "url" "$url"
    [ -n "$ref" ] && qmap_set "$manifest_stage" "packages" "$name" "ref" "$ref"
done < "$pack_rows"

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
for adapter in agents claude cursor copilot codex pi opencode; do
    old_e="$(is_target_enabled "$config" "$adapter")"
    new_e="$(is_target_enabled "$manifest_stage" "$adapter")"
    [ "$old_e" = "$new_e" ] || { echo "  TARGET DRIFT: $adapter enabled '$old_e' -> '$new_e'"; fail=1; }
    old_o="$(get_target_output "$config" "$adapter")"
    new_o="$(get_target_output "$manifest_stage" "$adapter")"
    [ "$old_o" = "$new_o" ] || { echo "  TARGET DRIFT: $adapter output '$old_o' -> '$new_o'"; fail=1; }
done
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
if [ ! -f "$root/.gitignore" ] || ! grep -q '^\.intelligence/' "$root/.gitignore"; then
    {
        [ -f "$root/.gitignore" ] && [ -n "$(tail -c 1 "$root/.gitignore" 2>/dev/null)" ] && echo ""
        echo "# intelligence CLI package store (restored by 'intelligence install')"
        echo ".intelligence/"
    } >> "$root/.gitignore"
fi
rollback() {
    rm -rf "$root/.intelligence" "$root/intelligence.yaml" "$root/intelligence.lock"
    echo "rolled back — the vendored setup is untouched" >&2
}
mv "$stage/.intelligence" "$root/.intelligence"
cp "$manifest_stage" "$root/intelligence.yaml"
lock_write_from_tsv "$root/intelligence.lock" "$lock_rows"

sync_out="$(cd "$root" && IS_SUPPRESS_CLI_NOTE=1 bash "$CLI_DIR/commands/sync.sh" 2>&1)" || {
    echo "$sync_out"
    rollback
    die "sync of the migrated state failed — rolled back"
}
echo "$sync_out" | grep -q '^IS_STATUS=ok' || {
    echo "$sync_out"
    rollback
    die "sync of the migrated state did not report ok — rolled back"
}

# Only now is anything of the old setup removed — and config.yaml is kept as
# a reviewable backup inside the store.
mkdir -p "$root/.intelligence/backup"
cp "$config" "$root/.intelligence/backup/config.yaml"
while IFS="$LOCK_SEP" read -r pack name url ref mirror; do
    if [ -n "$mirror" ] && [ -d "$root/$mirror" ]; then
        rm -rf "${root:?}/$mirror"
        # An emptied mirror parent (e.g. <umbrella>/external/) goes with it.
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
echo "From now on: intelligence sync | add | install | doctor."
