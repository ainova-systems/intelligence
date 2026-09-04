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

# Stale engine vs project schema stamped NEWER (ahead-of-engine) → refuse.
_vc_rc=0
check_version_compat "$_cf" || _vc_rc=$?
if [ "$_vc_rc" -ne 0 ]; then exit "$_vc_rc"; fi

# Schema gap → refuse. sync is a PURE synchronizer: it never changes schemas,
# so the CLI lifecycle preflight must align the project first. An ABSENT stamp
# means the same thing — a manifest with no
# `schema_version` must not silently sync past a schema change.
_stamp="$(read_schema_version "$_cf")"
_eng="$(engine_version)"
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
CONFIG_FILE="$(cd "$(dirname "$CONFIG_FILE")" && pwd)/$(basename "$CONFIG_FILE")"

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
for section in rules agents skills ignore submodules; do
    load_yaml_list "$CONFIG_FILE" "$section"
done

# Lint frontmatter across all source files (rules, agents, skills).
# Catches issues like unquoted colons that strict YAML consumers reject.
LINT_FILES=()
for section in rules agents skills; do
    load_yaml_list "$CONFIG_FILE" "$section"
    while IFS= read -r src; do
        [ -z "$src" ] && continue
        src_dir="$REPO_ROOT/$src"
        [ -d "$src_dir" ] || continue
        if [ "$section" = "skills" ]; then
            while IFS= read -r f; do
                [ -n "$f" ] && LINT_FILES+=("$f")
            done < <(find "$src_dir" -mindepth 2 -maxdepth 2 -name 'SKILL.md' 2>/dev/null)
        else
            for f in "$src_dir"/*.md; do
                [ -f "$f" ] && LINT_FILES+=("$f")
            done
        fi
    done <<< "$IS_YAML_LIST"
done
if [ "${#LINT_FILES[@]}" -gt 0 ]; then
    lint_frontmatter_files "${LINT_FILES[@]}"
fi

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
        adapter_name="$(basename "$adapter_file" .sh)"
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
        cp -a "$src" "$SYNC_TX_DIR/data/$index"
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

finish_sync_transaction() {
    local rc=$?
    trap - EXIT INT TERM
    set +e
    if [ "${SYNC_TX_ACTIVE:-0}" = "1" ] && [ "$rc" -ne 0 ]; then
        restore_sync_snapshot
        echo "ERROR: sync failed; all adapter-owned paths were restored to their pre-sync state." >&2
    fi
    rm -rf "$SYNC_TX_DIR"
    exit "$rc"
}
trap finish_sync_transaction EXIT
trap 'exit 130' INT TERM

preflight_idx=0
while [ "$preflight_idx" -lt "${#ADAPTERS[@]}" ]; do
    adapter="${ADAPTERS[$preflight_idx]}"
    adapter_file="${ADAPTER_FILES[$preflight_idx]}"
    preflight_idx=$((preflight_idx + 1))
    if [ -n "$TARGET_FILTER" ] && [ "$adapter" != "$TARGET_FILTER" ]; then
        continue
    fi
    target_enabled_var "$CONFIG_FILE" "$adapter"
    [ "$IS_TGT_ENABLED" = "1" ] || continue
    target_output_var "$CONFIG_FILE" "$adapter"
    output="$IS_TGT_OUTPUT"
    [ -n "$output" ] || output=".$adapter"
    validate_output_path "$REPO_ROOT" "$CONFIG_FILE" "$adapter" "$REPO_ROOT/$output"
    records="$(adapter_contract_records "$adapter" "$adapter_file" "$output")" || exit 1
    while IFS=$'\t' read -r kind value; do
        [ "$kind" = "requires" ] || continue
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
SYNC_TX_ACTIVE=1

synced=0
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

    # Source adapter and run.
    # shellcheck source=/dev/null
    source "$adapter_file"
    "sync_to_$adapter" "$REPO_ROOT" "$CONFIG_FILE" "$output_dir"
    echo ""
    synced=$((synced + 1))
done

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
rm -rf "$SYNC_TX_DIR"
trap - EXIT INT TERM

# Warn about unsynced directories
warn_unsynced "$REPO_ROOT" "$CONFIG_FILE"

# Report adapter-agnostic source context pressure on every successful sync.
report_context_source_sizes "$REPO_ROOT" "$CONFIG_FILE"

# Report model overrides that drift from intelligence-sync defaults
# (helpful when defaults move forward — e.g., gpt-5.5 -> gpt-5.6).
report_model_drift "$CONFIG_FILE"

echo ""
# sync.sh never changes project schemas (the CLI preflight owns that), so
# success is always ok.
is_status ok "synced=$synced"
echo "=== Done: $synced target(s) synced ==="
