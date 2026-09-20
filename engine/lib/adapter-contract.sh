#!/bin/bash
# Declarative adapter ownership contract shared by the engine and CLI.
#
# Every adapter exposes adapter_contract_<name> <configured-output>. The
# function emits tab-separated records through the helpers below. Keeping the
# declaration beside sync_to_<name>() makes backup, rollback, git policy and
# lifecycle checks consume the same ownership model as the writer itself.

adapter_contract_version()  { printf 'version\t%s\n' "$1"; }
adapter_contract_requires() { printf 'requires\t%s\n' "$1"; }
adapter_contract_owned()    { printf 'owned\t%s\n' "$1"; }
adapter_contract_managed()  { printf 'managed\t%s\n' "$1"; }
adapter_contract_legacy()   { printf 'legacy\t%s\n' "$1"; }
adapter_contract_preserve() { printf 'preserve\t%s\n' "$1"; }
adapter_contract_ignore()   { printf 'ignore\t%s\n' "$1"; }
adapter_contract_include()  { printf 'include\t%s\n' "$1"; }

adapter_contract_function() {
    printf 'adapter_contract_%s' "$1"
}

# --- cross-adapter ownership -------------------------------------------------
#
# `owned` is exclusive: one adapter writes and prunes that path. `managed` is
# shared on purpose — .agents/skills is filled by Antigravity, Codex, Pi and
# opencode from identical content — so two `managed` claims on one path are
# legal. Any other collision means two adapters prune each other: whichever
# runs last wins, the earlier adapter's output is gone, and both report
# success. `intelligence sync codex` with codex output set to `.agents` did
# exactly that to Antigravity's agents.
#
# State is one "adapter<TAB>kind<TAB>path" record per line in IS_ADAPTER_CLAIMS.
# A conflict is reported through IS_ADAPTER_CLAIM_CONFLICT, never printed and
# never captured in a subshell: the accumulator has to survive the call.
# shellcheck disable=SC2034  # IS_ADAPTER_CLAIM_CONFLICT is read by callers in the engine and the CLI
adapter_claims_reset() {
    IS_ADAPTER_CLAIMS=""
    IS_ADAPTER_CLAIM_CONFLICT=""
}

# adapter_claims_add <adapter> <kind> <path>
# Registers the claim, or sets IS_ADAPTER_CLAIM_CONFLICT and returns 1.
# shellcheck disable=SC2034  # the conflict text is consumed by the caller
adapter_claims_add() {
    local adapter="$1" kind="$2" path="$3"
    local prev_adapter prev_kind prev_path
    while IFS=$'\t' read -r prev_adapter prev_kind prev_path; do
        [ -n "$prev_adapter" ] || continue
        [ "$prev_adapter" = "$adapter" ] && continue
        case "$path" in
            "$prev_path"|"$prev_path"/*) ;;
            *) case "$prev_path" in "$path"/*) ;; *) continue ;; esac ;;
        esac
        # Two `managed` claims agree by design; anything else prunes.
        [ "$kind" = "owned" ] || [ "$prev_kind" = "owned" ] || continue
        if [ "$path" = "$prev_path" ]; then
            IS_ADAPTER_CLAIM_CONFLICT="adapters '$prev_adapter' ($prev_kind) and '$adapter' ($kind) both claim '$path'; an owned path belongs to one adapter, so whichever syncs last prunes the other's output"
        else
            IS_ADAPTER_CLAIM_CONFLICT="adapter '$adapter' claims '$path' ($kind) nested in '$prev_path' ($prev_kind) claimed by '$prev_adapter'; whichever syncs last prunes the other's output"
        fi
        return 1
    done <<< "$IS_ADAPTER_CLAIMS"
    IS_ADAPTER_CLAIMS="$IS_ADAPTER_CLAIMS$adapter"$'\t'"$kind"$'\t'"$path"$'\n'
}

# adapter_claims_add_records <adapter> <records>
# Feeds every owned/managed record of one adapter through adapter_claims_add.
# Returns 1 on the first conflict, which stays in IS_ADAPTER_CLAIM_CONFLICT.
adapter_claims_add_records() {
    local adapter="$1" records="$2" kind value
    while IFS=$'\t' read -r kind value; do
        case "$kind" in
            owned|managed) ;;
            *) continue ;;
        esac
        adapter_claims_add "$adapter" "$kind" "$value" || return 1
    done <<< "$records"
}

# Reject records that could address anything outside the repository. Contract
# paths are always repo-relative; ignore/include records may contain globs.
adapter_contract_safe_path() {
    local path="$1"
    case "$path" in
        ""|/*|*\\*|[A-Za-z]:*|..|../*|*/../*|*/..|*$'\t'*|*$'\n'*) return 1 ;;
        *) return 0 ;;
    esac
}

adapter_contract_safe_concrete_path() {
    adapter_contract_safe_path "$1" || return 1
    case "$1" in
        *'*'*|*'?'*|*'['*) return 1 ;;
        *) return 0 ;;
    esac
}

# adapter_contract_records <adapter-name> <adapter-file> <configured-output>
# Source and query in a subshell so a project adapter cannot leak shell state
# into the caller. Project adapters are trusted executable code during sync;
# the isolation here is for correctness, not a security boundary.
adapter_contract_records() (
    local name="$1" file="$2" output="$3" fn line kind value saw_version=0
    # shellcheck source=/dev/null
    source "$file"
    fn="$(adapter_contract_function "$name")"
    declare -F "$fn" >/dev/null 2>&1 || {
        echo "ERROR: adapter '$name' has no $fn contract" >&2
        return 1
    }
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        kind="${line%%$'\t'*}"
        if [ "$kind" = "$line" ]; then
            echo "ERROR: adapter '$name' emitted a malformed contract record" >&2
            return 1
        fi
        value="${line#*$'\t'}"
        case "$kind" in
            version)
                [ "$value" = "1" ] || {
                    echo "ERROR: adapter '$name' uses unsupported contract version '$value'" >&2
                    return 1
                }
                saw_version=1
                ;;
            requires)
                case "$value" in
                    ""|[!abcdefghijklmnopqrstuvwxyz]*|*[!abcdefghijklmnopqrstuvwxyz0123456789_]*)
                        echo "ERROR: adapter '$name' declares invalid requirement '$value'" >&2
                        return 1
                        ;;
                esac
                ;;
            owned|managed|legacy|preserve)
                adapter_contract_safe_concrete_path "$value" || {
                    echo "ERROR: adapter '$name' declares unsafe $kind path '$value'" >&2
                    return 1
                }
                ;;
            ignore|include)
                adapter_contract_safe_path "$value" || {
                    echo "ERROR: adapter '$name' declares unsafe $kind path '$value'" >&2
                    return 1
                }
                ;;
            *)
                echo "ERROR: adapter '$name' emitted unknown contract record '$kind'" >&2
                return 1
                ;;
        esac
        printf '%s\n' "$line"
    done < <("$fn" "$output")
    [ "$saw_version" -eq 1 ] || {
        echo "ERROR: adapter '$name' contract did not declare version 1" >&2
        return 1
    }
)
