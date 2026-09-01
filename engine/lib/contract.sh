#!/bin/bash
# shellcheck disable=SC2034  # IS_RC_*/IS_SCHEMA_VERSION_KEY are the public bash<->CLI contract, consumed by the scripts that source this lib
# intelligence-sync: the version and status contract.
# Source this file — never execute directly.
#
# Two things live here, and both are contracts other programs depend on:
#   * the applied-schema stamp (`schema_version` in the manifest) with its
#     read / write / compare helpers, and
#   * the IS_STATUS / IS_RC_* codes every engine flow reports.
#
# Schema migrations themselves are NOT here: the CLI owns them behind
# `intelligence init`, and a legacy Intelligence Sync project is brought forward
# by its archived engine before `intelligence init` converts it.

# The applied-schema version is a managed key in the manifest.
#
# INVARIANT: this key is a PERMANENT, format-stable, top-level scalar contract.
# Anything else in the manifest may be reshaped; the name, location and shape of
# this key never are - so any engine, however old or new, can always read "what
# schema is this?" before parsing the rest.
IS_SCHEMA_VERSION_KEY="schema_version"

# read_schema_version <config_file> → applied version, or "" if absent.
read_schema_version() {
    local cf="$1"
    [ -f "$cf" ] || return 0
    awk -v k="$IS_SCHEMA_VERSION_KEY" '
        { sub(/\r$/, "") }
        $0 ~ "^" k ":" {
            v = $0; sub(/^[^:]*:[[:space:]]*/, "", v)
            gsub(/^["\047]|["\047][[:space:]]*$/, "", v)
            sub(/[[:space:]]+$/, "", v)
            print v; exit
        }
    ' "$cf"
}

# stamp_schema_version <config_file> <version> — idempotent, transactional upsert of
# the contract key (replace in place if present, else append at top level).
# No-op if config.yaml does not exist yet (pre-bootstrap).
stamp_schema_version() {
    local cf="$1" ver="$2"
    [ -f "$cf" ] || return 0
    local tmp="$cf.ver.tmp"
    awk -v k="$IS_SCHEMA_VERSION_KEY" -v val="$ver" '
        { sub(/\r$/, "") }
        $0 ~ "^" k ":" { print k ": \"" val "\""; found=1; next }
        { print }
        END { if (!found) print k ": \"" val "\"" }
    ' "$cf" > "$tmp" && mv "$tmp" "$cf"
}

# --- bash ↔ skill status contract -------------------------------------------
# Bash is the deterministic, fail-closed core: it never guesses. Any state it
# cannot resolve safely is reported as a machine-readable status line on
# stdout plus a stable exit code, and the intelligence-update SKILL (the
# intelligent layer) decides what to do. Codes are part of the public
# contract — do not renumber.
IS_RC_OK=0                  # success (synced / migrated / nothing to do)
IS_RC_ERROR=1               # generic error
IS_RC_CONFIG_MISSING=2      # no manifest found
IS_RC_AMBIGUOUS=3           # conflicting state; agent/human-only — bash never emits this itself
IS_RC_AHEAD=4               # project stamped newer than this engine understands
IS_RC_ABORTED_INCOMPLETE=5  # staged state incomplete; the project was left untouched
IS_RC_NEEDS_UPDATE=6        # pending schema changes (stamp < engine) — run `intelligence init --apply`

# is_status <code-name> [detail] — emit one parseable line for the skill.
is_status() {
    local code="$1" detail="${2:-}"
    if [ -n "$detail" ]; then
        echo "IS_STATUS=$code IS_DETAIL=$detail"
    else
        echo "IS_STATUS=$code"
    fi
}

# Engine version = scripts/VERSION next to this lib (BASH_SOURCE works when
# sourced). Empty if unreadable — callers treat empty as "no guard".
engine_version() {
    local vf
    vf="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/VERSION"
    [ -f "$vf" ] && tr -d ' \t\r\n' < "$vf"
}

# _ver_gt A B → true if semver A is strictly greater than B (numeric x.y.z;
# any non-numeric suffix on a field is ignored). Missing fields = 0.
# Pre-release/build metadata ordering is intentionally NOT handled — the
# stamp only ever stores plain x.y.z, so this is sufficient.
_ver_gt() {
    local a="$1" b="$2" i ai bi
    local -a A B
    IFS=. read -r -a A <<< "$a"
    IFS=. read -r -a B <<< "$b"
    for i in 0 1 2; do
        ai="${A[$i]:-0}"; ai="${ai//[!0-9]/}"; ai=${ai:-0}
        bi="${B[$i]:-0}"; bi="${bi//[!0-9]/}"; bi=${bi:-0}
        if [ "$((10#$ai))" -gt "$((10#$bi))" ]; then return 0; fi
        if [ "$((10#$ai))" -lt "$((10#$bi))" ]; then return 1; fi
    done
    return 1
}

# check_version_compat <config_file> — refuse to operate on a project whose
# config schema is stamped newer than this engine knows (a stale engine must
# never rewrite/sync a newer schema). Emits status + returns IS_RC_AHEAD on
# conflict, else 0.
check_version_compat() {
    local cf="$1" stamp eng
    stamp="$(read_schema_version "$cf")"
    [ -n "$stamp" ] || return 0
    eng="$(engine_version)"
    [ -n "$eng" ] || return 0
    if _ver_gt "$stamp" "$eng"; then
        is_status ahead-of-engine "stamp=$stamp engine=$eng"
        echo "  ERROR: project stamped $stamp but this engine is $eng — refusing." >&2
        echo "         Update the CLI first: npm i -g @ainova-systems/intelligence@latest" >&2
        return "$IS_RC_AHEAD"
    fi
    return 0
}
