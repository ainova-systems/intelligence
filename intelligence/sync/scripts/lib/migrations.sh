#!/bin/bash
# shellcheck disable=SC2034  # IS_RC_*/IS_MIGRATED/IS_VERSION_KEY are the public bash↔skill contract, consumed by the scripts that source this lib
# intelligence-sync: versioned migrations — breaking-change update architecture
# Source this file — never execute directly. Requires layout.sh already
# sourced (uses no globals from it directly; callers pass paths explicitly).
#
# THE MODEL (how breaking changes are shipped & absorbed):
#   * The project carries a version stamp (.intelligence-sync-version); the
#     engine carries scripts/VERSION. The gap stamped → engine IS the set of
#     breaking changes to apply.
#   * Each breaking structural change ships as ONE registered migrate_to_<ver>
#     in MIGRATIONS (ordered, ascending). The dispatcher applies only the
#     pending ones (target version > stamped), in order, so a project several
#     versions behind is walked forward step by step, stamping after each.
#   * Every migrate_to_<ver> obeys the contract: precondition → stage → verify
#     postcondition (sentinel) → commit → cleanup; idempotent; fail-closed
#     (never destroy prior state before the replacement is verified).
#   * A stale engine refuses a project stamped newer than it knows
#     (ahead-of-engine). sync.sh refuses to sync across an un-applied gap
#     (needs-update). The intelligence-update SKILL is the brain: it reads the
#     CHANGELOG across the gap, surfaces breaking items, runs this chain, and
#     verifies after.
#
# Naming carries the target version (bash forbids dots → underscores):
#   migrate_to_0_3_1   flat <umbrella>/scripts → modular <umbrella>/sync/
# Future breaking changes: append a new suffix to MIGRATIONS and add the
# matching migrate_to_<ver> — nothing here is rewritten or reordered.

# Ordered (ascending) list of migration target versions. Append only.
MIGRATIONS=( "0_3_1" "0_7_0" )

# The applied-schema version is a managed key in config.yaml — NOT a dotfile,
# NOT scripts/VERSION. config.yaml is what most future breaking changes will
# reshape, so the schema version lives with what it versions.
#
# INVARIANT: this key is a PERMANENT, format-stable, top-level scalar contract.
# Migrations may restructure anything else in config.yaml, but never the name,
# location, or shape of this key — so any engine (however old/new) can always
# read "what schema is this?" before parsing the rest. The bootstrap/INIT flow
# must emit it for fresh projects and preserve it on re-bootstrap.
IS_VERSION_KEY="sync_version"

# "0_3_1" → "0.3.1"
_mig_ver_dotted() { printf '%s' "$1" | tr '_' '.'; }

# read_engine_stamp <config_file> → applied version, or "" if absent.
read_engine_stamp() {
    local cf="$1"
    [ -f "$cf" ] || return 0
    awk -v k="$IS_VERSION_KEY" '
        { sub(/\r$/, "") }
        $0 ~ "^" k ":" {
            v = $0; sub(/^[^:]*:[[:space:]]*/, "", v)
            gsub(/^["\047]|["\047][[:space:]]*$/, "", v)
            sub(/[[:space:]]+$/, "", v)
            print v; exit
        }
    ' "$cf"
}

# stamp_version <config_file> <version> — idempotent, transactional upsert of
# the contract key (replace in place if present, else append at top level).
# No-op if config.yaml does not exist yet (pre-bootstrap).
stamp_version() {
    local cf="$1" ver="$2"
    [ -f "$cf" ] || return 0
    local tmp="$cf.ver.tmp"
    awk -v k="$IS_VERSION_KEY" -v val="$ver" '
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
IS_RC_CONFIG_MISSING=2      # no config.yaml found
IS_RC_AMBIGUOUS=3           # conflicting state; skill/human-only — bash never emits this itself, it is reserved for the intelligence-update skill to report
IS_RC_AHEAD=4               # project stamped newer than this engine understands
IS_RC_ABORTED_INCOMPLETE=5  # staged module incomplete; legacy left intact
IS_RC_NEEDS_UPDATE=6        # pending breaking changes (stamp < engine) — run the update flow first

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
        ai=$(printf '%s' "${A[$i]:-0}" | tr -cd '0-9'); ai=${ai:-0}
        bi=$(printf '%s' "${B[$i]:-0}" | tr -cd '0-9'); bi=${bi:-0}
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
    stamp="$(read_engine_stamp "$cf")"
    [ -n "$stamp" ] || return 0
    eng="$(engine_version)"
    [ -n "$eng" ] || return 0
    if _ver_gt "$stamp" "$eng"; then
        is_status ahead-of-engine "stamp=$stamp engine=$eng"
        echo "  ERROR: project stamped $stamp but this engine is $eng — refusing." >&2
        echo "         Update the engine first (the intelligence-update skill handles this)." >&2
        return "$IS_RC_AHEAD"
    fi
    return 0
}

# Set by migrate_to_* when it actually performed work this run, so the caller
# can report `migrated` vs `ok`.
IS_MIGRATED=0

# Idempotent directory replace (rsync if present, else rm+cp). Returns non-zero
# if any step fails: a migration runs in an `||` context, so `set -e` is off and
# an unchecked copy failure (permissions, full disk) would otherwise sail on to
# the cleanup and delete the legacy files it never actually copied.
_mig_copy_dir() {
    local src="$1" dst="$2"
    [ -d "$src" ] || return 0
    if command -v rsync >/dev/null 2>&1; then
        mkdir -p "$dst" || return 1
        rsync -a --delete "$src/" "$dst/" || return 1
    else
        rm -rf "$dst" || return 1
        mkdir -p "$(dirname "$dst")" || return 1
        cp -r "$src" "$dst" || return 1
    fi
    return 0
}

_mig_copy_file() {
    local src="$1" dst="$2"
    [ -f "$src" ] || return 0
    mkdir -p "$(dirname "$dst")" || return 1
    cp "$src" "$dst" || return 1
    return 0
}

# Repo-root-relative path of the umbrella — the prefix every `sources:` entry is
# resolved against (resolve_source_dir does "$repo_root/$entry"). `basename` is
# only correct when the umbrella sits directly at the repo root; a nested one
# (`platform/intelligence/`) would yield `intelligence/...` and register a source
# that resolves nowhere. Ask git for the real prefix, and fall back to basename
# when there is no git (a tarball checkout), which is the flat case anyway.
_mig_umbrella_rel() {
    local umbrella="$1" prefix=""
    if command -v git >/dev/null 2>&1; then
        prefix="$(git -C "$umbrella" rev-parse --show-prefix 2>/dev/null || true)"
    fi
    prefix="${prefix%/}"
    if [ -n "$prefix" ]; then
        printf '%s' "$prefix"
    else
        printf '%s' "$(basename "$umbrella")"
    fi
}

# True (0) if <entry> is already listed anywhere in config.yaml (quoted or bare).
_mig_has_source() {
    local config="$1" entry="$2"
    [ -f "$config" ] || return 1
    grep -Fq -- "\"$entry\"" "$config" || grep -Fq -- "- $entry" "$config"
}

# Idempotently add one entry to `sources.<section>` in config.yaml. No backup —
# the edit is a single additive list item. Name-agnostic: the caller passes the
# already-resolved "<base>/<module>/<dir>". If the section does not exist under
# `sources:` yet, it is created with the entry as its only item.
# Usage: _mig_add_source <config.yaml> <rules|agents|skills> <entry>
_mig_add_source() {
    local config="$1" section="$2" entry="$3"
    if [ ! -f "$config" ]; then
        echo "  [migrate] no config.yaml at $config — add this under sources.$section manually:" >&2
        echo "      - \"$entry\"" >&2
        return 0
    fi
    _mig_has_source "$config" "$entry" && return 0

    local tmp="$config.mig.tmp"
    awk -v section="$section" -v entry="$entry" '
        function emit() { print "    - \"" entry "\""; inserted = 1 }
        function close_here() {
            if (in_sec && !inserted) { emit(); in_sec = 0 }
        }
        { sub(/\r$/, "") }
        # Top-level key: ends the sources block (and any open section in it).
        /^[A-Za-z]/ {
            close_here()
            # `sources:` existed but never declared this section — declare it.
            if (in_src && !inserted) { print "  " section ":"; emit() }
            in_sec = 0
            in_src = ($0 ~ /^sources:[[:space:]]*$/) ? 1 : 0
            print; next
        }
        in_src && $0 ~ "^  " section ":[[:space:]]*$" { print; in_sec = 1; next }
        # Another 2-space sub-key ends this section.
        in_src && /^  [A-Za-z]/ { close_here(); print; next }
        in_sec && /^    -[[:space:]]/ { print; next }     # existing item
        in_sec && /^[[:space:]]*$/ { close_here(); print; next }
        { print }
        END {
            close_here()
            if (in_src && !inserted) { print "  " section ":"; emit() }
        }
    ' "$config" > "$tmp" && mv "$tmp" "$config"
}

# Back-compat shim: 0.3.1 shipped with this name, and a shipped migration is
# never rewritten.
_mig_add_skill_source() {
    _mig_add_source "$1" "skills" "$2"
}

# --- migrate_to_0_3_1 -------------------------------------------------------
# Pre-0.3.1: engine + meta-skills + INIT.md + docs lived flat under the
# umbrella, mixed with project content. 0.3.1: they move into the self-
# contained module subfolder <umbrella>/<module>/. Project content
# (rules/, agents/, non-meta skills/, config.yaml) is never moved or deleted.
#
# Ownership of meta-skills is by the reserved `intelligence-` prefix. A
# project skill must not use that prefix (documented in CONVENTIONS.md).
#
# migrate_to_0_3_1 <umbrella_dir> <module_name> [<upstream_module_dir>]
#   upstream_module_dir set  → authoritative content source (update.sh)
#   upstream_module_dir empty → relocate local legacy files (sync.sh, offline)
migrate_to_0_3_1() {
    local umbrella="$1" module_name="$2" upstream="${3:-}"
    local module_dir="$umbrella/$module_name"
    local s

    # Precondition: any legacy upstream-owned artifact directly under the
    # umbrella. None ⇒ already modular or fresh ⇒ idempotent no-op.
    local has_legacy=0
    [ -d "$umbrella/scripts" ] && has_legacy=1
    [ -e "$umbrella/INIT.md" ] && has_legacy=1
    [ -d "$umbrella/docs" ] && has_legacy=1
    for s in "$umbrella"/skills/intelligence-*; do
        [ -e "$s" ] && { has_legacy=1; break; }
    done
    # Already modular / fresh ⇒ nothing to relocate. Stamping is owned by the
    # dispatcher (run_migrations), not here.
    if [ "$has_legacy" -eq 0 ]; then
        return 0
    fi

    echo "  [migrate 0.3.1] legacy flat layout detected — relocating engine into '$module_name/'"
    IS_MIGRATED=1
    mkdir -p "$module_dir"

    # Authoritative content source: the fresh upstream clone when update.sh
    # supplies one, else the project's own legacy files (sync.sh, offline).
    local src_root="$umbrella"
    if [ -n "$upstream" ] && [ -d "$upstream" ]; then
        src_root="$upstream"
    fi

    # Stage. Every copy's exit status is captured — see _mig_copy_dir.
    local copy_rc=0
    _mig_copy_dir  "$src_root/scripts" "$module_dir/scripts" || copy_rc=1
    _mig_copy_file "$src_root/INIT.md" "$module_dir/INIT.md" || copy_rc=1
    _mig_copy_dir  "$src_root/docs"    "$module_dir/docs"    || copy_rc=1
    mkdir -p "$module_dir/skills" || copy_rc=1
    for s in "$src_root"/skills/intelligence-*; do
        [ -d "$s" ] || continue
        _mig_copy_dir "$s" "$module_dir/skills/$(basename "$s")" || copy_rc=1
    done

    # Verify the FULL postcondition BEFORE any destructive cleanup: every
    # artifact present at the source must now exist in the module, non-empty.
    # This is the crash-safety gate — a half-populated module must never
    # trigger legacy deletion, so two script sentinels are not enough.
    local missing=""
    [ "$copy_rc" -eq 0 ] || missing="$missing copy-failed"
    [ -s "$module_dir/scripts/sync.sh" ] || missing="$missing scripts/sync.sh"
    [ -s "$module_dir/scripts/lib/common.sh" ] || missing="$missing scripts/lib/common.sh"
    if [ -f "$src_root/INIT.md" ] && [ ! -s "$module_dir/INIT.md" ]; then
        missing="$missing INIT.md"
    fi
    if [ -d "$src_root/docs" ] && [ -z "$(find "$module_dir/docs" -type f 2>/dev/null | head -1)" ]; then
        missing="$missing docs/"
    fi
    for s in "$src_root"/skills/intelligence-*; do
        [ -d "$s" ] || continue
        if [ ! -s "$module_dir/skills/$(basename "$s")/SKILL.md" ]; then
            missing="$missing skills/$(basename "$s")"
        fi
    done

    if [ -n "$missing" ]; then
        is_status aborted-incomplete "module=$module_name missing=${missing# }"
        echo "  ERROR: migration aborted — '$module_name/' incomplete (${missing# }); legacy left intact." >&2
        return "$IS_RC_ABORTED_INCOMPLETE"
    fi

    # Remove ONLY the legacy upstream-owned locations. Meta-skills / INIT /
    # docs are never the running process, so these always succeed → no
    # duplicate intelligence-* ever survives under <umbrella>/skills/.
    rm -f  "$umbrella/INIT.md"
    rm -rf "$umbrella/docs"
    for s in "$umbrella"/skills/intelligence-*; do
        [ -e "$s" ] && rm -rf "$s"
    done
    # The legacy scripts/ dir may host the *currently running* update.sh.
    # On Linux deleting an open script is fine; some Windows shells refuse
    # it. Try, and if it lingers print a one-line manual cleanup instead of
    # failing — the new location, config, and stamp are already correct, and
    # the next sync/update run removes the dead dir.
    rm -rf "$umbrella/scripts" 2>/dev/null || true
    if [ -d "$umbrella/scripts" ]; then
        echo "  NOTE: legacy '$umbrella/scripts' still present (likely in use)." >&2
        echo "        Remove it manually once this process exits:" >&2
        echo "          rm -rf \"$umbrella/scripts\"" >&2
    fi

    # config.yaml: name-agnostic relative path under the actual umbrella base.
    _mig_add_skill_source "$umbrella/config.yaml" "$(_mig_umbrella_rel "$umbrella")/$module_name/skills"

    echo "  [migrate 0.3.1] done — engine at '$module_name/', legacy removed, no duplicates"
}

# --- migrate_to_0_7_0 -------------------------------------------------------
# 0.7.0 is the first release where the engine ships a RULE and an AGENT of its
# own (`intelligence-authoring`, `intelligence-architect`), inside the module
# beside the meta-skills. Those reach the IDEs only if `config.yaml` lists the
# module's `rules/` and `agents/` directories as sources — so this migration
# registers them, exactly as 0.3.1 registered the module's `skills/`.
#
# Precondition is structural: both entries already present ⇒ applied ⇒ silent
# no-op. Nothing else in config.yaml is read or rewritten, and no file is
# deleted, so there is nothing to stage — the postcondition is simply that both
# entries are readable afterwards.
#
# migrate_to_0_7_0 <umbrella_dir> <module_name> [<upstream_module_dir> — unused]
migrate_to_0_7_0() {
    local umbrella="$1" module_name="$2"
    local config="$umbrella/config.yaml"
    [ -f "$config" ] || return 0

    local base rules_entry agents_entry
    base="$(_mig_umbrella_rel "$umbrella")"
    rules_entry="$base/$module_name/rules"
    agents_entry="$base/$module_name/agents"

    if _mig_has_source "$config" "$rules_entry" && _mig_has_source "$config" "$agents_entry"; then
        return 0
    fi

    echo "  [migrate 0.7.0] registering the module's rules/ and agents/ as sources"
    IS_MIGRATED=1
    _mig_add_source "$config" "rules"  "$rules_entry"
    _mig_add_source "$config" "agents" "$agents_entry"

    if ! _mig_has_source "$config" "$rules_entry" || ! _mig_has_source "$config" "$agents_entry"; then
        is_status error "migrate_to_0_7_0 could not register module sources"
        echo "  ERROR: failed to add the module's rules/agents to sources in $config." >&2
        echo "         Add them by hand under 'sources:':" >&2
        echo "           rules:  - \"$rules_entry\"" >&2
        echo "           agents: - \"$agents_entry\"" >&2
        return "$IS_RC_ERROR"
    fi

    echo "  [migrate 0.7.0] done — sources.rules += $rules_entry, sources.agents += $agents_entry"
}

# run_migrations <umbrella_dir> <module_name> [<upstream_module_dir>]
# The dispatcher of the breaking-change chain. Correctness rests on idempotent
# structural preconditions, NOT on the stamp: every migrate_to_* self-detects
# whether its change is already applied and is a silent no-op if so, so the
# whole chain is simply run in order — a wrong/missing stamp can never cause a
# needed migration to be skipped. The stamp is only a safety guard
# (ahead-of-engine / needs-update) + reporting. Returns 0 on success
# (IS_MIGRATED tells whether work happened) or the failing migration's IS_RC_*
# code; never partially destroys (each migrate_to_* is transactional and
# fail-closed). Caller maps the code to an exit status + IS_STATUS line.
run_migrations() {
    local umbrella="$1" module_name="$2" upstream="${3:-}"
    local cf="$umbrella/config.yaml"
    local v ver rc
    # A stale engine must never touch a project schema stamped newer than it
    # knows. (Reads the frozen contract key from config.yaml.)
    check_version_compat "$cf" || return $?
    for v in "${MIGRATIONS[@]}"; do
        ver="$(_mig_ver_dotted "$v")"
        "migrate_to_$v" "$umbrella" "$module_name" "$upstream"
        rc=$?
        if [ "$rc" -ne 0 ]; then return "$rc"; fi
        # Commit progress: stamp this version so an interrupted chain resumes
        # from the last good point. Idempotent migrations that no-op'd just
        # re-assert the same value.
        stamp_version "$cf" "$ver"
    done
    # Fresh project with no stamp at all (e.g. just-bootstrapped, nothing in
    # the chain applied) → stamp to the engine version so future runs have a
    # baseline. Safe: migrations already self-skipped.
    if [ -z "$(read_engine_stamp "$cf")" ]; then
        stamp_version "$cf" "$(engine_version)"
    fi
    return 0
}
