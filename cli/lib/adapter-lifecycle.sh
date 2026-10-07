#!/bin/bash
# CLI consumers of the engine's declarative adapter contract.

adapter_file_for() {
    local root="$1" content_dir="$2" name="$3"
    if [ -f "$root/$content_dir/adapters/$name.sh" ]; then
        printf '%s\n' "$root/$content_dir/adapters/$name.sh"
    elif [ -f "$IS_ENGINE_DIR/adapters/$name.sh" ]; then
        printf '%s\n' "$IS_ENGINE_DIR/adapters/$name.sh"
    else
        return 1
    fi
}

# adapter_records_for <root> <content-dir> <name> <output> [manifest] — pass the
# manifest whenever the caller applies or checks Git policy; ownership callers
# may omit it (engine/lib/adapter-contract.sh).
adapter_records_for() {
    local root="$1" content_dir="$2" name="$3" output="$4" manifest="${5:-}" file
    file="$(adapter_file_for "$root" "$content_dir" "$name")" || {
        echo "ERROR: adapter '$name' not found" >&2
        return 1
    }
    adapter_contract_records "$name" "$file" "$output" "$manifest"
}

validate_adapter_contract_for() {
    local root="$1" content_dir="$2" name="$3" output="$4"
    adapter_records_for "$root" "$content_dir" "$name" "$output" >/dev/null
}

adapter_contract_paths() {
    local root="$1" content_dir="$2" name="$3" output="$4"
    adapter_records_for "$root" "$content_dir" "$name" "$output" \
        | awk -F '\t' '$1 == "owned" || $1 == "managed" || $1 == "legacy" || $1 == "preserve" { print $2 }'
}

# Keep the record kind for onboarding. A single concrete path may be both an
# adapter output and a legacy input (AGENTS.md is the important example), so
# flattening the contract too early loses the information needed to quarantine
# only legacy entry points.
adapter_contract_onboarding_records() {
    local root="$1" content_dir="$2" name="$3" output="$4"
    adapter_records_for "$root" "$content_dir" "$name" "$output" \
        | awk -F '\t' '$1 == "owned" || $1 == "managed" || $1 == "legacy" || $1 == "preserve" { print $1 "\t" $2 }'
}
