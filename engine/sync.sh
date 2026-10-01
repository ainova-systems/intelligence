#!/bin/bash
# intelligence-sync: the sync engine's entry point.
#
# The engine runs from outside the project (the CLI's install dir), so it never
# searches the filesystem for one: the project arrives through the environment,
# exported by `intelligence sync`.
#
#   CONFIG_FILE        the project's manifest (intelligence.yaml at the root)
#   REPO_ROOT          the project root
#   IS_CONTENT_REL     the project's content dir, repo-relative
#   IS_MODULE_REL      the installed sync package, repo-relative
#   IS_PROTECTED_DIRS  dirs an adapter output may never overlap
#
# Usage: intelligence sync [target]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/contract.sh"
source "$SCRIPT_DIR/lib/adapter-contract.sh"

if [ -z "${CONFIG_FILE:-}" ] || [ ! -f "${CONFIG_FILE:-}" ]; then
    is_status config-missing "CONFIG_FILE=${CONFIG_FILE:-}"
    echo "ERROR: the engine needs CONFIG_FILE to point at an existing manifest." >&2
    echo "       Run it through the CLI: intelligence sync" >&2
    exit "$IS_RC_CONFIG_MISSING"
fi

# Schema version lives in the manifest (the frozen contract key).
_cf="$CONFIG_FILE"

# Stale engine vs project schema stamped NEWER (ahead-of-engine): a newer
# major refuses, a newer minor/patch warns and renders (see contract.sh).
_vc_rc=0
check_version_compat "$_cf" || _vc_rc=$?
if [ "$_vc_rc" -ne 0 ]; then exit "$_vc_rc"; fi

# Schema gap → refuse. sync is a PURE synchronizer: it never changes schemas,
# so the CLI lifecycle preflight must align the project first. An ABSENT stamp
# means the same thing — a manifest with no
# `schema_version` must not silently sync past a schema change.
read_schema_version_var "$_cf"
_stamp="$IS_SCHEMA_VERSION"
engine_version_var
[ "$IS_ENGINE_VERSION_FOUND" = 1 ] || exit 1
_eng="$IS_ENGINE_VERSION"
if [ -z "$_stamp" ]; then
    is_status needs-update "stamped= engine=$_eng (no schema_version)"
    echo "ERROR: the manifest has no schema_version — schema un-applied." >&2
    echo "       Run: intelligence init --apply" >&2
    exit "$IS_RC_NEEDS_UPDATE"
elif [ -n "$_eng" ] && _ver_gt "$_eng" "$_stamp"; then
    is_status needs-update "stamped=$_stamp engine=$_eng"
    echo "ERROR: project at $_stamp but engine is $_eng — pending schema changes." >&2
    echo "       Run: intelligence init --apply" >&2
    exit "$IS_RC_NEEDS_UPDATE"
fi

# Normalize REPO_ROOT and CONFIG_FILE to one `cd && pwd` spelling so
# prefix-stripping in path comparisons works: Git Bash on Windows reaches the
# same location through `D:/...` and `/d/...`, and the CLI (or the Node shim
# behind it) may hand us either.
REPO_ROOT_RAW="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || dirname "$CONFIG_FILE")}"
REPO_ROOT="$(cd "$REPO_ROOT_RAW" && pwd)"
unset REPO_ROOT_RAW
case "$CONFIG_FILE" in
    */*) _cf_dir="${CONFIG_FILE%/*}"; [ -n "$_cf_dir" ] || _cf_dir="/" ;;
    *) _cf_dir="." ;;
esac
CONFIG_FILE="$(cd "$_cf_dir" && pwd)/${CONFIG_FILE##*/}"
unset _cf_dir

# Layout tokens for generated output (see finalize_output_file in common.sh).
# Package-shipped rules/agents cannot hardcode the content dir's name — the
# project chooses it — so they write `<content-dir>` / `<module>` and every adapter
# expands them on the way out.
IS_CONTENT_REL="${IS_CONTENT_REL:-intelligence}"
# No vendor default: the CLI always exports the package path (derived from its
# distribution data), so a bare invocation must say so rather than guess.
if [ -z "${IS_MODULE_REL:-}" ]; then
    echo "ERROR: the engine needs IS_MODULE_REL (exported by the intelligence CLI)." >&2
    exit 1
fi
export IS_CONTENT_REL IS_MODULE_REL

# Project-owned adapters live in the content dir: <content-dir>/adapters/.
INTELLIGENCE_DIR="$REPO_ROOT/$IS_CONTENT_REL"

TARGET_FILTER="${1:-}"

echo "=== intelligence-sync ==="
echo "  Config: $CONFIG_FILE"
echo "  Root:   $REPO_ROOT"
echo ""

# The engine never mutates the manifest, so parse its hot sections exactly
# once: every later read_yaml_list / target lookup — in this process and in
# adapter process substitutions — hits the in-memory copy instead of
# spawning awk.
load_targets_cache "$CONFIG_FILE"
load_yaml_lists "$CONFIG_FILE" rules agents skills ignore submodules

# Lint frontmatter across all source files (rules, agents, skills).
# Catches issues like unquoted colons that strict YAML consumers reject.
LINT_FILES=()
LINT_SKILL_DIRS=()
for section in rules agents skills; do
    load_yaml_list "$CONFIG_FILE" "$section"
    while IFS= read -r src; do
        [ -z "$src" ] && continue
        src_dir="$REPO_ROOT/$src"
        [ -d "$src_dir" ] || continue
        if [ "$section" = "skills" ]; then
            LINT_SKILL_DIRS+=("$src_dir")
        else
            for f in "$src_dir"/*.md; do
                [ -f "$f" ] && LINT_FILES+=("$f")
            done
        fi
    done <<< "$IS_YAML_LIST"
done
# One find for every skills source: it walks its start points in order.
if [ "${#LINT_SKILL_DIRS[@]}" -gt 0 ]; then
    while IFS= read -r f; do
        [ -n "$f" ] && LINT_FILES+=("$f")
    done < <(find "${LINT_SKILL_DIRS[@]}" -mindepth 2 -maxdepth 2 -name 'SKILL.md' 2>/dev/null)
fi
if [ "${#LINT_FILES[@]}" -gt 0 ]; then
    lint_frontmatter_files "${LINT_FILES[@]}"
fi

# Sources stay read-only for the whole run (validate_output_path refuses an
# output inside one), so read_source_artifact_files enumerates each section
# once, in this shell, and its later callers — the agents adapter, the shared
# skill directory, the context report — replay it. Adapters that list sources
# with in-shell globs spawn nothing and keep their own, locale-ordered listing.
# shellcheck disable=SC2034  # read by read_source_artifact_files in lib/common.sh
IS_SOURCE_FILES_MEMO=1
for section in rules agents skills; do
    read_source_artifact_files "$REPO_ROOT" "$CONFIG_FILE" "$section"
done

# Adapters come from two places, discovered by filename (minus `.sh`,
# `_template` excluded):
#
#   1. Built-in   — shipped inside the CLI, replaced with each CLI installation
#   2. Project    — <content-dir>/adapters/, owned by the project and never touched
#
# A custom adapter therefore belongs in the content dir's `adapters/`; the
# built-in directory lives inside the installed CLI and is not the project's to
# edit. A project adapter whose name matches a built-in overrides it (an escape
# hatch for patching a built-in without forking — announced, never silent).
ADAPTERS=()
ADAPTER_FILES=()

register_adapter() {
    local name="$1" file="$2"
    local n=${#ADAPTERS[@]} i=0
    while [ "$i" -lt "$n" ]; do
        if [ "${ADAPTERS[$i]}" = "$name" ]; then
            ADAPTER_FILES[$i]="$file"
            echo "  NOTE: project adapter '$name' overrides the built-in one ($(basename "$INTELLIGENCE_DIR")/adapters/$(basename "$file"))"
            return 0
        fi
        i=$((i + 1))
    done
    ADAPTERS+=("$name")
    ADAPTER_FILES+=("$file")
}

for adapters_dir in "$SCRIPT_DIR/adapters" "$INTELLIGENCE_DIR/adapters"; do
    [ -d "$adapters_dir" ] || continue
    for adapter_file in "$adapters_dir"/*.sh; do
        [ -f "$adapter_file" ] || continue
        adapter_name="${adapter_file##*/}"
        adapter_name="${adapter_name%.sh}"
        [ "$adapter_name" = "_template" ] && continue
        register_adapter "$adapter_name" "$adapter_file"
    done
done

# Validate every selected adapter contract before any output is touched, then
# snapshot the declared write-set. If a later adapter fails, the EXIT handler
# restores all earlier adapter outputs so sync is atomic from the repository's
# point of view.
SYNC_TX_DIR="$(mktemp -d -t intelligence-sync-XXXXXX)"
SYNC_TX_INDEX="$SYNC_TX_DIR/paths.tsv"
mkdir -p "$SYNC_TX_DIR/data"
: > "$SYNC_TX_INDEX"
SYNC_TX_ACTIVE=0
SYNC_TX_SEEN_LIST=$'\n'
SYNC_TX_COUNT=0

# Independent work runs concurrently unless INTELLIGENCE_SYNC_SERIAL=1 asks for
# the one-at-a-time order every earlier engine used (decision 0011). Every
# background job is listed in SYNC_BG_PIDS so an early exit stops it before
# anything is restored or removed.
SYNC_PARALLEL=1
[ "${INTELLIGENCE_SYNC_SERIAL:-0}" != "1" ] || SYNC_PARALLEL=0
SYNC_BG_PIDS=()
SYNC_COPY_INDEXES=()

snapshot_sync_path() {
    local adapter_name="$1" rel="$2" src index present=0
    case "$SYNC_TX_SEEN_LIST" in
        *$'\n'"$rel"$'\n'*) return 0 ;;
    esac
    SYNC_TX_SEEN_LIST="$SYNC_TX_SEEN_LIST$rel"$'\n'
    validate_output_path "$REPO_ROOT" "$CONFIG_FILE" "$adapter_name" "$REPO_ROOT/$rel"
    index="$SYNC_TX_COUNT"
    src="$REPO_ROOT/$rel"
    if [ -e "$src" ] || [ -L "$src" ]; then
        # Copies of distinct paths into distinct slots: they can overlap, and
        # The snapshot wait before the render collects every status.
        if [ "$SYNC_PARALLEL" = 1 ]; then
            cp -a "$src" "$SYNC_TX_DIR/data/$index" 2> "$SYNC_TX_DIR/copy.$index.err" &
            SYNC_BG_PIDS+=("$!")
            SYNC_COPY_INDEXES+=("$index")
        else
            cp -a "$src" "$SYNC_TX_DIR/data/$index"
        fi
        present=1
    fi
    printf '%s\t%s\t%s\n' "$index" "$rel" "$present" >> "$SYNC_TX_INDEX"
    SYNC_TX_COUNT=$((SYNC_TX_COUNT + 1))
}

restore_sync_snapshot() {
    local index rel present dst
    while IFS=$'\t' read -r index rel present; do
        [ -n "$rel" ] || continue
        dst="$REPO_ROOT/$rel"
        rm -rf "$dst"
        if [ "$present" = "1" ]; then
            mkdir -p "$(dirname "$dst")"
            cp -a "$SYNC_TX_DIR/data/$index" "$dst"
        fi
    done < "$SYNC_TX_INDEX"
}

# stop_sync_jobs — reap every background job before restoring or removing
# anything, so no copy or adapter can write after that point. It waits rather
# than kills: killing a job's shell would leave its cp or awk still writing.
# Ctrl-C already reaches every job through the terminal's process group.
stop_sync_jobs() {
    local pid
    for pid in "${SYNC_BG_PIDS[@]+"${SYNC_BG_PIDS[@]}"}"; do
        wait "$pid" 2>/dev/null
    done
    SYNC_BG_PIDS=()
}

# wait_sync_jobs — collect every background job's status; the first failure
# becomes this shell's, as it would have had the work run in the foreground.
wait_sync_jobs() {
    local pid rc=0 first=0
    for pid in "${SYNC_BG_PIDS[@]+"${SYNC_BG_PIDS[@]}"}"; do
        rc=0
        wait "$pid" || rc=$?
        [ "$first" -ne 0 ] || first="$rc"
    done
    SYNC_BG_PIDS=()
    return "$first"
}

finish_sync_transaction() {
    local rc=$?
    trap - EXIT INT TERM
    set +e
    stop_sync_jobs
    if [ "${SYNC_TX_ACTIVE:-0}" = "1" ] && [ "$rc" -ne 0 ]; then
        restore_sync_snapshot
        echo "ERROR: sync failed; all adapter-owned paths were restored to their pre-sync state." >&2
    fi
    rm -rf "$SYNC_TX_DIR"
    exit "$rc"
}
trap finish_sync_transaction EXIT
trap 'exit 130' INT TERM

# Ownership is checked across EVERY enabled adapter, not only the selected one:
# `intelligence sync codex` still prunes a path another adapter owns, so a
# filtered run that skipped the check would be the one that destroys output.
adapter_claims_reset
agents_dependents=""

# note_agents_dependent <adapter> — collect the AGENTS.md consumers for the
# root-path warning below. The list is built with its separators so no pattern
# substitution is needed: Bash 3.2 is the floor, and its ${v//} keeps the
# backslash of an escaped separator.
note_agents_dependent() {
    [ -n "$agents_dependents" ] && agents_dependents="$agents_dependents, "
    agents_dependents="$agents_dependents$1"
}
SELECTED_RECORDS=()
RENDER_PARALLEL="$SYNC_PARALLEL"
preflight_idx=0
while [ "$preflight_idx" -lt "${#ADAPTERS[@]}" ]; do
    adapter="${ADAPTERS[$preflight_idx]}"
    adapter_file="${ADAPTER_FILES[$preflight_idx]}"
    preflight_idx=$((preflight_idx + 1))
    target_enabled_var "$CONFIG_FILE" "$adapter"
    [ "$IS_TGT_ENABLED" = "1" ] || continue
    target_output_var "$CONFIG_FILE" "$adapter"
    output="$IS_TGT_OUTPUT"
    [ -n "$output" ] || output=".$adapter"
    records="$(adapter_contract_records "$adapter" "$adapter_file" "$output")" || exit 1

    if ! adapter_claims_add_records "$adapter" "$records"; then
        echo "ERROR: $IS_ADAPTER_CLAIM_CONFLICT." >&2
        echo "       Give each adapter its own output: intelligence adapter list" >&2
        exit 1
    fi

    if [ -n "$TARGET_FILTER" ] && [ "$adapter" != "$TARGET_FILTER" ]; then
        # Not selected: its claims are registered, its output is not touched.
        while IFS=$'\t' read -r kind value; do
            [ "$kind" = "requires" ] && [ "$value" = "agents" ] && note_agents_dependent "$adapter"
        done <<< "$records"
        continue
    fi

    validate_output_path "$REPO_ROOT" "$CONFIG_FILE" "$adapter" "$REPO_ROOT/$output"
    # The scheduler below reads ownership and requirements from these records.
    # A project adapter is executable code whose reads no contract declares, so
    # its presence keeps the whole render serial.
    SELECTED_RECORDS+=("$records")
    case "$adapter_file" in
        "$SCRIPT_DIR/adapters/"*) ;;
        *) RENDER_PARALLEL=0 ;;
    esac
    while IFS=$'\t' read -r kind value; do
        [ "$kind" = "requires" ] || continue
        [ "$value" = "agents" ] && note_agents_dependent "$adapter"
        target_enabled_var "$CONFIG_FILE" "$value"
        if [ "$IS_TGT_ENABLED" != "1" ]; then
            echo "ERROR: targets.$adapter requires enabled target '$value'." >&2
            echo "       Enable it first: intelligence adapter enable $value" >&2
            exit 1
        fi
    done <<< "$records"
    while IFS=$'\t' read -r kind value; do
        case "$kind" in
            owned|managed) snapshot_sync_path "$adapter" "$value" ;;
        esac
    done <<< "$records"
done

# Every adapter that requires `agents` skips always-on rules because AGENTS.md
# carries them — and each of those tools reads AGENTS.md at the workspace root
# only. Rendered anywhere else, the always-on rules reach no tool at all, and a
# stale root copy from an earlier run is what they keep reading.
if [ -n "$agents_dependents" ]; then
    target_output_var "$CONFIG_FILE" "agents"
    # Resolved, not lexical: `./` renders `./AGENTS.md`, which IS the
    # workspace-root file every dependent adapter reads.
    agents_output_path_var "${IS_TGT_OUTPUT:-.agents}"
    adapter_contract_rel_path "$IS_AGENTS_OUTPUT_PATH"
    agents_rel="$IS_ADAPTER_REL_PATH"
    if [ "$agents_rel" != "AGENTS.md" ]; then
        echo "WARNING: targets.agents.output renders '$agents_rel', not the workspace-root AGENTS.md. These adapters skip always-on rules because AGENTS.md carries them, and they read it at the root only: $agents_dependents. No tool loads those rules from '$agents_rel'." >&2
    fi
fi
# Every snapshot copy has landed before any adapter writes. Their diagnostics
# print in path order once all have finished, so a failed copy reads the same
# whichever finished first; it reports after preflight checked every adapter,
# where the serial order stopped at that adapter (decision 0011).
snapshot_rc=0
wait_sync_jobs || snapshot_rc=$?
for index in "${SYNC_COPY_INDEXES[@]+"${SYNC_COPY_INDEXES[@]}"}"; do
    [ ! -s "$SYNC_TX_DIR/copy.$index.err" ] || cat "$SYNC_TX_DIR/copy.$index.err" >&2
done
[ "$snapshot_rc" -eq 0 ] || exit "$snapshot_rc"
SYNC_TX_ACTIVE=1

# The run list: selected, enabled adapters in discovery order, refused with the
# same messages the one-at-a-time loop gave. Preflight validated every output.
RUN_NAMES=()
RUN_FILES=()
RUN_DIRS=()
adapter_count=${#ADAPTERS[@]}
adapter_idx=0

while [ "$adapter_idx" -lt "$adapter_count" ]; do
    adapter="${ADAPTERS[$adapter_idx]}"
    adapter_file="${ADAPTER_FILES[$adapter_idx]}"
    adapter_idx=$((adapter_idx + 1))

    # Skip if user requested specific target and this isn't it
    if [ -n "$TARGET_FILTER" ] && [ "$adapter" != "$TARGET_FILTER" ]; then
        continue
    fi

    # Check if target is enabled in config
    target_enabled_var "$CONFIG_FILE" "$adapter"
    enabled="$IS_TGT_ENABLED"
    if [ "$enabled" != "1" ]; then
        if [ -n "$TARGET_FILTER" ]; then
            echo "ERROR: Adapter '$TARGET_FILTER' is disabled in $CONFIG_FILE." >&2
            echo "       Enable it first: intelligence adapter enable $TARGET_FILTER" >&2
            exit 1
        fi
        continue
    fi

    # Get output directory
    target_output_var "$CONFIG_FILE" "$adapter"
    output="$IS_TGT_OUTPUT"
    if [ -z "$output" ]; then
        output=".$adapter"
    fi
    output_dir="$REPO_ROOT/$output"

    # Refuse to run if the output would clobber content — `output: "."`,
    # `output: "intelligence"`, or a `../` path that escapes the repo. Applies
    # to EVERY adapter, `agents` included: dir-writing adapters `rm -rf` their
    # output, and `agents` overwrites whatever single file it is handed. Both
    # turn a bad config line into a destructive write.
    validate_output_path "$REPO_ROOT" "$CONFIG_FILE" "$adapter" "$output_dir"
    RUN_NAMES+=("$adapter")
    RUN_FILES+=("$adapter_file")
    RUN_DIRS+=("$output_dir")
done
synced=${#RUN_NAMES[@]}

# run_adapter <index> — source one adapter and render it.
run_adapter() {
    # shellcheck source=/dev/null
    source "${RUN_FILES[$1]}"
    "sync_to_${RUN_NAMES[$1]}" "$REPO_ROOT" "$CONFIG_FILE" "${RUN_DIRS[$1]}"
    echo ""
}

# managed_paths_meet <a> <b> — two resolved paths are one tree: equal, or one
# inside the other.
managed_paths_meet() {
    [ "$1" = "$2" ] && return 0
    case "$1" in "$2"/*) return 0 ;; esac
    case "$2" in "$1"/*) return 0 ;; esac
    return 1
}

# plan_concurrent_render — fill RUN_CHAIN (each adapter's chain, named by its
# first member) and CHAIN_WAVE (when that chain may start), from the contract
# records preflight kept. Adapters that manage one tree form a chain and run in
# list order inside one job: they share that tree, and sync_open_skill_dirs
# replays the first one's work in the same shell. An adapter that requires
# another starts in a later wave than the chain holding it — Codex reads the
# rendered AGENTS.md. Returns 1 when no safe plan exists; the render is then
# serial.
plan_concurrent_render() {
    local n="$synced" i j k kind value old value_chain
    local -a paths=() path_chain=()
    [ "${#SELECTED_RECORDS[@]}" -eq "$n" ] || return 1
    RUN_CHAIN=()
    CHAIN_WAVE=()
    for ((i = 0; i < n; i++)); do
        RUN_CHAIN[i]=$i
        CHAIN_WAVE[i]=0
    done
    for ((i = 0; i < n; i++)); do
        while IFS=$'\t' read -r kind value; do
            [ "$kind" = managed ] || continue
            normalize_path_var "$REPO_ROOT/$value"
            value="$IS_NORM_PATH"
            for ((k = 0; k < ${#paths[@]}; k++)); do
                managed_paths_meet "${paths[k]}" "$value" || continue
                old="${RUN_CHAIN[i]}"
                [ "$old" != "${path_chain[k]}" ] || continue
                # Merge into the chain whose first member comes earlier.
                if [ "$old" -lt "${path_chain[k]}" ]; then
                    old="${path_chain[k]}"
                    value_chain="${RUN_CHAIN[i]}"
                else
                    value_chain="${path_chain[k]}"
                fi
                for ((j = 0; j < n; j++)); do
                    [ "${RUN_CHAIN[j]}" != "$old" ] || RUN_CHAIN[j]="$value_chain"
                done
                for ((j = 0; j < ${#paths[@]}; j++)); do
                    [ "${path_chain[j]}" != "$old" ] || path_chain[j]="$value_chain"
                done
            done
            paths+=("$value")
            path_chain+=("${RUN_CHAIN[i]}")
        done <<< "${SELECTED_RECORDS[i]}"
    done
    # Relax requirement edges; a plan still moving after n rounds has a cycle.
    local round changed want
    for ((round = 0; round <= n; round++)); do
        changed=0
        for ((i = 0; i < n; i++)); do
            while IFS=$'\t' read -r kind value; do
                [ "$kind" = requires ] || continue
                for ((j = 0; j < n; j++)); do
                    [ "${RUN_NAMES[j]}" = "$value" ] || continue
                    [ "${RUN_CHAIN[j]}" != "${RUN_CHAIN[i]}" ] || continue
                    want=$(( CHAIN_WAVE[RUN_CHAIN[j]] + 1 ))
                    if [ "${CHAIN_WAVE[RUN_CHAIN[i]]}" -lt "$want" ]; then
                        CHAIN_WAVE[RUN_CHAIN[i]]="$want"
                        changed=1
                    fi
                done
            done <<< "${SELECTED_RECORDS[i]}"
        done
        [ "$changed" = 1 ] || return 0
    done
    return 1
}

# render_concurrently — run each wave's chains as background jobs, one output
# buffer per adapter. Buffers print in list order as soon as every earlier
# adapter's has printed, so progress still streams adapter by adapter. A failed
# adapter ends the run with its own status after the buffers of the adapters
# that completed before it in the list; the EXIT handler then restores every
# snapshot, exactly as when the adapters ran one at a time.
render_concurrently() {
    local n="$synced" buf="$SYNC_TX_DIR/out" wave last_wave=0 c k pid rc
    local printed=0 failed=-1 failed_rc=0
    local -a wave_pids=() wave_chains=() files=() job_rc=()
    mkdir -p "$buf"
    for ((c = 0; c < n; c++)); do
        [ "${CHAIN_WAVE[c]}" -le "$last_wave" ] || last_wave="${CHAIN_WAVE[c]}"
    done
    for ((wave = 0; wave <= last_wave; wave++)); do
        wave_pids=()
        wave_chains=()
        for ((c = 0; c < n; c++)); do
            [ "${RUN_CHAIN[c]}" = "$c" ] && [ "${CHAIN_WAVE[c]}" = "$wave" ] || continue
            (
                for ((k = 0; k < n; k++)); do
                    [ "${RUN_CHAIN[k]}" = "$c" ] || continue
                    run_adapter "$k" > "$buf/$k" 2>&1
                    : > "$buf/$k.ok"
                done
            ) &
            wave_pids+=("$!")
            wave_chains+=("$c")
            SYNC_BG_PIDS+=("$!")
        done
        for ((k = 0; k < ${#wave_pids[@]}; k++)); do
            rc=0
            wait "${wave_pids[k]}" || rc=$?
            job_rc[wave_chains[k]]="$rc"
            # Stream while the wave runs: every buffer whose predecessors have
            # all printed goes out now. Only completed adapters are marked, so
            # nothing printed here can precede a failure in list order.
            files=()
            while [ "$printed" -lt "$n" ] && [ -f "$buf/$printed.ok" ]; do
                files+=("$buf/$printed")
                printed=$((printed + 1))
            done
            [ "${#files[@]}" -eq 0 ] || cat "${files[@]}"
        done
        SYNC_BG_PIDS=()
        # The first adapter in list order that started and did not finish.
        for ((k = 0; k < n; k++)); do
            if [ -f "$buf/$k" ] && [ ! -f "$buf/$k.ok" ]; then
                failed=$k
                failed_rc="${job_rc[RUN_CHAIN[k]]:-1}"
                [ "$failed_rc" != 0 ] || failed_rc=1
                break
            fi
        done
        # A job that failed before its adapter's buffer existed still fails
        # the run, charged to the first member of that chain not marked done.
        if [ "$failed" -lt 0 ]; then
            for ((k = 0; k < ${#wave_chains[@]}; k++)); do
                rc="${job_rc[wave_chains[k]]}"
                [ "$rc" = 0 ] && continue
                for ((c = 0; c < n; c++)); do
                    [ "${RUN_CHAIN[c]}" = "${wave_chains[k]}" ] && [ ! -f "$buf/$c.ok" ] || continue
                    failed=$c
                    break
                done
                [ "$failed" -ge 0 ] || failed="${wave_chains[k]}"
                failed_rc="$rc"
                break
            done
        fi
        files=()
        if [ "$failed" -ge 0 ]; then
            for ((k = printed; k <= failed; k++)); do
                [ -f "$buf/$k" ] && files+=("$buf/$k")
            done
            [ "${#files[@]}" -eq 0 ] || cat "${files[@]}"
            exit "$failed_rc"
        fi
        while [ "$printed" -lt "$n" ] && [ -f "$buf/$printed.ok" ]; do
            files+=("$buf/$printed")
            printed=$((printed + 1))
        done
        [ "${#files[@]}" -eq 0 ] || cat "${files[@]}"
    done
}

if [ "$RENDER_PARALLEL" = 1 ] && [ "$synced" -gt 1 ] && plan_concurrent_render; then
    render_concurrently
else
    adapter_idx=0
    while [ "$adapter_idx" -lt "$synced" ]; do
        run_adapter "$adapter_idx"
        adapter_idx=$((adapter_idx + 1))
    done
fi

if [ $synced -eq 0 ]; then
    if [ -n "$TARGET_FILTER" ]; then
        echo "ERROR: Adapter '$TARGET_FILTER' not found."
        echo "Available: ${ADAPTERS[*]}"
    else
        echo "WARNING: No targets enabled in $CONFIG_FILE"
    fi
    exit 1
fi

SYNC_TX_ACTIVE=0

# After rendering, three read-only reports, in this order:
#   - directories that look like sources but are not wired in (a repository-wide
#     scan, so it runs only once every output exists);
#   - adapter-agnostic source context pressure;
#   - model overrides that drift from intelligence-sync defaults (helpful when
#     defaults move forward — e.g., gpt-5.5 -> gpt-5.6).
# Concurrently, the scan runs beside the other two and beside removing the
# snapshots; the buffers print in the order above.
if [ "$SYNC_PARALLEL" = 1 ]; then
    rm -rf "$SYNC_TX_DIR/data" &
    SYNC_BG_PIDS+=("$!")
    warn_unsynced "$REPO_ROOT" "$CONFIG_FILE" > "$SYNC_TX_DIR/unsynced" 2>&1 &
    SYNC_BG_PIDS+=("$!")
    {
        report_context_source_sizes "$REPO_ROOT" "$CONFIG_FILE"
        report_model_drift "$CONFIG_FILE"
    } > "$SYNC_TX_DIR/reports" 2>&1
    wait_sync_jobs
    cat "$SYNC_TX_DIR/unsynced" "$SYNC_TX_DIR/reports"
    rm -rf "$SYNC_TX_DIR"
    trap - EXIT INT TERM
else
    rm -rf "$SYNC_TX_DIR"
    trap - EXIT INT TERM
    warn_unsynced "$REPO_ROOT" "$CONFIG_FILE"
    report_context_source_sizes "$REPO_ROOT" "$CONFIG_FILE"
    report_model_drift "$CONFIG_FILE"
fi

echo ""
# sync.sh never changes project schemas (the CLI preflight owns that), so
# success is always ok.
is_status ok "synced=$synced"
echo "=== Done: $synced target(s) synced ==="
