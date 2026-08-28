#!/bin/bash
# Preserve the pre-Intelligence state described by enabled adapter contracts.
# The snapshot is data-only and explicitly identifies itself as initial
# onboarding state so recovery skills never mistake it for generated output.

onboarding_source_records() {
    local root="$1" content_dir="$2" targets="$3" target output
    for target in $targets; do
        output="$(default_target_output "$target")"
        adapter_contract_onboarding_records "$root" "$content_dir" "$target" "$output"
    done | awk -F '\t' 'NF == 2 && !seen[$1 SUBSEP $2]++'
}

onboarding_source_paths() {
    onboarding_source_records "$1" "$2" "$3" \
        | awk -F '\t' 'NF == 2 && !seen[$2]++ { print $2 }'
}

onboarding_legacy_paths() {
    onboarding_source_records "$1" "$2" "$3" \
        | awk -F '\t' '$1 == "legacy" && !seen[$2]++ { print $2 }'
}

onboarding_source_count() {
    local root="$1" content_dir="$2" targets="$3" rel count=0
    while IFS= read -r rel; do
        [ -e "$root/$rel" ] || [ -L "$root/$rel" ] || continue
        count=$((count + 1))
    done < <(onboarding_source_paths "$root" "$content_dir" "$targets")
    printf '%s\n' "$count"
}

preserve_onboarding_sources() {
    local root="$1" content_dir="$2" targets="$3"
    local rel src dest backup_rel backup stage target legacy_count=0
    backup_rel="$content_dir/_backup"
    backup="$root/$backup_rel"
    ONBOARDING_BACKUP_COUNT="$(onboarding_source_count "$root" "$content_dir" "$targets")"
    ONBOARDING_BACKUP_REL=""
    ONBOARDING_LEGACY_COUNT=0
    export ONBOARDING_BACKUP_COUNT ONBOARDING_BACKUP_REL ONBOARDING_LEGACY_COUNT
    [ "$ONBOARDING_BACKUP_COUNT" -gt 0 ] || return 0
    [ ! -e "$backup" ] || die "onboarding backup already exists at $backup_rel - review or move it before rerunning init"

    mkdir -p "$root/$content_dir"
    stage="$root/$content_dir/.backup-stage.$$"
    [ ! -e "$stage" ] || die "temporary onboarding backup path already exists"
    mkdir -p "$stage"

    {
        printf '# Intelligence initial-state backup contract v1\n'
        printf 'state\tinitial-onboarding\n'
        printf 'source\tpre-intelligence\n'
        for target in $targets; do printf 'target\t%s\n' "$target"; done
    } > "$stage/manifest.tsv"

    while IFS= read -r rel; do
        src="$root/$rel"
        [ -e "$src" ] || [ -L "$src" ] || continue
        dest="$stage/$rel"
        mkdir -p "$(dirname "$dest")"
        if ! cp -R "$src" "$dest"; then
            rm -rf "$stage"
            die "failed to preserve initial AI instruction path '$rel'"
        fi
        printf 'path\t%s\n' "$rel" >> "$stage/manifest.tsv"
    done < <(onboarding_source_paths "$root" "$content_dir" "$targets")

    while IFS= read -r rel; do
        [ -e "$stage/$rel" ] || [ -L "$stage/$rel" ] || continue
        printf 'legacy\t%s\n' "$rel" >> "$stage/manifest.tsv"
        legacy_count=$((legacy_count + 1))
    done < <(onboarding_legacy_paths "$root" "$content_dir" "$targets")

    # This marker is deliberately outside manifest.tsv: the manifest is the
    # immutable inventory, while the marker is short-lived transaction state.
    [ "$legacy_count" -eq 0 ] || : > "$stage/.quarantine-pending"

    mv "$stage" "$backup"
    ensure_gitignore_header "$root"
    gitignore_add_line "$root" "$backup_rel/"
    ONBOARDING_BACKUP_REL="$backup_rel"
    ONBOARDING_LEGACY_COUNT="$legacy_count"
    export ONBOARDING_BACKUP_REL ONBOARDING_LEGACY_COUNT
}

onboarding_quarantine_is_pending() {
    [ -f "$1/$2/_backup/.quarantine-pending" ]
}

onboarding_backup_legacy_paths() {
    local manifest="$1/$2/_backup/manifest.tsv"
    [ -f "$manifest" ] || return 0
    awk -F '\t' '$1 == "legacy" && NF == 2 && !seen[$2]++ { print $2 }' "$manifest"
}

quarantine_onboarding_legacy_sources() {
    local root="$1" content_dir="$2" rel src backup
    onboarding_quarantine_is_pending "$root" "$content_dir" || return 0
    backup="$root/$content_dir/_backup"
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        src="$root/$rel"
        [ -e "$src" ] || [ -L "$src" ] || continue
        [ -e "$backup/$rel" ] || [ -L "$backup/$rel" ] \
            || die "initial backup is missing legacy path '$rel'"
        if [ -d "$src" ] && [ ! -L "$src" ]; then
            rm -rf -- "$src"
        else
            rm -f -- "$src"
        fi
    done < <(onboarding_backup_legacy_paths "$root" "$content_dir")
}

restore_onboarding_legacy_sources() {
    local root="$1" content_dir="$2" rel src dest backup
    onboarding_quarantine_is_pending "$root" "$content_dir" || return 0
    backup="$root/$content_dir/_backup"
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        src="$backup/$rel"
        [ -e "$src" ] || [ -L "$src" ] || continue
        dest="$root/$rel"
        if [ -d "$dest" ] && [ ! -L "$dest" ]; then
            rm -rf -- "$dest"
        else
            rm -f -- "$dest"
        fi
        mkdir -p "$(dirname "$dest")"
        cp -R "$src" "$dest" || die "failed to restore legacy onboarding path '$rel'"
    done < <(onboarding_backup_legacy_paths "$root" "$content_dir")
}

complete_onboarding_quarantine() {
    local marker="$1/$2/_backup/.quarantine-pending"
    [ ! -f "$marker" ] || rm -f -- "$marker"
}
