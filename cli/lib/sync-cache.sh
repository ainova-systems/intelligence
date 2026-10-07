#!/bin/bash
# Optional CLI optimization. Cache data never supplies paths or executable code:
# every dependency is derived again from the manifest and built-in contracts.
#
# The record keeps three fingerprints apart (decision 0018), so a check can say
# which side moved:
#   tooling  the CLI and engine code, plus the invocation and environment that
#            shape rendering — target filter, root, layout, bash, locale, PATH,
#            umask. A change here is not the project's: a check renders rather
#            than answer "sync needed" from it.
#   inputs   the manifest, the lock, every configured source including skill
#            resources and installed packages, and the project adapter folder.
#   outputs  every path the enabled built-in adapters own or manage.
# Each fingerprint lists names, entry kinds and executable state beside content
# hashes; timestamps never count. `.intelligence/sync-cache/state` holds the
# record and the report a hit replays; `seal` holds the state file's own hash,
# so a record is trusted only whole.

SC_FORMAT='intelligence-sync-cache-v2'
SC_SAFE_SEEN=$'\n'

sync_cache_safe_path() {
    local path="$1" probe="$1"
    case "$path" in *[[:cntrl:]]*|*\\*|*\"*) return 1 ;; esac
    # Include ancestors: find does not report a link above its starting path.
    # Start points share most ancestors, so each one is probed once per run.
    while [ -n "$probe" ] && [ "$probe" != / ]; do
        case "$probe" in "$REPO_ROOT"|"$CLI_DIR"|"$IS_ENGINE_DIR") break ;; esac
        case "$SC_SAFE_SEEN" in *$'\n'"$probe"$'\n'*) break ;; esac
        [ ! -L "$probe" ] || return 1
        SC_SAFE_SEEN="$SC_SAFE_SEEN$probe"$'\n'
        probe="${probe%/*}"
    done
}

# --- Native paths for Git for Windows --------------------------------------
# Git for Windows does not translate POSIX paths it reads from stdin. cygpath
# would, at the price of a process; the mount table it consults is readable in
# this shell. Only paths under a listed mount other than `/` are translated
# here — `/` also stands for drives mounted on demand — and any other path sends
# the whole list through cygpath. The same table answers two more questions:
#   - whether executable bits are real: on a `noacl` mount Cygwin derives them
#     from a file's name and first bytes, which the content hash already covers,
#     so asking find for them would only add a stat per file;
#   - whether find's order is already stable: NTFS lists a directory from its
#     name-collated index, so the same tree always walks in the same order and
#     the sort that other filesystems need can be skipped.
SC_MOUNTS_READ=0
SC_MOUNT_POSIX=()
SC_MOUNT_NATIVE=()
SC_MOUNT_TYPE=()
SC_EXEC_PROBE=1
SC_TRANSLATE=0

sync_cache_mounts() {
    [ "$SC_MOUNTS_READ" = 0 ] || return 0
    SC_MOUNTS_READ=1
    case "${OSTYPE:-}" in
        msys*|cygwin*) ;;
        *)
            command -v cygpath >/dev/null 2>&1 && SC_TRANSLATE=2
            return 0
            ;;
    esac
    SC_TRANSLATE=2
    local native posix type options _rest acl=0 lines=0
    [ -r /proc/mounts ] || return 0
    while read -r native posix type options _rest; do
        lines=$((lines + 1))
        case "$options" in *noacl*) ;; *) acl=1 ;; esac
        case "$native$posix" in *\\*)
            native="${native//\\040/ }" posix="${posix//\\040/ }"
            case "$native$posix" in *\\*) continue ;; esac
            ;;
        esac
        [ "$posix" != / ] || continue
        SC_MOUNT_POSIX+=("$posix")
        SC_MOUNT_NATIVE+=("$native")
        SC_MOUNT_TYPE+=("$type")
    done < /proc/mounts
    [ "$lines" -gt 0 ] || return 0
    [ "$acl" = 1 ] || SC_EXEC_PROBE=0
    [ "${#SC_MOUNT_POSIX[@]}" -eq 0 ] || SC_TRANSLATE=1
}

# sync_cache_mount_var <absolute-path> — IS_SC_MOUNT, the index of the longest
# listed mount holding the path; return 1 when none does.
sync_cache_mount_var() {
    local i=0 length=0 mount
    IS_SC_MOUNT=-1
    while [ "$i" -lt "${#SC_MOUNT_POSIX[@]}" ]; do
        mount="${SC_MOUNT_POSIX[$i]}"
        case "$1" in
            "$mount"|"$mount"/*)
                if [ "${#mount}" -gt "$length" ]; then IS_SC_MOUNT="$i"; length="${#mount}"; fi
                ;;
        esac
        i=$((i + 1))
    done
    [ "$IS_SC_MOUNT" -ge 0 ]
}

# sync_cache_native_var <absolute-path> — IS_SC_NATIVE, or return 1 when only
# cygpath can say.
sync_cache_native_var() {
    sync_cache_mount_var "$1" || return 1
    IS_SC_NATIVE="${SC_MOUNT_NATIVE[$IS_SC_MOUNT]}${1:${#SC_MOUNT_POSIX[$IS_SC_MOUNT]}}"
}

# --- Dependencies ------------------------------------------------------------
sync_cache_dependencies() {
    local src section adapter file output _adapter kind value
    local -a batch=()
    SC_TOOLING=("$CLI_DIR/intelligence" "$CLI_DIR/engine-package.yaml"
        "$CLI_DIR/commands" "$CLI_DIR/internal" "$CLI_DIR/lib" "$IS_ENGINE_DIR")
    SC_INPUTS=("$CONFIG_FILE" "$REPO_ROOT/intelligence.lock"
        "$REPO_ROOT/$IS_CONTENT_REL/adapters")
    SC_OUTPUTS=()
    # Project adapters can read arbitrary files or environment and execute any
    # code. Their dependencies cannot be inferred from their write contract.
    for file in "$REPO_ROOT/$IS_CONTENT_REL/adapters"/*.sh; do
        [ ! -e "$file" ] && [ ! -L "$file" ] || return 1
    done
    # The engine's list parser hands a package reference (decision 0019) over
    # as the store path sync renders from, and leaves out one that resolves to
    # nothing; only the manifest, an input itself, decides which.
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
        batch+=("$adapter" "$file" "$output")
    done
    [ "${#batch[@]}" -gt 0 ] || return 1
    # Every enabled contract in one subshell: two forks per adapter were most of
    # this step on Windows.
    adapter_contract_records_batch "$SC_SCRATCH.contract" "${batch[@]}" > "$SC_SCRATCH.records" || return 1
    while IFS=$'\t' read -r _adapter kind value; do
        case "$kind" in owned|managed) SC_OUTPUTS+=("$REPO_ROOT/$value") ;; esac
    done < "$SC_SCRATCH.records"
    [ "${#SC_OUTPUTS[@]}" -gt 0 ]
}

# --- Fingerprint ---------------------------------------------------------------
# _sync_cache_starts <group> <path>... — queue a group's start points. A missing
# one is recorded as missing; a repeated one is walked once.
_sync_cache_starts() {
    local group="$1" path
    shift
    for path in "$@"; do
        sync_cache_safe_path "$path" || return 1
        case "$SC_START_SEEN" in
            *$'\n'"$group $path"$'\n'*) continue ;;
            *$'\n'?" $path"$'\n'*) return 1 ;;
        esac
        SC_START_SEEN="$SC_START_SEEN$group $path"$'\n'
        if [ -e "$path" ]; then
            SC_STARTS+=("$path")
            SC_START_GROUPS+=("$group")
        else
            SC_MISSING+=("$group missing $path")
        fi
    done
}

# The listing stage of the fingerprint pipeline. It reads find's output, tells
# kinds from repeats, files every entry under its start point's group and
# writes the three listings, each on one line, plus the file counts, to
# SC_AWK_LISTING. On stdout it prints the paths to hash for git, grouped
# tooling, inputs, outputs, then the state file: one hash per path comes back
# in that order. Any entry it cannot place fails the whole pipeline.
# When the walk itself arrives grouped (SC_AWK_STREAM=1: unsorted, start points
# in group order) each path goes to git as soon as it is placed, so hashing runs
# beside the walk; a group that comes back after a later one fails the run.
_SC_AWK_LISTING='
    BEGIN {
        starts = split(ENVIRON["SC_AWK_STARTS"], rows, "\n")
        for (i = 1; i <= starts; i++) {
            split(rows[i], field, "\t")
            group[i] = field[1]; posix[i] = field[2]; native[i] = field[3]
        }
        probe = ENVIRON["SC_AWK_EXEC_PROBE"]
        stream = (ENVIRON["SC_AWK_STREAM"] == 1)
        rank["T"] = 1; rank["I"] = 2; rank["O"] = 3
    }
    function place(    kind, j, g, k, path) {
        if (count == 1) kind = "f"
        else if (count == 2) kind = "d"
        else if (count == 3 && probe == 1) kind = "x"
        else { bad = 1; return }
        if (!last || (entry != posix[last] && index(entry, posix[last] "/") != 1)) {
            last = 0
            for (j = 1; j <= starts; j++) {
                if (entry == posix[j] || index(entry, posix[j] "/") == 1) { last = j; break }
            }
            if (!last) { bad = 1; return }
        }
        g = group[last]
        listing[g] = listing[g] kind " " entry "\037"
        if (kind == "d") return
        k = ++files[g]
        path = native[last] substr(entry, length(posix[last]) + 1)
        if (!stream) { file[g, k] = path; return }
        if (rank[g] < current) { bad = 1; return }
        current = rank[g]
        print path
        fflush()
    }
    bad { next }
    $0 == entry { count++; next }
    entry != "" { place() }
    { entry = $0; count = 1 }
    END {
        if (entry != "" && !bad) place()
        if (bad) exit 1
        out = ENVIRON["SC_AWK_LISTING"]
        printf "T %s\nI %s\nO %s\nN %d %d %d\n", listing["T"], listing["I"], listing["O"], files["T"], files["I"], files["O"] > out
        n = split("T I O", order, " ")
        if (!stream) for (i = 1; i <= n; i++) for (k = 1; k <= files[order[i]]; k++) print file[order[i], k]
        if (ENVIRON["SC_AWK_STATE"] != "") print ENVIRON["SC_AWK_STATE"]
    }
'

# sync_cache_fingerprint <target> — one walk and one batch hash over every
# tooling, input and output path, into SC_PRINT_T, SC_PRINT_I and SC_PRINT_O.
# The cache state file joins the batch, so SC_STATE_HASH can be checked against
# its seal without another process. Unsupported paths or entry kinds return 1:
# an incomplete fingerprint must never be compared.
#
# One pipeline does the work: find lists every entry and refuses what cannot be
# fingerprinted — links and other special files, and names holding a control
# character, a backslash or a double quote (every component of a walked path is
# a start point, checked above, or an entry find visits). Directories print
# twice and, where executable bits are real, executable files three times, so
# the listing stage tells kinds without a stat per entry. git hashes the files
# while the walk is still running.
sync_cache_fingerprint() {
    local target="$1" hashes i j n value ordered=0 starts_env="" state="" umask_value
    local tooling inputs outputs listing saved_ifs="$IFS"
    local -a hash_lines=() expression=() keep=() starts=() groups=() natives=() parts=() count=()
    SC_STARTS=() SC_START_GROUPS=() SC_MISSING=() SC_START_SEEN=$'\n'
    _sync_cache_starts T "${SC_TOOLING[@]}" || return 1
    _sync_cache_starts I "${SC_INPUTS[@]}" || return 1
    _sync_cache_starts O "${SC_OUTPUTS[@]}" || return 1
    # Nested start points would list one entry twice. Within a group the outer
    # one covers the inner; across groups the run is not fingerprinted.
    n="${#SC_STARTS[@]}"
    for ((i = 0; i < n; i++)); do
        keep[i]=1
        for ((j = 0; j < n; j++)); do
            [ "$i" != "$j" ] || continue
            case "${SC_STARTS[i]}" in
                "${SC_STARTS[j]}"/*)
                    [ "${SC_START_GROUPS[i]}" = "${SC_START_GROUPS[j]}" ] || return 1
                    keep[i]=0
                    ;;
            esac
        done
    done
    for ((i = 0; i < n; i++)); do
        [ "${keep[i]}" = 1 ] || continue
        starts+=("${SC_STARTS[i]}")
        groups+=("${SC_START_GROUPS[i]}")
    done
    SC_STATE_HASH=""
    if [ -n "${SC_DIRECTORY:-}" ] && [ -f "$SC_DIRECTORY/state" ] && [ ! -L "$SC_DIRECTORY/state" ]; then
        state="$SC_DIRECTORY/state"
    fi
    sync_cache_mounts
    # Translate each start point once; its entries share the prefix.
    if [ "$SC_TRANSLATE" = 1 ]; then
        ordered=1
        for ((j = 0; j < ${#starts[@]}; j++)); do
            if ! sync_cache_native_var "${starts[j]}"; then
                SC_TRANSLATE=2
                break
            fi
            natives[j]="$IS_SC_NATIVE"
            [ "${SC_MOUNT_TYPE[$IS_SC_MOUNT]}" = ntfs ] || ordered=0
        done
        if [ "$SC_TRANSLATE" = 1 ] && [ -n "$state" ]; then
            if sync_cache_native_var "$state"; then state="$IS_SC_NATIVE"; else SC_TRANSLATE=2; fi
        fi
    fi
    [ "$SC_TRANSLATE" = 1 ] || ordered=0
    for ((j = 0; j < ${#starts[@]}; j++)); do
        value="${starts[j]}"
        [ "$SC_TRANSLATE" != 1 ] || value="${natives[j]}"
        starts_env="$starts_env${groups[j]}"$'\t'"${starts[j]}"$'\t'"$value"$'\n'
    done
    starts_env="${starts_env%$'\n'}"
    expression=(\( ! -type d ! -type f -exec false {} + \)
        -o \( \( -name '*[[:cntrl:]]*' -o -name '*\\*' -o -name '*"*' \) -exec false {} + \)
        -o -type d -print -print)
    [ "$SC_EXEC_PROBE" = 0 ] || expression+=(-o -type f -perm -100 -print -print -print)
    expression+=(-o -print)
    if [ "${#starts[@]}" -gt 0 ]; then
        # The pipeline's stages run side by side, and pipefail reports any one
        # that refused; the listing stage rewrites its file whenever it succeeds.
        if [ "$ordered" = 1 ]; then
            # Start points are listed tooling, inputs, outputs, and an unsorted
            # walk visits them in that order: stream each file to git.
            hashes="$(LC_ALL=C find "${starts[@]}" "${expression[@]}" \
                | SC_AWK_STARTS="$starts_env" SC_AWK_EXEC_PROBE="$SC_EXEC_PROBE" SC_AWK_STREAM=1 \
                    SC_AWK_LISTING="$SC_SCRATCH.listing" SC_AWK_STATE="$state" LC_ALL=C awk "$_SC_AWK_LISTING" \
                | git hash-object --no-filters --stdin-paths)" || return 1
        elif [ "$SC_TRANSLATE" = 2 ]; then
            hashes="$(LC_ALL=C find "${starts[@]}" "${expression[@]}" | LC_ALL=C sort \
                | SC_AWK_STARTS="$starts_env" SC_AWK_EXEC_PROBE="$SC_EXEC_PROBE" \
                    SC_AWK_LISTING="$SC_SCRATCH.listing" SC_AWK_STATE="$state" LC_ALL=C awk "$_SC_AWK_LISTING" \
                | cygpath -m -f - | git hash-object --no-filters --stdin-paths)" || return 1
        else
            hashes="$(LC_ALL=C find "${starts[@]}" "${expression[@]}" | LC_ALL=C sort \
                | SC_AWK_STARTS="$starts_env" SC_AWK_EXEC_PROBE="$SC_EXEC_PROBE" \
                    SC_AWK_LISTING="$SC_SCRATCH.listing" SC_AWK_STATE="$state" LC_ALL=C awk "$_SC_AWK_LISTING" \
                | git hash-object --no-filters --stdin-paths)" || return 1
        fi
        [ -f "$SC_SCRATCH.listing" ] || return 1
        listing="$(< "$SC_SCRATCH.listing")"
    else
        listing=$'T \nI \nO \nN 0 0 0'
    fi
    IFS=$'\n'
    set -f
    # shellcheck disable=SC2206  # word splitting on newlines is the point
    parts=($listing)
    # shellcheck disable=SC2206
    hash_lines=($hashes)
    set +f
    IFS="$saved_ifs"
    [ "${#parts[@]}" -eq 4 ] || return 1
    case "${parts[3]}" in "N "*) ;; *) return 1 ;; esac
    read -r -a count <<< "${parts[3]#N }"
    n=$(( count[0] + count[1] + count[2] ))
    [ -z "$state" ] || n=$((n + 1))
    [ "${#hash_lines[@]}" -eq "$n" ] || return 1
    [ -z "$state" ] || SC_STATE_HASH="${hash_lines[n - 1]}"
    tooling="${parts[0]#T }" inputs="${parts[1]#I }" outputs="${parts[2]#O }"
    for value in "${SC_MISSING[@]+"${SC_MISSING[@]}"}"; do
        case "${value%% *}" in
            T) tooling="$tooling${value#* }"$'\037' ;;
            I) inputs="$inputs${value#* }"$'\037' ;;
            *) outputs="$outputs${value#* }"$'\037' ;;
        esac
    done
    [ "${count[0]}" -eq 0 ] || { printf -v value '%s\037' "${hash_lines[@]:0:${count[0]}}"; tooling="$tooling$value"; }
    [ "${count[1]}" -eq 0 ] || { printf -v value '%s\037' "${hash_lines[@]:${count[0]}:${count[1]}}"; inputs="$inputs$value"; }
    [ "${count[2]}" -eq 0 ] || { printf -v value '%s\037' "${hash_lines[@]:$((count[0] + count[1])):${count[2]}}"; outputs="$outputs$value"; }
    # Explicit values that affect rendering, discovery or parsing. No secrets
    # or inherited environment dump are persisted. umask prints into a file so
    # reading it costs no subshell.
    umask > "$SC_SCRATCH.umask" || return 1
    IFS= read -r umask_value < "$SC_SCRATCH.umask" || return 1
    for value in "$target" "$REPO_ROOT" "$CONFIG_FILE" "$IS_CONTENT_REL" "$IS_MODULE_REL" \
        "$IS_SYNC_CMD" "$IS_MANIFEST_NAME" "$IS_PROTECTED_DIRS" "$BASH_VERSION" "${OSTYPE:-}" \
        "${LANG:-}" "${LC_ALL:-}" "${LC_CTYPE:-}" "${LC_COLLATE:-}" "${PATH:-}" "$umask_value" \
        "exec-probe=$SC_EXEC_PROBE" "walk-ordered=$ordered"; do
        case "$value" in *[[:cntrl:]]*) return 1 ;; esac
        tooling="${tooling}env $value"$'\037'
    done
    SC_PRINT_T="T $tooling"
    SC_PRINT_I="I $inputs"
    SC_PRINT_O="O $outputs"
}

sync_cache_directory() {
    local path="$REPO_ROOT/.intelligence/sync-cache" physical root_physical probe expected
    SC_DIRECTORY=""
    sync_cache_safe_path "$path/state" || return 1
    # Reading is safe through the lexical check above: a record is data and
    # authorizes nothing unless it matches this run exactly. Writing must not
    # land outside the repository, so it also compares physical spellings.
    if [ "${1:-}" = create ]; then
        probe="$path"; expected="/.intelligence/sync-cache"
        while [ ! -e "$probe" ]; do probe="${probe%/*}"; expected="${expected%/*}"; done
        # Both physical spellings from one subshell.
        physical="$(cd "$REPO_ROOT" && pwd -P && cd "$probe" && pwd -P)" || return 1
        root_physical="${physical%%$'\n'*}"
        physical="${physical#*$'\n'}"
        [ "$physical" = "$root_physical$expected" ] || return 1
        mkdir -p "$path" || return 1
    fi
    SC_DIRECTORY="$path"
}

# sync_cache_read — load the sealed record into SC_RECORD_T / _I / _O and
# SC_RECORD_REPORT. Anything missing, unsealed, malformed or from another
# format is no record at all.
sync_cache_read() {
    local file="$SC_DIRECTORY/state" seal="" stored offset saved_ifs="$IFS"
    local -a fields=()
    SC_RECORD_T="" SC_RECORD_I="" SC_RECORD_O="" SC_RECORD_REPORT=""
    [ -n "$SC_STATE_HASH" ] || return 1
    [ -f "$SC_DIRECTORY/seal" ] && [ ! -L "$SC_DIRECTORY/seal" ] || return 1
    IFS= read -r seal < "$SC_DIRECTORY/seal" || return 1
    [ "$seal" = "$SC_STATE_HASH" ] || return 1
    stored="$(< "$file")" || return 1
    IFS=$'\n'
    set -f
    # shellcheck disable=SC2206
    fields=($stored)
    set +f
    IFS="$saved_ifs"
    [ "${#fields[@]}" -ge 6 ] || return 1
    [ "${fields[0]}" = "$SC_FORMAT" ] || return 1
    case "${fields[1]}" in "T "*) ;; *) return 1 ;; esac
    case "${fields[2]}" in "I "*) ;; *) return 1 ;; esac
    case "${fields[3]}" in "O "*) ;; *) return 1 ;; esac
    offset=$(( ${#fields[0]} + ${#fields[1]} + ${#fields[2]} + ${#fields[3]} + 4 ))
    SC_RECORD_T="${fields[1]}"
    SC_RECORD_I="${fields[2]}"
    SC_RECORD_O="${fields[3]}"
    SC_RECORD_REPORT="${stored:$offset}"
    case $'\n'"$SC_RECORD_REPORT"$'\n' in *$'\n'IS_STATUS=ok[$' \n']*) ;; *) return 1 ;; esac
    case $'\n'"$SC_RECORD_REPORT" in *$'\n''=== Done:'*) ;; *) return 1 ;; esac
}

# sync_cache_publish <report-file> — record the fingerprints taken after a
# successful render. Callers have checked that inputs and tooling did not move.
# mktemp+rename avoids following a pre-existing state-file link, and readers
# see only complete records; the seal follows the state it describes.
sync_cache_publish() {
    local report="$1" staged seal_staged hash
    sync_cache_directory create || return 0
    staged="$(mktemp "$SC_DIRECTORY/state-XXXXXX")" || return 0
    if ! { printf '%s\n' "$SC_FORMAT" "$SC_PRINT_T" "$SC_PRINT_I" "$SC_PRINT_O"; cat "$report"; } > "$staged"; then
        rm -f "$staged"
        return 0
    fi
    hash="$(git hash-object --no-filters "$staged")" || { rm -f "$staged"; return 0; }
    seal_staged="$staged.seal"
    printf '%s\n' "$hash" > "$seal_staged" || { rm -f "$staged" "$seal_staged"; return 0; }
    mv -f "$staged" "$SC_DIRECTORY/state" || { rm -f "$staged" "$seal_staged"; return 0; }
    mv -f "$seal_staged" "$SC_DIRECTORY/seal" || rm -f "$seal_staged"
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

# sync_cache_prepare <target> — dependencies, cache directory and fingerprint;
# returns 1 when this run cannot be fingerprinted.
sync_cache_prepare() {
    sync_cache_dependencies && sync_cache_directory && sync_cache_fingerprint "$1"
}

sync_with_cache() {
    local target="$1" force="$2" rc=0 cacheable=0 before_t before_i
    project_lock_scratch "$REPO_ROOT" || return 1
    SC_SCRATCH="$IS_LOCK_SCRATCH"
    echo "Checking source files..."
    if sync_cache_prepare "$target"; then
        cacheable=1
    fi
    if [ "$cacheable" = 1 ] && [ "$force" = 0 ]; then
        echo "Checking generated files..."
        if sync_cache_read && [ "$SC_RECORD_T" = "$SC_PRINT_T" ] && [ "$SC_RECORD_I" = "$SC_PRINT_I" ] \
            && [ "$SC_RECORD_O" = "$SC_PRINT_O" ]; then
            echo 'Unchanged: generated files are up to date.'
            printf '\n%s\n' "$SC_RECORD_REPORT"
            printf '\n=== Unchanged: no files needed updating ===\n'
            return 0
        fi
    fi
    # A failed or interrupted attempt must not leave a success cache reusable.
    if [ "$cacheable" = 1 ]; then
        rm -f "$SC_DIRECTORY/state" "$SC_DIRECTORY/seal" || cacheable=0
    fi
    before_t="${SC_PRINT_T:-}" before_i="${SC_PRINT_I:-}"
    # Stream progress while retaining diagnostics for the next cache hit. Check
    # both processes: a failed capture must never publish a success record.
    local -a pipeline_status
    if bash "$IS_ENGINE_DIR/sync.sh" "$target" 2>&1 | tee "$SC_SCRATCH.log"; then
        pipeline_status=("${PIPESTATUS[@]}")
    else
        pipeline_status=("${PIPESTATUS[@]}")
    fi
    rc="${pipeline_status[0]}"
    [ "$rc" = 0 ] || return "$rc"
    [ "${pipeline_status[1]}" = 0 ] || return "${pipeline_status[1]}"
    if [ "$cacheable" = 1 ]; then
        echo "Checking sync results..."
        # Recheck inputs after rendering (decision 0010): a change during the
        # run must not bless the outputs as current.
        if sync_cache_fingerprint "$target" && [ "$SC_PRINT_T" = "$before_t" ] \
            && [ "$SC_PRINT_I" = "$before_i" ] \
            && sync_cache_report "$SC_SCRATCH.log" > "$SC_SCRATCH.report"; then
            sync_cache_publish "$SC_SCRATCH.report"
        fi
    fi
    echo "=== Sync complete ==="
    return 0
}

# --- sync --check ----------------------------------------------------------------
# sync_check <target> <force> — 0 when generated files are what sync would
# leave, 2 when sync would change them (IS_CHECK_OUT_OF_DATE=1 marks that
# verdict, so the command can turn a failure that ends in 2 into 1), and the
# failure's own status otherwise. Prints one IS_STATUS line. A valid record
# from the same tooling answers without rendering; otherwise the engine renders
# inside its snapshot transaction, compares, restores every path, and a clean
# result is recorded so the next check is fast.
# shellcheck disable=SC2034  # IS_CHECK_OUT_OF_DATE is read by commands/sync.sh
sync_check() {
    local target="$1" force="$2" rc=0 cacheable=0 verdict="" sources=0 generated=0
    local before_t before_i before_o
    project_lock_scratch "$REPO_ROOT" || return 1
    SC_SCRATCH="$IS_LOCK_SCRATCH"
    if sync_cache_prepare "$target"; then
        cacheable=1
    fi
    if [ "$cacheable" = 1 ] && [ "$force" = 0 ] && sync_cache_read && [ "$SC_RECORD_T" = "$SC_PRINT_T" ]; then
        [ "$SC_RECORD_I" = "$SC_PRINT_I" ] || sources=1
        [ "$SC_RECORD_O" = "$SC_PRINT_O" ] || generated=1
        case "$sources$generated" in
            00) is_status ok "generated files are up to date"; return 0 ;;
            10) is_status out-of-date "sources changed since the last sync; run 'intelligence sync'" ;;
            01) is_status out-of-date "generated files changed since the last sync; run 'intelligence sync'" ;;
            *) is_status out-of-date "sources and generated files changed since the last sync; run 'intelligence sync'" ;;
        esac
        IS_CHECK_OUT_OF_DATE=1
        return "$IS_RC_OUT_OF_DATE"
    fi
    before_t="${SC_PRINT_T:-}" before_i="${SC_PRINT_I:-}" before_o="${SC_PRINT_O:-}"
    rm -f "$SC_SCRATCH.verdict"
    IS_SYNC_CHECK="$SC_SCRATCH.verdict" bash "$IS_ENGINE_DIR/sync.sh" "$target" > "$SC_SCRATCH.log" 2>&1 || rc=$?
    if [ "$rc" = 0 ]; then
        [ ! -f "$SC_SCRATCH.verdict" ] || IFS= read -r verdict < "$SC_SCRATCH.verdict" || verdict=""
        case "$verdict" in
            same|differs) ;;
            *) echo "ERROR: the engine rendered without reporting a comparison" >&2; rc=1 ;;
        esac
    fi
    if [ "$rc" != 0 ]; then
        cat "$SC_SCRATCH.log" >&2
        return "$rc"
    fi
    if [ "$verdict" = differs ]; then
        IS_CHECK_OUT_OF_DATE=1
        is_status out-of-date "rendering would change generated files; run 'intelligence sync'"
        return "$IS_RC_OUT_OF_DATE"
    fi
    # Publish under sync's rules: tooling and inputs unchanged by the run, and
    # outputs exactly as they were before it (the engine restored them).
    if [ "$cacheable" = 1 ] && sync_cache_fingerprint "$target" && [ "$SC_PRINT_T" = "$before_t" ] \
        && [ "$SC_PRINT_I" = "$before_i" ] && [ "$SC_PRINT_O" = "$before_o" ] \
        && sync_cache_report "$SC_SCRATCH.log" > "$SC_SCRATCH.report"; then
        sync_cache_publish "$SC_SCRATCH.report"
    fi
    is_status ok "generated files are up to date (rendered to compare)"
    return 0
}
