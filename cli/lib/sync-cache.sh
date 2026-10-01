#!/bin/bash
# Optional CLI optimization. Cache data never supplies paths or executable code:
# every dependency is derived again from the manifest and built-in contracts.

sync_cache_safe_path() {
    local path="$1" probe="$1"
    case "$path" in *[[:cntrl:]]*|*\\*|*\"*) return 1 ;; esac
    # Include ancestors: find does not report a link above its starting path.
    while [ -n "$probe" ] && [ "$probe" != / ]; do
        case "$probe" in "$REPO_ROOT"|"$CLI_DIR"|"$IS_ENGINE_DIR") break ;; esac
        [ ! -L "$probe" ] || return 1
        probe="${probe%/*}"
    done
}

# One checked enumeration and one batch hash, including names, directory/file
# types and executable bits. Timestamps cannot prove content is unchanged.
# Unsupported paths/types are a cache miss, never an incomplete fingerprint.
# Keep list descriptors open across the walk; reopening each line is expensive
# on Windows and provides no additional content verification.
sync_cache_fingerprint() (
    local work="$1" path kind executable seen=$'\n'
    local -a existing
    existing=()
    shift
    : > "$work/entries" || return 1
    : > "$work/files" || return 1
    : > "$work/list" || return 1
    for path in "$@"; do
        sync_cache_safe_path "$path" || return 1
        # Shared managed destinations are declared by several adapters. Walking
        # the same tree again only multiplies filesystem probes on Windows.
        case "$seen" in *$'\n'"$path"$'\n'*) continue ;; esac
        seen="$seen$path"$'\n'
        if [ -e "$path" ]; then
            existing+=("$path")
        else
            printf 'missing\t%s\n' "$path" >> "$work/entries" || return 1
        fi
    done
    if [ "${#existing[@]}" -gt 0 ]; then
        find "${existing[@]}" -print0 > "$work/list" || return 1
    fi
    while IFS= read -r -d '' path; do
        # Starting-path ancestors were checked above. find does not follow
        # links, so checking each returned entry once covers the entire tree.
        case "$path" in *[[:cntrl:]]*|*\\*|*\"*) return 1 ;; esac
        [ ! -L "$path" ] || return 1
        executable=0
        if [ -f "$path" ]; then
            kind='file'
            [ ! -x "$path" ] || executable=1
            printf '%s\n' "$path" >&4 || return 1
        elif [ -d "$path" ]; then
            kind=directory
        else
            return 1
        fi
        printf '%s\t%s\t%s\n' "$kind" "$executable" "$path" >&3 || return 1
    done < "$work/list" 3>> "$work/entries" 4> "$work/files" || return 1
    # find order need not be stable. Sort both streams; preserve path-to-hash
    # association by feeding the sorted file list into a single git process.
    LC_ALL=C sort -u "$work/entries" > "$work/sorted" || return 1
    LC_ALL=C sort -u "$work/files" > "$work/paths" || return 1
    if command -v cygpath >/dev/null 2>&1; then
        # Git for Windows does not translate POSIX paths received on stdin.
        cygpath -m -f "$work/paths" > "$work/native" || return 1
    else
        cp "$work/paths" "$work/native" || return 1
    fi
    git hash-object --no-filters --stdin-paths < "$work/native" > "$work/hashes" || return 1
    cat "$work/sorted" "$work/paths" "$work/hashes" | git hash-object --stdin || return 1
)

sync_cache_dependencies() {
    local src section adapter file output records kind value
    SC_INPUTS=("$CONFIG_FILE" "$REPO_ROOT/intelligence.lock"
        "$CLI_DIR/intelligence" "$CLI_DIR/engine-package.yaml"
        "$CLI_DIR/commands" "$CLI_DIR/internal" "$CLI_DIR/lib" "$IS_ENGINE_DIR"
        "$REPO_ROOT/$IS_CONTENT_REL/adapters")
    SC_OUTPUTS=()
    # Project adapters can read arbitrary files or environment and execute any
    # code. Their dependencies cannot be inferred from their write contract.
    for file in "$REPO_ROOT/$IS_CONTENT_REL/adapters"/*.sh; do
        [ ! -e "$file" ] && [ ! -L "$file" ] || return 1
    done
    for section in rules agents skills; do
        load_yaml_list "$CONFIG_FILE" "$section"
        while IFS= read -r src; do
            [ -n "$src" ] || continue
            adapter_contract_safe_concrete_path "$src" || return 1
            case "$src" in .|./|.intelligence|.intelligence/|.intelligence/sync-cache*) return 1 ;; esac
            SC_INPUTS+=("$REPO_ROOT/$src")
        done <<< "$IS_YAML_LIST"
    done
    load_targets_cache "$CONFIG_FILE"
    for file in "$IS_ENGINE_DIR/adapters"/*.sh; do
        adapter="${file##*/}"; adapter="${adapter%.sh}"
        [ "$adapter" != _template ] || continue
        target_enabled_var "$CONFIG_FILE" "$adapter"
        [ "$IS_TGT_ENABLED" = 1 ] || continue
        case "$adapter" in agents|antigravity|claude|codex|copilot|cursor|opencode|pi) ;; *) return 1 ;; esac
        target_output_var "$CONFIG_FILE" "$adapter"
        output="${IS_TGT_OUTPUT:-.$adapter}"
        records="$(adapter_contract_records "$adapter" "$file" "$output")" || return 1
        while IFS=$'\t' read -r kind value; do
            case "$kind" in owned|managed) SC_OUTPUTS+=("$REPO_ROOT/$value") ;; esac
        done <<< "$records"
    done
    [ "${#SC_OUTPUTS[@]}" -gt 0 ]
}

sync_cache_input_hash() {
    local fingerprint payload
    fingerprint="$(sync_cache_fingerprint "$1" "${SC_INPUTS[@]}")" || return 1
    [ -n "${SC_UMASK:-}" ] || SC_UMASK="$(umask)"
    # Explicit environment values that affect rendering, discovery or parsing.
    # No secrets or inherited environment dump are persisted.
    printf -v payload '%s\n' "$fingerprint" "$2" "$REPO_ROOT" "$CONFIG_FILE" \
        "$IS_CONTENT_REL" "$IS_MODULE_REL" "$IS_SYNC_CMD" "$IS_MANIFEST_NAME" \
        "$IS_PROTECTED_DIRS" "$BASH_VERSION" "${OSTYPE:-}" "${LANG:-}" \
        "${LC_ALL:-}" "${LC_CTYPE:-}" "${LC_COLLATE:-}" "${PATH:-}" "$SC_UMASK"
    # A here-string appends the final newline the payload already ends with.
    git hash-object --stdin <<< "${payload%$'\n'}"
}

sync_cache_directory() {
    local path="$REPO_ROOT/.intelligence/sync-cache" physical root_physical probe expected
    sync_cache_safe_path "$path/state" || return 1
    root_physical="$(cd "$REPO_ROOT" && pwd -P)" || return 1
    probe="$path"; expected="$root_physical/.intelligence/sync-cache"
    while [ ! -e "$probe" ]; do probe="${probe%/*}"; expected="${expected%/*}"; done
    physical="$(cd "$probe" && pwd -P)" || return 1
    [ "$physical" = "$expected" ] || return 1
    if [ "${1:-}" = create ]; then mkdir -p "$path" || return 1; fi
    SC_DIRECTORY="$path"
}

sync_cache_read() {
    local file="$1" input="$2" output="$3" work="$4" header report_hash actual
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    IFS= read -r header < "$file" || return 1
    case "$header" in "intelligence-sync-cache-v1 $input $output "*) ;; *) return 1 ;; esac
    report_hash="${header##* }"
    case "$report_hash" in ''|*[!a-f0-9]*) return 1 ;; esac
    [ "${#report_hash}" -eq 40 ] || [ "${#report_hash}" -eq 64 ] || return 1
    tail -n +2 "$file" > "$work/report" || return 1
    actual="$(git hash-object --stdin < "$work/report")" || return 1
    [ "$actual" = "$report_hash" ] || return 1
    grep -q '^IS_STATUS=ok\($\| \)' "$work/report" || return 1
    grep -q '^=== Done:' "$work/report" || return 1
}

# Keep actionable diagnostics, including the multi-line unsynced-directory
# report that compact mode intentionally omits. Never replay renderer progress.
sync_cache_report() {
    awk '
        /^(WARNING:|  WARN:)/ { warning=1; print; next }
        warning && /^    / { print; next }
        { warning=0 }
        /^(CONTEXT:|IS_STATUS=ok|=== Done:|=== WARNING:|  NOT SYNCED:|  Wire one in:)/ { print }
    ' "$1"
}

sync_with_cache() (
    local target="$1" force="$2" work before after outputs report_hash rc=0 cacheable=0
    work="$(mktemp -d -t intelligence-cache-XXXXXX)" || return 1
    trap 'rm -rf "$work"' EXIT
    echo "Checking source files..."
    # Read once here so both input hashes, one in a background job, reuse it.
    SC_UMASK="$(umask)"
    if sync_cache_dependencies && sync_cache_directory; then
        before="$(sync_cache_input_hash "$work" "$target")" || before=""
        [ -z "$before" ] || cacheable=1
    fi
    if [ "$cacheable" = 1 ] && [ "$force" = 0 ]; then
        echo "Checking generated files..."
        outputs="$(sync_cache_fingerprint "$work" "${SC_OUTPUTS[@]}")" || outputs=""
        if [ -n "$outputs" ] && sync_cache_read "$SC_DIRECTORY/state" "$before" "$outputs" "$work"; then
            echo 'Unchanged: generated files are up to date.'
            printf '\n'
            cat "$work/report"
            printf '\n=== Unchanged: no files needed updating ===\n'
            return 0
        fi
    fi
    # A failed or interrupted attempt must not leave a success cache reusable.
    if [ "$cacheable" = 1 ]; then
        rm -f "$SC_DIRECTORY/state" || cacheable=0
    fi
    # Stream progress while retaining diagnostics for the next cache hit. Check
    # both processes: a failed capture must never publish a success record.
    local -a pipeline_status
    if bash "$IS_ENGINE_DIR/sync.sh" "$target" 2>&1 | tee "$work/log"; then
        pipeline_status=("${PIPESTATUS[@]}")
    else
        pipeline_status=("${PIPESTATUS[@]}")
    fi
    rc="${pipeline_status[0]}"
    [ "$rc" = 0 ] || return "$rc"
    [ "${pipeline_status[1]}" = 0 ] || return "${pipeline_status[1]}"
    if [ "$cacheable" = 1 ]; then
        (
            echo "Checking sync results..."
            # The input recheck and the output fingerprint only read files, so
            # they run side by side, each in its own scratch directory.
            local after_pid after_rc=0
            mkdir "$work/after" "$work/outputs" || return 0
            sync_cache_input_hash "$work/after" "$target" > "$work/after/hash" &
            after_pid=$!
            outputs="$(sync_cache_fingerprint "$work/outputs" "${SC_OUTPUTS[@]}")" || outputs=""
            sync_cache_report "$work/log" > "$work/report" || outputs=""
            report_hash="$(git hash-object --stdin < "$work/report")" || outputs=""
            wait "$after_pid" || after_rc=$?
            [ "$after_rc" = 0 ] && [ -n "$outputs" ] || return 0
            IFS= read -r after < "$work/after/hash" || return 0
            [ "$before" = "$after" ] || return 0
            # Recheck containment before publishing. mktemp+rename avoids following a
            # pre-existing state-file link, and readers see only complete records.
            sync_cache_directory create || return 0
            local staged
            staged="$(mktemp "$SC_DIRECTORY/state-XXXXXX")" || return 0
            if { printf 'intelligence-sync-cache-v1 %s %s %s\n' "$after" "$outputs" "$report_hash"; cat "$work/report"; } > "$staged"; then
                mv -f "$staged" "$SC_DIRECTORY/state" || rm -f "$staged"
            else
                rm -f "$staged"
            fi
        )
    fi
    echo "=== Sync complete ==="
    return 0
)
