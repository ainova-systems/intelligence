#!/bin/bash
# Preserve the pre-Intelligence state described by enabled adapter contracts.
# The snapshot is data-only and explicitly identifies itself as initial
# onboarding state so recovery skills never mistake it for generated output.

onboarding_source_paths() {
    local root="$1" content_dir="$2" targets="$3" target output
    for target in $targets; do
        output="$(default_target_output "$target")"
        adapter_contract_paths "$root" "$content_dir" "$target" "$output"
    done | awk 'NF && !seen[$0]++'
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
    local rel src dest backup_rel backup stage target
    backup_rel="$content_dir/_backup"
    backup="$root/$backup_rel"
    ONBOARDING_BACKUP_COUNT="$(onboarding_source_count "$root" "$content_dir" "$targets")"
    ONBOARDING_BACKUP_REL=""
    export ONBOARDING_BACKUP_COUNT ONBOARDING_BACKUP_REL
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

    mv "$stage" "$backup"
    ensure_gitignore_header "$root"
    gitignore_add_line "$root" "$backup_rel/"
    ONBOARDING_BACKUP_REL="$backup_rel"
    export ONBOARDING_BACKUP_REL
}
