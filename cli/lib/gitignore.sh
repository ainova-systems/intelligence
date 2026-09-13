#!/bin/bash
# Generated-output policy derived from each adapter's ownership contract.

# The line that separates what this policy manages from what the project wrote
# before Intelligence touched the file: everything the CLI appends lands after
# it, so it is also the boundary of what the CLI may rewrite.
IS_GITIGNORE_HEADER='# Intelligence generated state and tool output'

# Line endings held in variables, never written as `$'\r'` at the point of use:
# inside a command substitution bash does not expand that form, so the very same
# expression stops stripping the CR depending on where it is called from.
IS_CR=$'\r'
IS_LF=$'\n'
IS_CRLF=$'\r\n'

# An ignore file checked out on Windows can hold CRLF, and a CR belongs to the
# pattern Git matches — so these two helpers decide presence ignoring it, and
# append in whatever ending the file already uses. Comparing with the CR
# attached made every existing line look absent on Linux and macOS (where it is
# part of the line, unlike under MSYS), so each alignment appended an LF copy of
# a line that was already there and the file grew forever.

# ignore_file_eol_var <file> — set IS_IGNORE_EOL from the file's first line.
ignore_file_eol_var() {
    local file="$1" first=""
    IS_IGNORE_EOL="$IS_LF"
    [ -s "$file" ] || return 0
    IFS= read -r first < "$file" || true
    case "$first" in
        *"$IS_CR") IS_IGNORE_EOL="$IS_CRLF" ;;
    esac
}

# ignore_file_has_line <file> <line> — true when the file lists exactly this
# line, with or without a trailing CR.
ignore_file_has_line() {
    local file="$1" line="$2"
    [ -f "$file" ] || return 1
    grep -Fqx -- "$line" "$file" 2>/dev/null && return 0
    grep -Fqx -- "$line$IS_CR" "$file" 2>/dev/null
}

# ignore_file_append_line <file> <line> — append in the file's own ending.
ignore_file_append_line() {
    local file="$1" line="$2"
    ignore_file_eol_var "$file"
    printf '%s%s' "$line" "$IS_IGNORE_EOL" >> "$file"
}

gitignore_add_line() {
    local root="$1" line="$2" file="$1/.gitignore"
    ignore_file_has_line "$file" "$line" && return 0
    ignore_file_append_line "$file" "$line"
}

gitignore_path_is_ignored() {
    local root="$1" path="$2"
    git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 2
    git -C "$root" check-ignore -q --no-index -- "$path"
}

# True when the file's last lines are exactly these, in order.
gitignore_tail_is() {
    local file="$1"; shift
    [ -f "$file" ] || return 1
    local want tail_lines
    want="$(printf '%s\n' "$@")"
    # CR stripped for the comparison only — the chain is the same chain whether
    # the file is LF or CRLF.
    tail_lines="$(tail -n "$#" -- "$file" | tr -d '\r')"
    [ "$tail_lines" = "$want" ]
}

# gitignore_collapse_duplicates <root> <probe-path> <line…> — keep only the LAST
# occurrence of each given line inside the region this policy owns (its header
# to end of file).
#
# This removes residue, never meaning: Git applies the last matching rule, so
# identical earlier copies of a line decide nothing. The copies exist because
# the 0.12.0 repair appended the whole negation chain on every alignment — a
# project carries one chain per run it made, and 0.12.1 only stopped the growth.
#
# Lines above the header predate Intelligence and are left untouched, including
# a hand-written copy of a line this policy also writes. The probe path is
# re-checked afterwards: a collapse that somehow changed what Git ignores is
# rolled back rather than committed.
gitignore_collapse_duplicates() {
    local root="$1" probe="$2"; shift 2
    local file="$root/.gitignore" tmp backup before=0 after=0
    local -a lines=() managed=("$@") last_idx=()
    local line key i mi n hdr=-1 keep final_newline=1
    [ -f "$file" ] || return 0

    # Read and write the file's own bytes, without awk: on Windows it reads in
    # text mode and would hand back every line stripped of its CR, rewriting a
    # CRLF file as LF. A line's CR is significant to Git, and either way the
    # lines this function does not remove must survive byte-for-byte.
    line=""
    while IFS= read -r line; do
        lines[${#lines[@]}]="$line"
        line=""
    done < "$file"
    # `read` returns 1 at EOF but still fills `line` when the file's last line
    # carries no newline; preserve that ending instead of adding one.
    if [ -n "$line" ]; then
        lines[${#lines[@]}]="$line"
        final_newline=0
    fi
    n=${#lines[@]}
    for ((i = 0; i < n; i++)); do
        if [ "${lines[i]%"$IS_CR"}" = "$IS_GITIGNORE_HEADER" ]; then hdr=$i; break; fi
    done
    [ "$hdr" -ge 0 ] || return 0

    # Where each managed line last occurs below the header. Indexed arrays and
    # arithmetic `for` only — Bash 3.2 has no associative arrays.
    for ((mi = 0; mi < ${#managed[@]}; mi++)); do
        last_idx[mi]=-1
        for ((i = hdr + 1; i < n; i++)); do
            [ "${lines[i]%"$IS_CR"}" = "${managed[mi]}" ] && last_idx[mi]=$i
        done
    done

    tmp="$file.cli.tmp"
    {
        for ((i = 0; i < n; i++)); do
            keep=1
            if [ "$i" -gt "$hdr" ]; then
                key="${lines[i]%"$IS_CR"}"
                for ((mi = 0; mi < ${#managed[@]}; mi++)); do
                    if [ "$key" = "${managed[mi]}" ] && [ "$i" -ne "${last_idx[mi]}" ]; then
                        keep=0
                        break
                    fi
                done
            fi
            [ "$keep" -eq 1 ] || continue
            if [ "$i" -eq $((n - 1)) ] && [ "$final_newline" -eq 0 ]; then
                printf '%s' "${lines[i]}"
            else
                printf '%s\n' "${lines[i]}"
            fi
        done
    } > "$tmp"
    if [ ! -s "$tmp" ] || cmp -s "$tmp" "$file"; then
        rm -f "$tmp"
        return 0
    fi

    before=0
    gitignore_path_is_ignored "$root" "$probe" || before=$?
    backup="$file.cli.bak"
    cp -- "$file" "$backup"
    mv -- "$tmp" "$file"
    after=0
    gitignore_path_is_ignored "$root" "$probe" || after=$?
    if [ "$after" != "$before" ]; then
        mv -- "$backup" "$file"
        return 0
    fi
    rm -f "$backup"
}

# Git cannot re-include a child of an excluded directory, so an include needs an
# explicit negation for every parent. A negation only wins when it comes after
# the rule excluding the parent, and the only repair an append can make is to
# move the whole chain last — so the repair runs when, and only when, the chain
# is not already there.
#
# Probe the include TARGET, never a parent with a trailing slash: `dir/*` — the
# ignore this very policy writes — matches `dir/` because `*` matches the empty
# string, so a parent probe answers "still ignored" in the healthy end state.
# Keyed on that, the repair re-appended a line already last, which cannot change
# the answer, and the file grew by one line on every run.
gitignore_add_effective_include() {
    local root="$1" value="${2#./}" dir parent="" part line rc
    local -a negations=()
    dir="${value%/*}"
    if [ "$dir" != "$value" ]; then
        while IFS= read -r part; do
            [ -n "$part" ] || continue
            if [ -n "$parent" ]; then parent="$parent/$part"; else parent="$part"; fi
            negations+=("!$parent/")
        done < <(printf '%s\n' "$dir" | tr '/' '\n')
    fi
    negations+=("!$value")

    for line in "${negations[@]}"; do
        gitignore_add_line "$root" "$line"
    done

    # `|| rc=$?` keeps the probe out of `set -e`'s reach: its honest "not
    # ignored" is exit 1, and a bare call would abort the whole command there.
    rc=0
    gitignore_path_is_ignored "$root" "$value" || rc=$?
    case "$rc" in
        0) ;;
        1|2) gitignore_collapse_duplicates "$root" "$value" "${negations[@]}"; return 0 ;;
        *) return "$rc" ;;
    esac

    # Still ignored: an earlier negation is shadowed by a later rule. Move the
    # chain last. Already last means appending cannot help — leave it, and let
    # `status --check` report the re-inclusion this policy could not make
    # effective rather than growing the file forever.
    if ! gitignore_tail_is "$root/.gitignore" "${negations[@]}"; then
        for line in "${negations[@]}"; do
            ignore_file_append_line "$root/.gitignore" "$line"
        done
    fi
    # Either way the chain now stands last, so any earlier copy of it is the
    # residue an older CLI appended; collapsing runs on both paths so a project
    # converges on one copy whether or not this run had to move anything.
    gitignore_collapse_duplicates "$root" "$value" "${negations[@]}"
}

ensure_gitignore_header() {
    local root="$1" file="$1/.gitignore"
    if ! ignore_file_has_line "$file" "$IS_GITIGNORE_HEADER"; then
        if [ -f "$file" ] && [ -s "$file" ] && [ -n "$(tail -c 1 "$file" 2>/dev/null)" ]; then
            ignore_file_eol_var "$file"
            printf '%s' "$IS_IGNORE_EOL" >> "$file"
        fi
        ignore_file_append_line "$file" "$IS_GITIGNORE_HEADER"
    fi
}

ensure_base_gitignore() {
    local root="$1"
    ensure_gitignore_header "$root"
    gitignore_add_line "$root" '.intelligence/'
}

ensure_target_gitignore() {
    local root="$1" manifest="$2" target="$3" content_dir output kind value records
    ensure_gitignore_header "$root"
    content_dir="$(manifest_intelligence_dir "$manifest")"
    output="$(get_target_output "$manifest" "$target")"
    [ -n "$output" ] || output="$(default_target_output "$target")"
    records="$(adapter_records_for "$root" "$content_dir" "$target" "$output")" \
        || die "adapter '$target' has an invalid ownership contract"
    while IFS=$'\t' read -r kind value; do
        case "$kind" in
            ignore)  gitignore_add_line "$root" "$value" ;;
            include) gitignore_add_effective_include "$root" "$value" ;;
        esac
    done <<< "$records"
}

ensure_manifest_gitignore() {
    local root="$1" manifest="$2" target
    ensure_base_gitignore "$root"
    while IFS= read -r target; do
        [ -n "$target" ] || continue
        if [ "$(is_target_enabled "$manifest" "$target")" = "1" ]; then
            ensure_target_gitignore "$root" "$manifest" "$target"
        fi
    done < <(target_names "$manifest")
}

# Publishing/build tools do not share Git's ignore policy. In particular,
# .vscodeignore and .npmignore become the packager's own filter, while Docker
# always builds from its independent context filter. Only amend files the
# project already has: their presence is the explicit signal that this root is
# packaged or sent as a build context.
publisher_ignore_file_names() {
    printf '%s\n' .vscodeignore .npmignore .dockerignore
}

publisher_ignore_add_line() {
    local file="$1" line="$2"
    ignore_file_has_line "$file" "$line" && return 0
    ignore_file_append_line "$file" "$line"
    PUBLISH_IGNORE_FILE_CHANGED=1
}

publisher_ignore_add_path() {
    local file="$1" path="${2#./}"
    path="${path%/}"
    [ -n "$path" ] || return 0
    publisher_ignore_add_line "$file" "$path"
    publisher_ignore_add_line "$file" "$path/**"
}

ensure_manifest_publisher_ignores() {
    local root="$1" manifest="$2" rel file content_dir target output records kind value
    content_dir="$(manifest_intelligence_dir "$manifest")"
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        file="$root/$rel"
        [ -f "$file" ] || continue
        PUBLISH_IGNORE_FILE_CHANGED=0
        if ! ignore_file_has_line "$file" '# Intelligence development context and generated output'; then
            if [ -s "$file" ] && [ -n "$(tail -c 1 "$file" 2>/dev/null)" ]; then
                ignore_file_eol_var "$file"
                printf '%s' "$IS_IGNORE_EOL" >> "$file"
            fi
            ignore_file_append_line "$file" '# Intelligence development context and generated output'
            PUBLISH_IGNORE_FILE_CHANGED=1
        fi
        publisher_ignore_add_path "$file" '.intelligence'
        publisher_ignore_add_line "$file" 'intelligence.yaml'
        publisher_ignore_add_line "$file" 'intelligence.lock'
        publisher_ignore_add_path "$file" "$content_dir"
        while IFS= read -r target; do
            [ -n "$target" ] || continue
            [ "$(is_target_enabled "$manifest" "$target")" = "1" ] || continue
            output="$(get_target_output "$manifest" "$target")"
            [ -n "$output" ] || output="$(default_target_output "$target")"
            publisher_ignore_add_path "$file" "$output"
            records="$(adapter_records_for "$root" "$content_dir" "$target" "$output")" \
                || die "adapter '$target' has an invalid ownership contract"
            while IFS=$'\t' read -r kind value; do
                case "$kind" in
                    owned|managed|legacy) publisher_ignore_add_path "$file" "$value" ;;
                esac
            done <<< "$records"
        done < <(target_names "$manifest")
        if [ "$PUBLISH_IGNORE_FILE_CHANGED" -eq 1 ]; then
            echo "packaging exclusions updated: $rel"
        fi
    done < <(publisher_ignore_file_names)
}

managed_gitignore_patterns() {
    local root="$1" manifest="$2" content_dir target output records kind value
    content_dir="$(manifest_intelligence_dir "$manifest")"
    printf '%s\n' '.intelligence/' "$content_dir/_backup/"
    while IFS= read -r target; do
        [ -n "$target" ] || continue
        [ "$(is_target_enabled "$manifest" "$target")" = "1" ] || continue
        output="$(get_target_output "$manifest" "$target")"
        [ -n "$output" ] || output="$(default_target_output "$target")"
        records="$(adapter_records_for "$root" "$content_dir" "$target" "$output")" \
            || return 1
        while IFS=$'\t' read -r kind value; do
            case "$kind" in
                ignore) printf '%s\n' "$value" ;;
                include) printf '!%s\n' "$value" ;;
            esac
        done <<< "$records"
    done < <(target_names "$manifest")
}

# Git does not apply ignore rules retroactively to files already in its index.
# Name each affected path that still exists and print a command which only
# untracks it. Quarantined legacy paths are already worktree deletions and must
# not receive a misleading "keep the local copy" instruction.
report_tracked_managed_ignores() {
    local root="$1" manifest="$2" patterns tracked path quoted posix_quoted powershell_quoted announced=0
    git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
    patterns="$(mktemp -t intelligence-gitignore-XXXXXX)"
    tracked="$(mktemp -t intelligence-tracked-XXXXXX)"
    managed_gitignore_patterns "$root" "$manifest" > "$patterns" || {
        rm -f "$patterns" "$tracked"
        return 0
    }
    git -C "$root" ls-files -z -ci --exclude-from="$patterns" > "$tracked" 2>/dev/null || true
    rm -f "$patterns"
    [ -s "$tracked" ] || {
        rm -f "$tracked"
        return 0
    }
    while IFS= read -r -d '' path; do
        [ -n "$path" ] || continue
        [ -e "$root/$path" ] || [ -L "$root/$path" ] || continue
        if [ "$announced" -eq 0 ]; then
            echo "  Tracked files still bypass these .gitignore rules. Untrack them without deleting local copies:"
            announced=1
        fi
        if [[ "$path" == *"'"* ]]; then
            # macOS still ships Bash 3.2; use portable sed rather than newer
            # parameter-replacement behavior for the embedded quote.
            posix_quoted="$(printf '%s' "$path" | sed "s/'/'\\\\''/g")"
            powershell_quoted="$(printf '%s' "$path" | sed "s/'/''/g")"
            printf "    POSIX:      git rm --cached -- '%s'\n" "$posix_quoted"
            printf "    PowerShell: git rm --cached -- '%s'\n" "$powershell_quoted"
        else
            quoted="'$path'"
            printf '    git rm --cached -- %s\n' "$quoted"
        fi
    done < "$tracked"
    rm -f "$tracked"
}
