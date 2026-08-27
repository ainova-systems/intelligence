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
