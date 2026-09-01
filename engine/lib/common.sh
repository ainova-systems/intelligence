#!/bin/bash
# intelligence-sync: Core library functions
# Source this file — never execute directly.
#
# Usage: source "$(dirname "$0")/lib/common.sh"

# --- File Utilities ---

# Convert CRLF to LF in a file (safe for Windows/Git Bash)
normalize_file_to_lf() {
    local target="$1"
    local tmp_file="$target.tmp"
    awk '{ sub(/\r$/, ""); print }' "$target" > "$tmp_file"
    mv "$tmp_file" "$target"
}

# --- Layout tokens -----------------------------------------------------------
#
# The content directory is named by the project (`intelligence/`,
# `Intelligence/`, a codename), so package-shipped artifacts cannot hardcode
# it. Layout-sensitive paths and commands use tokens expanded at output time:
#
#   <content-dir> -> the repo-relative project content dir (e.g. `Intelligence`)
#   <module>      -> the repo-relative sync package store path
#
# Values come from IS_CONTENT_REL / IS_MODULE_REL, which the CLI derives from
# the detected layout (never hardcoded) and exports before any adapter runs.
# Expansion happens in EVERY generated file, frontmatter and body alike, so a
# scoped rule reaches Claude's `paths:`, Cursor's `globs:` and Copilot's
# `applyTo:` already carrying the project's real folder name.

# Process spawns dominate sync time on Git Bash for Windows: one fork costs
# tens of milliseconds against ~1ms on Linux, so a helper that runs awk per
# file turns a large project into minutes of pure process creation. Every hot
# helper therefore has a batched form that handles N files in ONE awk process,
# and adapters MUST use the batched forms inside per-file loops. The shared
# function library below keeps token expansion and frontmatter semantics in
# exactly one place across those batch programs.
#
# fin_line() uses literal (index-based) substitution, not gsub: a regex
# replacement would give `&` in a path its special meaning, and POSIX awk has
# no way to pass a replacement string verbatim. Token values arrive via the
# -v args produced by is_fin_awk_vars.
IS_AWK_LIB='
    function is_repl(s, from, to,   out, i) {
        out = ""
        while ((i = index(s, from)) > 0) {
            out = out substr(s, 1, i - 1) to
            s = substr(s, i + length(from))
        }
        return out s
    }
    function fin_line(s) {
        s = is_repl(s, "<sync-cmd>", FIN_SC)
        s = is_repl(s, "<manifest>", FIN_MF)
        s = is_repl(s, "<module>", FIN_MOD)
        s = is_repl(s, "<content-dir>", FIN_CONTENT)
        return s
    }
    function fm_value_strip(val,   n, first, last) {
        sub(/^[[:space:]]+/, "", val)
        sub(/[[:space:]]+$/, "", val)
        n = length(val)
        if (n >= 2) {
            first = substr(val, 1, 1)
            last = substr(val, n, 1)
            if ((first == "\"" && last == "\"") || (first == "\047" && last == "\047")) {
                val = substr(val, 2, n - 2)
            }
        }
        return val
    }
    function base_name(p,   q, m) { m = split(p, q, "/"); return q[m] }
'

# is_fin_awk_vars — fill the global IS_FIN_V array with the -v bindings the
# IS_AWK_LIB fin_line() function needs. Rebuilt on every call: the IS_* env
# contract is exported after this file is sourced.
is_fin_awk_vars() {
    IS_FIN_V=(
        -v "FIN_SC=${IS_SYNC_CMD:-intelligence sync}"
        -v "FIN_MF=${IS_MANIFEST_NAME:-intelligence.yaml}"
        -v "FIN_MOD=${IS_MODULE_REL:-.intelligence/packages/@ainova-systems/sync}"
        -v "FIN_CONTENT=${IS_CONTENT_REL:-intelligence}"
    )
}

# finalize_output_files <file>...
# The single exit gate for every file an adapter writes: expand layout tokens,
# then normalize CRLF -> LF, for any number of files in one awk process. Each
# file is buffered in full and written back in place when the input moves to
# the next file, so no temp files and no per-file mv are needed; a failed run
# is covered by sync.sh's transaction restore.
finalize_output_files() {
    [ "$#" -gt 0 ] || return 0
    is_fin_awk_vars
    awk "${IS_FIN_V[@]}" "$IS_AWK_LIB"'
        function flush_file(   i) {
            if (out_file == "") return
            for (i = 1; i <= line_n; i++) print buf[i] > out_file
            close(out_file)
        }
        FNR == 1 { flush_file(); out_file = FILENAME; line_n = 0 }
        { sub(/\r$/, ""); buf[++line_n] = fin_line($0) }
        END { flush_file() }
    ' "$@"
}

# finalize_output_file <file> — single-file form, kept for cold paths and
# project adapters. A missed call ships a literal `<content-dir>` into an IDE.
finalize_output_file() {
    finalize_output_files "$1"
}

# finalize_copy_files <dst_dir> <src>...
# Copy every source file to <dst_dir>/<basename> with the finalize transform
# applied on the way, all in one awk process. Replaces per-file cp+finalize
# in adapter rule loops.
finalize_copy_files() {
    local dst="$1"
    shift
    [ "$#" -gt 0 ] || return 0
    local f
    # awk never reads a record from an empty source, so pre-create those to
    # keep the old cp behavior of producing an empty output file.
    for f in "$@"; do
        [ -s "$f" ] || : > "$dst/${f##*/}"
    done
    is_fin_awk_vars
    awk "${IS_FIN_V[@]}" -v dst="$dst" "$IS_AWK_LIB"'
        FNR == 1 {
            if (out_file != "") close(out_file)
            out_file = dst "/" base_name(FILENAME)
        }
        { sub(/\r$/, ""); print fin_line($0) > out_file }
    ' "$@"
}

# frontmatter_index <keys-csv> <file>...
# One awk pass over many files; prints one row per file, in argument order:
# the path, then one value per requested key, all separated by \x1f (ASCII
# unit separator — never present in frontmatter values). Value semantics are
# get_frontmatter_value's exactly: first frontmatter block only, first key
# occurrence wins, first-colon split, symmetric quote strip. The special key
# `paths#` yields the has_paths count instead of a value. A file without
# frontmatter (or an empty file) still gets a row, with empty values.
frontmatter_index() {
    local keys="$1"
    shift
    [ "$#" -gt 0 ] || return 0
    awk -v keys="$keys" "$IS_AWK_LIB"'
        BEGIN { US = sprintf("%c", 31); nk = split(keys, K, ",") }
        function store(   i, row) {
            if (cur == "") return
            row = cur
            for (i = 1; i <= nk; i++) row = row US V[i]
            R[cur] = row
        }
        FNR == 1 {
            store()
            cur = FILENAME
            for (ri = 1; ri <= nk; ri++) { V[ri] = (K[ri] == "paths#") ? 0 : ""; delete SEEN[ri] }
            in_fm = 0; fm_done = 0
        }
        { sub(/\r$/, "") }
        FNR == 1 && $0 == "---" { in_fm = 1; next }
        FNR == 1 { fm_done = 1 }
        in_fm && !fm_done && $0 == "---" { fm_done = 1; next }
        fm_done || !in_fm { next }
        {
            idx = index($0, ":")
            if (idx == 0) next
            k = substr($0, 1, idx - 1)
            for (ki = 1; ki <= nk; ki++) {
                if (K[ki] == "paths#") {
                    if (k == "paths") V[ki]++
                } else if (k == K[ki] && !(ki in SEEN)) {
                    SEEN[ki] = 1
                    V[ki] = fm_value_strip(substr($0, idx + 1))
                }
            }
        }
        END {
            store()
            for (ai = 1; ai < ARGC; ai++) {
                if (ARGV[ai] in R) print R[ARGV[ai]]
                else {
                    row = ARGV[ai]
                    for (ki = 1; ki <= nk; ki++) row = row US ((K[ki] == "paths#") ? 0 : "")
                    print row
                }
            }
        }
    ' "$@"
}

# Escape a string for safe interpolation into a TOML basic string ("..").
# Backslash and double-quote are escaped; control chars stripped.
# Fork-free form: sets IS_TOML_ESCAPED; the printing form wraps it.
toml_escape_var() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    # Strip any literal newline / carriage return — TOML basic strings
    # do not allow them; multi-line content belongs in `"""..."""`.
    s="${s//$'\n'/ }"
    s="${s//$'\r'/}"
    IS_TOML_ESCAPED="$s"
}

toml_escape() {
    toml_escape_var "$1"
    printf '%s' "$IS_TOML_ESCAPED"
}

# Escape a string for safe interpolation into a YAML double-quoted scalar.
# Fork-free form: sets IS_YAML_ESCAPED; the printing form wraps it.
yaml_dq_escape_var() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/ }"
    s="${s//$'\r'/}"
    IS_YAML_ESCAPED="$s"
}

yaml_dq_escape() {
    yaml_dq_escape_var "$1"
    printf '%s' "$IS_YAML_ESCAPED"
}

# --- Source Resolution -------------------------------------------------------
#
# Every `sources.*` entry is a repo-relative path resolved as
# `$repo_root/<entry>`. Fetching, version resolution and pinning belong to the
# CLI: by the time the engine runs, an installed package is an ordinary
# directory under the store, indistinguishable from project content.

# Map an absolute file path to a repo-root-relative path for use as a link
# target inside a COMMITTED file (e.g. AGENTS.md). A file under $repo_root gets
# its repo-relative path; one resolved outside it has no stable, committable
# path, so this returns the empty string — callers MUST then emit the bare
# name, never the absolute path. The `${path#"$repo_root"/}` strip is a no-op
# when $path is not under $repo_root, which is how that case is detected.
repo_rel_link() {
    repo_rel_link_var "$1" "$2"
    printf '%s' "$IS_REPO_REL"
}

# repo_rel_link_var — fork-free form: sets IS_REPO_REL ("" when the path is
# not under the repo root) instead of printing.
repo_rel_link_var() {
    local repo_root="$1" path="$2" rel
    rel="${path#"$repo_root"/}"
    if [ "$rel" = "$path" ]; then
        IS_REPO_REL=""
    else
        IS_REPO_REL="$rel"
    fi
}

# Repo-root-relative path of an existing DIRECTORY — by identity, not spelling.
# `${dir#"$repo_root"/}` is a plain string strip, which silently yields the
# unchanged absolute path when the two were produced from different spellings of
# the same location. That is not hypothetical: Git Bash reaches the Windows temp
# dir through two mounts (`/tmp/...` and `/c/Users/.../Temp/...`) and `pwd`
# prints whichever one you arrived through, so `REPO_ROOT` (from `git
# rev-parse`) and `LS_UMBRELLA_DIR` (from the invocation path) can disagree
# character-by-character while naming the same directory. AGENTS.md is
# committed, so a failed strip would bake a machine-specific absolute path into
# version control.
#
# Walks up from <dir> comparing each ancestor to <repo_root> with `-ef`
# (device+inode — identity, immune to spelling), collecting basenames.
# Echoes "" when <dir> is not inside <repo_root>, or does not exist.
# Usage: rel="$(repo_rel_dir "$repo_root" "$LS_MODULE_DIR")"   # -> intelligence/sync
repo_rel_dir() {
    local repo_root="$1" dir="$2"
    local cur rel="" parent base depth=0
    cur="$(cd "$dir" 2>/dev/null && pwd)" || return 0
    [ -d "$repo_root" ] || return 0
    while [ "$depth" -lt 64 ]; do
        if [ "$cur" -ef "$repo_root" ]; then
            printf '%s' "$rel"
            return 0
        fi
        parent="$(dirname "$cur")"
        base="$(basename "$cur")"
        [ "$parent" = "$cur" ] && return 0      # reached the filesystem root
        rel="$base${rel:+/$rel}"
        cur="$parent"
        depth=$((depth + 1))
    done
}

# Resolve a single source token to an absolute local directory. Every token is
# a repo-relative path: the CLI resolves, fetches and pins packages, so by the
# time the engine runs a package is just a directory under the store.
# ALWAYS returns 0 (echoes nothing on failure) so `set -e` callers using
# `dir="$(resolve_source_dir ...)"` never abort; the caller's existing
# `[ -d "$dir" ] || continue` guard then skips an unresolved source.
# Usage: dir="$(resolve_source_dir "$repo_root" "$src")"
resolve_source_dir() {
    printf '%s' "$1/$2"
}

# emit_wrapped_bodies <spec>
# Batch writer for adapters that wrap each source body in generated
# header/tail lines: one awk process emits every output file. <spec> holds
# one \n-separated record per file, fields separated by \x1f:
#   src \x1f dst \x1f mode \x1f trim \x1f escape \x1f header \x1f tail
# where mode selects the body extraction (`strip` = strip_frontmatter
# semantics, `fence` = body only after a closed frontmatter fence, so a file
# without frontmatter yields nothing, `fence_nofm` = fence, or the whole file
# when it never opened one), trim=1 drops trailing blank body lines and emits
# a single blank line for an empty body (the $(...)-capture-then-echo
# semantics the per-file code had), escape=toml applies the TOML triple-quote
# body escaping, and header/tail are literal output lines each prefixed with
# \x1e. Every output line passes through fin_line. The spec travels through
# the environment — awk -v would corrupt backslashes in escaped header values.
emit_wrapped_bodies() {
    local spec="$1"
    [ -n "$spec" ] || return 0
    local -a srcs=()
    local rec
    while IFS= read -r rec; do
        [ -n "$rec" ] || continue
        srcs+=("${rec%%$'\x1f'*}")
    done <<< "$spec"
    [ "${#srcs[@]}" -gt 0 ] || return 0
    is_fin_awk_vars
    IS_WRAP_SPEC="$spec" awk "${IS_FIN_V[@]}" "$IS_AWK_LIB"'
        BEGIN {
            US = sprintf("%c", 31); LS = sprintf("%c", 30)
            n = split(ENVIRON["IS_WRAP_SPEC"], recs, "\n")
            for (i = 1; i <= n; i++) {
                if (recs[i] == "") continue
                split(recs[i], f, US)
                DST[f[1]] = f[2]; MODE[f[1]] = f[3]; TRIM[f[1]] = f[4]
                ESC[f[1]] = f[5]; HEAD[f[1]] = f[6]; TAIL[f[1]] = f[7]
            }
        }
        function emit_lines(block,   m, parts, j) {
            m = split(block, parts, LS)
            for (j = 2; j <= m; j++) print fin_line(parts[j]) > out_file
        }
        function flush_file(   j, last) {
            if (out_file == "") return
            emit_lines(HEAD[cur])
            if (TRIM[cur] == "1") {
                last = 0
                for (j = 1; j <= body_n; j++) if (body[j] != "") last = j
                if (last == 0) print fin_line("") > out_file
                else for (j = 1; j <= last; j++) print fin_line(body[j]) > out_file
            } else {
                for (j = 1; j <= body_n; j++) print fin_line(body[j]) > out_file
            }
            emit_lines(TAIL[cur])
            close(out_file)
            out_file = ""
        }
        FNR == 1 {
            flush_file()
            cur = FILENAME; out_file = DST[cur]; SEENF[cur] = 1
            body_n = 0; in_fm = 0; past_fm = 0
        }
        { sub(/\r$/, "") }
        FNR == 1 && MODE[cur] == "strip" && $0 != "---" { past_fm = 1 }
        /^---$/ {
            if (!past_fm) { in_fm = !in_fm; if (!in_fm) past_fm = 1; next }
        }
        {
            if (MODE[cur] == "fence_nofm") { if (!past_fm && in_fm) next }
            else if (!past_fm) next
            line = $0
            if (ESC[cur] == "toml") {
                line = is_repl(line, "\\", "\\\\")
                line = is_repl(line, "\"\"\"", "\"\"\\\"")
            }
            body[++body_n] = line
        }
        END {
            flush_file()
            # An empty source never produces a record, so emit its header and
            # tail here — the per-file code still wrote the wrapper.
            for (i = 1; i < ARGC; i++) {
                if (ARGV[i] in SEENF) continue
                SEENF[ARGV[i]] = 1
                cur = ARGV[i]; out_file = DST[cur]; body_n = 0
                flush_file()
            }
        }
    ' "${srcs[@]}"
}

# Copy a markdown file with frontmatter, ensuring free-text string fields are
# wrapped in double quotes. Used by adapters that feed strict-YAML consumers
# (Codex CLI rejects unquoted colons / booleans). Idempotent — already-quoted
# values pass through untouched. Operates only inside the first `---` ... `---`
# block; body is preserved verbatim.
#
# Quoted fields: description, argument-hint
# When wrapping an unquoted value, literal `\` and `"` inside it are escaped
# (`\\`, `\"`) so an inner quote — e.g. `Use as a quick "what do we have" view`
# — cannot prematurely terminate the generated double-quoted scalar. Values the
# author already wrapped (in `"` or `'`) pass through untouched.
#
# Usage: copy_md_with_quoted_frontmatter "src.md" "dst.md"
copy_md_with_quoted_frontmatter() {
    local src="$1"
    local dst="$2"
    awk '
        function yamlq(s,    out, i, c) {
            out = ""
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (c == "\\") out = out "\\\\"
                else if (c == "\"") out = out "\\\""
                else out = out c
            }
            return out
        }
        BEGIN { state = "before" }
        { sub(/\r$/, "") }
        state == "before" {
            if (NR == 1 && $0 == "---") { state = "in_fm"; print; next }
            state = "after"; print; next
        }
        state == "in_fm" {
            if ($0 == "---") { state = "after"; print; next }
            idx = index($0, ":")
            if (idx == 0) { print; next }
            key = substr($0, 1, idx - 1)
            sub(/^[[:space:]]+/, "", key); sub(/[[:space:]]+$/, "", key)
            if (key != "description" && key != "argument-hint") { print; next }
            val = substr($0, idx + 1)
            sub(/^[[:space:]]+/, "", val); sub(/[[:space:]]+$/, "", val)
            if (val == "") { print; next }
            first = substr(val, 1, 1)
            last = substr(val, length(val), 1)
            if ((first == "\"" && last == "\"") || (first == "\047" && last == "\047")) { print; next }
            print key ": \"" yamlq(val) "\""
            next
        }
        state == "after" { print }
    ' "$src" > "$dst"
}

# Copy a skill directory in full: SKILL.md plus any bundled resources
# (references/, scripts/, assets/ — the Agent Skills standard lets a skill
# ship support files beside SKILL.md, and SKILL.md bodies point at them by
# relative path, so dropping them breaks the skill at runtime). Markdown is
# normalized to LF; every other file is copied byte-for-byte so potentially
# binary assets survive. `cp -R` copies symlinks as symlinks (POSIX), so a
# link inside a source skill never leaks host file content into the output.
#
# SKILL.md frontmatter is quoted for EVERY consumer, not only the strict-YAML
# ones. `argument-hint: [pr-number]` is a YAML *flow sequence*, so an unquoted
# hint arrives as a list and Claude Code refuses the whole skill with
# "argument-hint must be a string" — the skill silently disappears from the
# picker. Quoting is idempotent: an already-quoted value passes through
# untouched.
# Usage: copy_skill_bundle "src/skill/dir" "dest/skill/dir"
copy_skill_bundle() {
    _skill_bundles_reset
    _skill_bundle_stage "$1" "$2"
    _skill_bundles_flush
}

# copy_skill_bundle_dirs <dest_root> <src_dir>... — batch form: ONE cp -R
# copies every source skill directory into <dest_root>/<skill-name>, then one
# awk pass quotes and finalizes every bundled markdown file across all
# bundles. A later source with the same skill name overwrites file-by-file in
# order, exactly like the sequential per-bundle copies did.
copy_skill_bundle_dirs() {
    local dest_root="$1"
    shift
    [ "$#" -gt 0 ] || return 0
    local src dest
    local -a srcs=()
    for src in "$@"; do
        srcs+=("${src%/}")
    done
    mkdir -p "$dest_root"
    cp -R "${srcs[@]}" "$dest_root/"
    _skill_bundles_reset
    for src in "${srcs[@]}"; do
        dest="$dest_root/${src##*/}"
        _skill_bundle_note "$dest"
    done
    _skill_bundles_flush
}

_skill_bundles_reset() {
    _SB_QUOTE_LIST=""
    _SB_SEEN=""
    _SB_DESTS=()
}

_skill_bundle_stage() {
    local src="${1%/}" dest="$2"
    mkdir -p "$dest"
    cp -R "$src/." "$dest/"
    _skill_bundle_note "$dest"
}

# Record a staged bundle for the flush pass: mark its SKILL.md for
# frontmatter quoting and deduplicate the destination.
_skill_bundle_note() {
    local dest="$1"
    # A symlinked SKILL.md is left exactly as `cp -R` produced it — a
    # symlink. `[ -f ]` follows links, so quoting it would read the link's
    # TARGET and write that content into a real file, turning
    # `skills/x/SKILL.md -> /etc/…` into a copy of a host file inside the
    # output. That is the leak the symlink-preserving copy exists to
    # prevent, so skip the rewrite and say so (the same reason
    # `find -type f` in the flush never matches a symlink).
    if [ -L "$dest/SKILL.md" ]; then
        echo "  WARN: ${dest##*/}/SKILL.md is a symlink — emitted as-is (frontmatter not quoted, tokens not expanded)" >&2
    elif [ -f "$dest/SKILL.md" ]; then
        _SB_QUOTE_LIST="$_SB_QUOTE_LIST$dest/SKILL.md"$'\n'
    fi
    # The same skill name from a later source overwrites the earlier copy;
    # keep one dest entry so the flush does not process the files twice.
    case "${_SB_SEEN:-$'\n'}" in
        *$'\n'"$dest"$'\n'*) ;;
        *)
            _SB_DESTS+=("$dest")
            _SB_SEEN="${_SB_SEEN:-$'\n'}$dest"$'\n'
            ;;
    esac
}

_skill_bundles_flush() {
    [ "${#_SB_DESTS[@]}" -gt 0 ] || return 0
    local -a mds=()
    local f quote_list="$_SB_QUOTE_LIST"
    while IFS= read -r f; do
        [ -n "$f" ] && mds+=("$f")
    done < <(find "${_SB_DESTS[@]}" -type f -name '*.md')
    _skill_bundles_reset
    [ "${#mds[@]}" -gt 0 ] || return 0
    # One awk: quote free-text frontmatter fields in each top-level SKILL.md
    # (strict-YAML consumers reject unquoted colons; `argument-hint:
    # [pr-number]` would otherwise arrive as a YAML flow sequence and the
    # skill silently vanishes from the picker) and expand layout tokens in
    # every bundled markdown file. Quoting is idempotent — already-quoted
    # values pass through untouched. The quote list travels through the
    # environment, like emit_wrapped_bodies specs.
    is_fin_awk_vars
    IS_QUOTE_LIST="$quote_list" awk "${IS_FIN_V[@]}" "$IS_AWK_LIB"'
        BEGIN {
            qn = split(ENVIRON["IS_QUOTE_LIST"], QL, "\n")
            for (qi = 1; qi <= qn; qi++) if (QL[qi] != "") QUOTE[QL[qi]] = 1
        }
        function yamlq(s,    out, i, c) {
            out = ""
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (c == "\\") out = out "\\\\"
                else if (c == "\"") out = out "\\\""
                else out = out c
            }
            return out
        }
        function flush_file(   i) {
            if (out_file == "") return
            for (i = 1; i <= line_n; i++) print buf[i] > out_file
            close(out_file)
        }
        FNR == 1 {
            flush_file()
            out_file = FILENAME; line_n = 0
            state = (FILENAME in QUOTE) ? "before" : ""
        }
        { sub(/\r$/, "") }
        state == "before" {
            if (FNR == 1 && $0 == "---") state = "in_fm"
            else state = "after"
        }
        state == "in_fm" && FNR > 1 {
            if ($0 == "---") state = "after"
            else {
                idx = index($0, ":")
                if (idx > 0) {
                    key = substr($0, 1, idx - 1)
                    sub(/^[[:space:]]+/, "", key); sub(/[[:space:]]+$/, "", key)
                    if (key == "description" || key == "argument-hint") {
                        val = substr($0, idx + 1)
                        sub(/^[[:space:]]+/, "", val); sub(/[[:space:]]+$/, "", val)
                        if (val != "") {
                            first = substr(val, 1, 1)
                            last = substr(val, length(val), 1)
                            if (!((first == "\"" && last == "\"") || (first == "\047" && last == "\047"))) {
                                $0 = key ": \"" yamlq(val) "\""
                            }
                        }
                    }
                }
            }
        }
        { buf[++line_n] = fin_line($0) }
        END { flush_file() }
    ' "${mds[@]}"
}

# Copy skill directories into an Agent Skills open-standard location.
# The destination is a directory whose immediate children are skill folders
# containing SKILL.md (e.g. .agents/skills/<name>/SKILL.md). Free-text
# frontmatter fields are quoted for strict YAML consumers; lenient consumers
# accept the result unchanged, so this one copy can be shared across tools.
#
# Owns the full lifecycle of `$output_dir`: removes every existing skill
# subfolder, recreates the directory, then populates it. Sibling FILES at
# `$output_dir` are preserved (only immediate subdirectories are pruned).
# Multiple adapters may target the same path (e.g. Codex + Pi both write to
# `.agents/skills/`); calls are idempotent because every caller writes the
# same content from `intelligence/skills/`. Adapters MUST NOT do their own
# clean / mkdir for this dir — the helper is the single owner.
#
# Usage: sync_open_skill_dirs "$REPO_ROOT" "$CONFIG_FILE" "$dest_dir"
sync_open_skill_dirs() {
    local repo_root="$1"
    local config_file="$2"
    local output_dir="$3"

    # Several adapters share this destination in one run (Codex, Pi and
    # opencode all feed .agents/skills/) and the contract requires them to
    # write identical content, so the second and later calls replay the first
    # call's output instead of pruning and re-copying every skill.
    if [ "${IS_OPEN_SKILLS_DEST:-}" = "$output_dir" ] && [ "${IS_OPEN_SKILLS_CFG:-}" = "$config_file" ]; then
        printf '%s' "$IS_OPEN_SKILLS_LOG"
        return 0
    fi

    if [ -d "$output_dir" ]; then
        # Prune both real subdirectories and symlinks (incl. dir-symlinks):
        # "-type d" alone would leave a stale symlinked skill in place and
        # break the "helper owns the full lifecycle" contract.
        find "$output_dir" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -exec rm -rf {} +
    fi
    mkdir -p "$output_dir"

    local count=0 log="" d skill_name src list
    local -a skill_dirs=()
    load_yaml_list "$config_file" "skills"
    list="$IS_YAML_LIST"
    while IFS= read -r src; do
        [ -z "$src" ] && continue
        local dir="$repo_root/$src"
        [ -d "$dir" ] || continue
        for d in "$dir"/*/; do
            [ -d "$d" ] || continue
            skill_name="${d%/}"; skill_name="${skill_name##*/}"
            [ -f "$d/SKILL.md" ] || continue
            skill_dirs+=("$d")
            count=$((count + 1))
            log+="  skill: $skill_name"$'\n'
        done
    done <<< "$list"
    # copy_skill_bundle_dirs owns the frontmatter-quoting pass, so every
    # target gets it — not just this open-standard dir.
    if [ "$count" -gt 0 ]; then
        copy_skill_bundle_dirs "$output_dir" "${skill_dirs[@]}"
    fi

    log+="  -> Skills: $count"$'\n'
    printf '%s' "$log"
    IS_OPEN_SKILLS_DEST="$output_dir"
    IS_OPEN_SKILLS_CFG="$config_file"
    IS_OPEN_SKILLS_LOG="$log"
}

# Lint YAML frontmatter for common pitfalls (unquoted colons, leading tabs).
# Print warnings to stderr; do not fail. Strict consumers (Codex CLI) reject
# these files with cryptic messages — catching them in sync gives better DX.
# Batched: one awk process lints every file passed.
# Usage: lint_frontmatter_files "a.md" "b.md" ...
lint_frontmatter_files() {
    [ "$#" -gt 0 ] || return 0
    awk '
        FNR == 1 { in_fm = 0; done = 0 }
        { sub(/\r$/, "") }
        done { next }
        FNR == 1 && $0 != "---" { done = 1; next }
        FNR == 1 { in_fm = 1; next }
        in_fm && $0 == "---" { done = 1; next }
        in_fm && /^\t/ {
            printf "  WARN: %s:%d leading tab in frontmatter (use spaces)\n", FILENAME, FNR > "/dev/stderr"
        }
        in_fm && /^[a-zA-Z0-9_-]+:[[:space:]]+[^"\047|>[{]/ {
            value_start = index($0, ":") + 1
            value = substr($0, value_start)
            sub(/^[[:space:]]+/, "", value)
            if (value ~ /:[[:space:]]/ || value ~ /:$/) {
                col = index(value, ":") + value_start
                printf "  WARN: %s:%d unquoted colon in value at column %d — wrap value in quotes\n", FILENAME, FNR, col > "/dev/stderr"
            }
            if (value ~ /"/) {
                printf "  WARN: %s:%d literal double quote in unquoted value — wrap value in single quotes or escape as \\\" so strict-YAML targets accept it\n", FILENAME, FNR > "/dev/stderr"
            }
        }
        # Field-length limits. Both Claude Code and the Agent Skills standard
        # reject an over-long description outright ("Skill description must be
        # at most 1024 characters") and the skill vanishes from the picker with
        # no other signal, so catching it at sync time is the only cheap warning
        # the author ever gets. Measured on the value, quotes excluded; a block
        # scalar (`description: |`) is skipped — its length is not on this line.
        in_fm && /^(description|name):[[:space:]]*[^|>[:space:]]/ {
            key = substr($0, 1, index($0, ":") - 1)
            val = substr($0, index($0, ":") + 1)
            sub(/^[[:space:]]+/, "", val); sub(/[[:space:]]+$/, "", val)
            first = substr(val, 1, 1); last = substr(val, length(val), 1)
            if ((first == "\"" && last == "\"") || (first == "\047" && last == "\047")) {
                val = substr(val, 2, length(val) - 2)
            }
            limit = (key == "name") ? 64 : 1024
            if (length(val) > limit) {
                printf "  WARN: %s:%d %s is %d chars — over the %d-char limit; the skill/agent will be REJECTED at load time\n", FILENAME, FNR, key, length(val), limit > "/dev/stderr"
            }
        }
    ' "$@"
}

# lint_frontmatter <file> — single-file form for project adapters.
lint_frontmatter() {
    lint_frontmatter_files "$1"
}

# --- Frontmatter Parsing ---

# Extract a single value from YAML frontmatter by key.
# Splits on the FIRST colon only, so values containing additional colons
# (e.g. `description: "Use when: fixing APIs"`) are preserved. Reads only
# inside the first `---` ... `---` frontmatter block; body content is ignored.
# Strips surrounding double or single quotes from the value.
# Usage: get_frontmatter_value "tier" "path/to/file.md"
get_frontmatter_value() {
    local key="$1"
    local file="$2"
    awk -v k="$key" '
        { sub(/\r$/, "") }
        NR == 1 && $0 != "---" { exit }
        NR == 1 { in_fm = 1; next }
        in_fm && $0 == "---" { exit }
        !in_fm { next }

        {
            idx = index($0, ":")
            if (idx == 0) next
            line_key = substr($0, 1, idx - 1)
            if (line_key != k) next
            val = substr($0, idx + 1)
            sub(/^[[:space:]]+/, "", val)
            sub(/[[:space:]]+$/, "", val)
            n = length(val)
            if (n >= 2) {
                first = substr(val, 1, 1)
                last = substr(val, n, 1)
                if ((first == "\"" && last == "\"") || (first == "\047" && last == "\047")) {
                    val = substr(val, 2, n - 2)
                }
            }
            print val
            exit
        }
    ' "$file"
}

# Check if a file starts with YAML frontmatter (---)
has_frontmatter() {
    local file="$1"
    awk 'NR==1 { sub(/\r$/, ""); if ($0 == "---") print 1; else print 0; exit }' "$file"
}

# Strip YAML frontmatter, print body only.
# Reads the first `---` ... `---` block at the top of the file and emits
# everything after the closing fence verbatim. CRLF-safe (trailing \r stripped
# per line). If the file has no frontmatter, the entire file is printed.
# Shared by adapters that wrap source agent bodies into IDE-native templates
# (currently pi.sh, opencode.sh) — do NOT inline-duplicate this awk block.
# Usage: body="$(strip_frontmatter "path/to/file.md")"
strip_frontmatter() {
    local file="$1"
    awk '
        BEGIN { in_fm = 0; past_fm = 0 }
        { sub(/\r$/, "") }
        # No frontmatter: first line is not a `---` fence — treat the whole
        # file as body so the helper honors its "print everything if no
        # frontmatter" contract instead of emitting nothing.
        NR == 1 && $0 != "---" { past_fm = 1 }
        /^---$/ {
            if (!past_fm) {
                in_fm = !in_fm
                if (!in_fm) { past_fm = 1 }
                next
            }
        }
        past_fm { print }
    ' "$file"
}

# Check if a file has a paths: field in frontmatter.
# Scoped to the first `---` ... `---` block — body content like a code
# example referencing `paths: foo` will not be miscounted.
has_paths() {
    local file="$1"
    awk '
        { sub(/\r$/, "") }
        NR == 1 && $0 != "---" { print 0; done=1; exit }
        NR == 1 { in_fm = 1; next }
        in_fm && $0 == "---" { print c+0; done=1; exit }
        in_fm && /^paths:/ { c++ }
        END { if (!done) print c+0 }
    ' "$file"
}

# --- Tier/Access Mappings ---

# Hardcoded defaults: ide:tier -> model name.
# When you bump these, re-run sync in projects; any project whose config.yaml
# `models:` section diverges from these will print a drift warning so users
# know their override is now stale.
get_model_default() {
    local ide="$1"
    local tier="$2"
    case "$ide:$tier" in
        claude:heavy)     echo "opus" ;;
        claude:standard)  echo "sonnet" ;;
        claude:light)     echo "haiku" ;;
        cursor:heavy)     echo "inherit" ;;
        cursor:standard)  echo "inherit" ;;
        cursor:light)     echo "fast" ;;
        copilot:heavy)    echo "gpt-5.6-sol" ;;
        copilot:standard) echo "gpt-5.6-terra" ;;
        copilot:light)    echo "gpt-5.6-luna" ;;
        codex:heavy)      echo "gpt-5.6-sol" ;;
        codex:standard)   echo "gpt-5.6-terra" ;;
        codex:light)      echo "gpt-5.6-luna" ;;
        opencode:heavy)    echo "anthropic/claude-opus-4-8" ;;
        opencode:standard) echo "anthropic/claude-sonnet-5" ;;
        opencode:light)    echo "anthropic/claude-haiku-4-5-20251001" ;;
        *)                echo "" ;;
    esac
}

# Read a nested key from config.yaml: section -> sub -> key.
# Resolves `models.<ide>.<tier>` overrides and `packs.<name>.<field>`.
#
# The value strip is anchored at the FIRST colon (`[^:]*:`), never a greedy
# `.*:` — a greedy match cuts at the LAST colon on the line, which turns
# `url: https://host/repo.git` into `//host/repo.git`. An unquoted value also
# drops a trailing ` # comment`, per YAML; inside quotes a `#` is content.
#
# The sub-key is matched LITERALLY (`index(...) == 1`), never interpolated into
# a regex: a pack name may contain `.`, which as a pattern is any character, so
# `packs.a.b` would happily read a pack named `axb`.
get_nested_yaml_value() {
    local file="$1"
    local section="$2"
    local sub="$3"
    local key="$4"
    awk -v section="$section" -v subname="$sub" -v key="$key" '
        { sub(/\r$/, "") }
        $0 ~ "^" section ":[[:space:]]*$" { in_section=1; in_sub=0; next }
        in_section && /^[a-zA-Z]/ && $0 !~ "^" section ":" { in_section=0; in_sub=0 }
        in_section && index($0, "  " subname ":") == 1 {
            if (substr($0, length(subname) + 4) ~ /^[[:space:]]*$/) { in_sub=1; next }
        }
        in_section && in_sub && /^  [A-Za-z0-9_]/ { in_sub=0 }
        in_section && in_sub && index($0, "    " key ":") == 1 {
            val = $0
            sub(/^[[:space:]]*[^:]*:[[:space:]]*/, "", val)
            if (val ~ /^"/ || val ~ /^\047/) {
                q = substr(val, 1, 1)
                val = substr(val, 2)
                i = index(val, q)
                if (i > 0) val = substr(val, 1, i - 1)
            } else {
                sub(/[[:space:]]+#.*$/, "", val)
                sub(/[[:space:]]+$/, "", val)
            }
            print val
            exit
        }
    ' "$file"
}

# Resolve a model: config.yaml `models:` override wins, otherwise default.
# Usage: get_model "$CONFIG_FILE" "claude" "$tier"
get_model() {
    local config_file="$1"
    local ide="$2"
    local tier="${3:-heavy}"
    local override
    if [ -n "$config_file" ] && [ -f "$config_file" ]; then
        override=$(get_nested_yaml_value "$config_file" "models" "$ide" "$tier")
    fi
    if [ -n "${override:-}" ]; then
        echo "$override"
    else
        get_model_default "$ide" "$tier"
    fi
}

# load_model_tiers <config_file> <ide> — resolve the three standard tiers
# once per adapter run (IS_MODEL_HEAVY / IS_MODEL_STANDARD / IS_MODEL_LIGHT)
# so per-file loops map tier -> model without forking. resolve_model_var
# consumes them; a non-standard tier value still goes through get_model so a
# `models:` override for it keeps working.
load_model_tiers() {
    local config_file="$1" ide="$2"
    IS_MODEL_CFG="$config_file"
    IS_MODEL_IDE="$ide"
    IS_MODEL_HEAVY="$(get_model "$config_file" "$ide" "heavy")"
    IS_MODEL_STANDARD="$(get_model "$config_file" "$ide" "standard")"
    IS_MODEL_LIGHT="$(get_model "$config_file" "$ide" "light")"
}

# resolve_model_var <tier> — set IS_MODEL from the tiers load_model_tiers
# resolved. An empty tier resolves to heavy, like get_model's default.
# shellcheck disable=SC2034  # IS_MODEL is the return channel read by adapters
resolve_model_var() {
    case "$1" in
        heavy|"") IS_MODEL="$IS_MODEL_HEAVY" ;;
        standard) IS_MODEL="$IS_MODEL_STANDARD" ;;
        light)    IS_MODEL="$IS_MODEL_LIGHT" ;;
        *)        IS_MODEL="$(get_model "$IS_MODEL_CFG" "$IS_MODEL_IDE" "$1")" ;;
    esac
}

# Print info message for each model override that differs from the
# hardcoded default. Helps users notice when a script update brings new
# defaults that their config still overrides with the old value.
# One awk pass extracts every `<ide>.<tier>=<value>` triple under `models:`;
# comparison against defaults happens in shell.
report_model_drift() {
    local config_file="$1"
    [ -f "$config_file" ] || return 0

    local triples
    triples=$(awk '
        { sub(/\r$/, "") }
        /^models:[[:space:]]*$/ { in_models=1; next }
        in_models && /^[a-zA-Z]/ { in_models=0; in_ide="" }
        in_models && /^  [a-zA-Z][a-zA-Z0-9_-]*:[[:space:]]*$/ {
            line=$0
            sub(/^  /, "", line); sub(/:[[:space:]]*$/, "", line)
            in_ide=line
            next
        }
        in_models && in_ide && /^    [a-zA-Z][a-zA-Z0-9_-]*:/ {
            line=$0; sub(/^    /, "", line)
            key=line; sub(/:.*/, "", key)
            val=line; sub(/[^:]+:[[:space:]]*/, "", val)
            gsub(/^["\047]|["\047][[:space:]]*$/, "", val)
            print in_ide "\t" key "\t" val
        }
    ' "$config_file")

    [ -z "$triples" ] && return 0

    local printed_header=0
    while IFS=$'\t' read -r ide tier from_config; do
        [ -z "$from_config" ] && continue
        local default
        default=$(get_model_default "$ide" "$tier")
        [ "$from_config" = "$default" ] && continue
        if [ $printed_header -eq 0 ]; then
            echo ""
            echo "=== Model overrides (config.yaml differs from intelligence-sync defaults) ==="
            printed_header=1
        fi
        printf "  %-8s %-9s config=%-20s default=%s\n" "$ide" "$tier" "\"$from_config\"" "\"$default\""
    done <<< "$triples"

    if [ $printed_header -eq 1 ]; then
        echo "  (To accept new defaults: remove the entry from config.yaml \`models:\` section.)"
    fi
}

# Map access level to Claude tools string (fork-free form: sets
# IS_CLAUDE_TOOLS; the printing form wraps it for compatibility)
map_access_to_claude_tools_var() {
    case "$1" in
        readonly) IS_CLAUDE_TOOLS="Read, Grep, Glob, Bash" ;;
        # full: emit NO tools list at all. Confirmed empirically in Copilot (VSCode,
        # reading .claude/agents): a closed tools list restricts the agent to exactly
        # those tools and loses MCP; omitting the field lets it inherit every session
        # tool, MCP servers included. tools: ["*"] did NOT enable MCP - omission does.
        # (Claude Code behaves the same: no tools field = inherit all incl MCP.)
        # NOTE: omission also inherits Pylance + all built-ins, which can push the
        # request over Copilot's 128-tool cap and trigger virtual-tools grouping that
        # intermittently hides MCP. The durable fix is an explicit allowlist that
        # NAMES the MCP servers (umbraco-mcp/*, figma/*) and stays under 128; that
        # needs the project's MCP server list, so it is tracked, not encoded here yet.
        *)        IS_CLAUDE_TOOLS="" ;;
    esac
}

# Map access level to Claude disallowedTools (empty if full access)
map_access_to_claude_disallowed_var() {
    case "$1" in
        readonly) IS_CLAUDE_DISALLOWED="Write, Edit" ;;
        *)        IS_CLAUDE_DISALLOWED="" ;;
    esac
}

map_access_to_claude_tools() {
    map_access_to_claude_tools_var "$1"
    echo "$IS_CLAUDE_TOOLS"
}

map_access_to_claude_disallowed() {
    map_access_to_claude_disallowed_var "$1"
    echo "$IS_CLAUDE_DISALLOWED"
}

# --- Validation ---

# Lexically canonicalize a path: collapse `//`, `.` and `..` by pure string
# surgery, so a path that does not exist yet still normalizes (realpath -m is
# not POSIX and `cd` only works on dirs that exist). Symlinks are NOT resolved
# — validate_output_path pairs this with a `cd -P` check for paths that do
# exist.
# Usage: canon="$(normalize_path "/repo/a/../b")"   # -> /repo/b
normalize_path() {
    normalize_path_var "$1"
    printf '%s' "$IS_NORM_PATH"
}

# normalize_path_var <path> — fork-free form: sets IS_NORM_PATH instead of
# printing, so hot validation loops avoid a command-substitution subshell.
normalize_path_var() {
    local path="$1" p out=""
    local -a parts
    IFS='/' read -r -a parts <<< "$path"
    for p in "${parts[@]+"${parts[@]}"}"; do
        case "$p" in
            ""|".") ;;
            "..")   out="${out%/*}" ;;
            *)      out="$out/$p" ;;
        esac
    done
    IS_NORM_PATH="${out:-/}"
}

# Refuse to operate on output paths that could clobber content.
# Adapters `rm -rf` subdirectories of $output_dir, and the `agents` adapter
# overwrites whatever single file it is pointed at; if config.yaml aims an
# adapter at the repo root, outside the repo, at the intelligence source tree
# (whatever the user named it), or at any configured source directory, that
# write would destroy real work. Call this from sync.sh before invoking EVERY
# adapter — `agents` included: writing one file to an arbitrary path is a
# config-file-to-arbitrary-write path, no less than a cleanup is.
#
# All forbidden paths are derived dynamically — no folder name is
# hardcoded, so projects that renamed `intelligence/` (capital I, custom
# name) are protected the same way.
#
# Exits 1 with a clear message on rejection.
# Usage: validate_output_path "$REPO_ROOT" "$CONFIG_FILE" "$adapter" "$output_dir"
validate_output_path() {
    local repo_root="$1"
    local config_file="$2"
    local adapter="$3"
    local output_dir="$4"

    # A full sync validates the same path several times (preflight, snapshot,
    # the adapter run itself, and shared paths like `.agents/skills` once per
    # adapter that manages them). Success depends only on the inputs below —
    # failures exit and are never memoized — so repeats return immediately.
    local memo_key="$repo_root|$config_file|$output_dir"
    case "${IS_VOP_MEMO:-$'\n'}" in
        *$'\n'"$memo_key"$'\n'*) return 0 ;;
    esac

    # Canonicalize FIRST. Every check below is a string comparison, so a `../`
    # left in the raw value would walk straight past all of them.
    local canon
    normalize_path_var "$output_dir"
    canon="$IS_NORM_PATH"

    case "$canon" in
        ""|"/"|"$repo_root")
            echo "ERROR: targets.$adapter.output resolves to repo root or empty path: '$output_dir'" >&2
            echo "  Refusing to run — the adapter would destroy repository content." >&2
            exit 1
            ;;
    esac

    # Must stay inside the repository.
    case "$canon" in
        "$repo_root"/*) ;;
        *)
            echo "ERROR: targets.$adapter.output escapes the repository: '$output_dir'" >&2
            echo "  Resolves to '$canon', outside '$repo_root'." >&2
            exit 1
            ;;
    esac

    # A symlink ANYWHERE on the path can still lead out of the repo, which the
    # lexical pass above cannot see. The output itself usually does not exist on
    # a first sync, so checking only an existing final directory would miss the
    # common case (`.cursor` absent, but its parent `generated/` symlinked out).
    # Walk up to the deepest component that does exist and resolve THAT
    # physically. `-L` in the loop guard so a broken symlink is caught rather
    # than stepped over.
    local probe="$canon" parent
    while [ ! -e "$probe" ] && [ ! -L "$probe" ]; do
        parent="${probe%/*}"
        [ -n "$parent" ] || parent="/"
        [ "$parent" = "$probe" ] && break
        probe="$parent"
    done

    if [ -e "$probe" ] || [ -L "$probe" ]; then
        # A symlinked FILE target (e.g. `AGENTS.md` -> /etc/hosts, or a dangling
        # link) would be written straight through. Refuse rather than follow it;
        # a generated output is never legitimately a file symlink.
        if [ -L "$probe" ] && [ ! -d "$probe" ]; then
            echo "ERROR: targets.$adapter.output ('$output_dir') resolves through a symlink ('$probe')." >&2
            echo "  Refusing to write through it." >&2
            exit 1
        fi
        # Symlinked directory: allowed only while its physical target stays
        # inside the repo (`pwd -P` on both sides so a symlinked repo root
        # resolves consistently).
        local probe_dir phys repo_phys
        if [ -d "$probe" ]; then probe_dir="$probe"; else probe_dir="${probe%/*}"; [ -n "$probe_dir" ] || probe_dir="/"; fi
        phys="$(cd "$probe_dir" 2>/dev/null && pwd -P)" || phys=""
        if [ "${IS_VOP_REPO_PHYS_ROOT:-}" = "$repo_root" ]; then
            repo_phys="$IS_VOP_REPO_PHYS"
        else
            repo_phys="$(cd "$repo_root" && pwd -P)"
            IS_VOP_REPO_PHYS_ROOT="$repo_root"
            IS_VOP_REPO_PHYS="$repo_phys"
        fi
        case "${phys:-/nonexistent}" in
            "$repo_phys"|"$repo_phys"/*) ;;
            *)
                echo "ERROR: targets.$adapter.output ('$output_dir') resolves through a symlink to '$phys'," >&2
                echo "  which is outside the repository. Refusing to run." >&2
                exit 1
                ;;
        esac
    fi

    local rel="${canon#"$repo_root"/}"

    # Reject the intelligence source directory itself (parent of config.yaml).
    # Folder name is whatever the user chose — we read it from the filesystem.
    local intel_dir intel_rel
    if [ "${IS_VOP_INTEL_KEY:-}" = "$config_file" ]; then
        intel_dir="$IS_VOP_INTEL_DIR"
    else
        intel_dir="$(cd "$(dirname "$config_file")" && pwd)"
        IS_VOP_INTEL_KEY="$config_file"
        IS_VOP_INTEL_DIR="$intel_dir"
    fi
    intel_rel="${intel_dir#"$repo_root"/}"
    if [ -n "$intel_rel" ] && [ "$intel_rel" != "$intel_dir" ]; then
        case "$rel" in
            "$intel_rel"|"$intel_rel"/*)
                echo "ERROR: targets.$adapter.output points into the intelligence source tree ('$intel_rel'): '$rel'" >&2
                echo "  The adapter would overwrite or delete rules / agents / skills source files." >&2
                exit 1
                ;;
        esac
    fi

    # Explicitly protected directories (colon-separated, repo-relative). In CLI
    # mode the manifest sits at the repo root, so the parent-of-config
    # derivation above degrades to a no-op — the CLI names the source tree and
    # the package store here instead. Unset (every vendored setup) → inert.
    if [ -n "${IS_PROTECTED_DIRS:-}" ]; then
        local -a prot_arr=()
        local prot
        IFS=':' read -r -a prot_arr <<< "$IS_PROTECTED_DIRS"
        for prot in "${prot_arr[@]+"${prot_arr[@]}"}"; do
            [ -n "$prot" ] || continue
            case "$rel" in
                "$prot"|"$prot"/*)
                    echo "ERROR: targets.$adapter.output points into a protected directory ('$prot'): '$rel'" >&2
                    echo "  The adapter would overwrite or delete source or package content." >&2
                    exit 1
                    ;;
            esac
        done
    fi

    # Reject any configured source directory (rules, agents, skills).
    local section src src_rel src_list
    for section in rules agents skills; do
        load_yaml_list "$config_file" "$section"
        src_list="$IS_YAML_LIST"
        while IFS= read -r src; do
            [ -z "$src" ] && continue
            normalize_path_var "$repo_root/$src"
            src_rel="${IS_NORM_PATH#"$repo_root"/}"
            case "$rel" in
                "$src_rel"|"$src_rel"/*)
                    echo "ERROR: targets.$adapter.output ('$rel') overlaps a configured source ('$src')." >&2
                    echo "  The adapter would overwrite or delete source content." >&2
                    exit 1
                    ;;
            esac
        done <<< "$src_list"
    done

    IS_VOP_MEMO="${IS_VOP_MEMO:-$'\n'}$memo_key"$'\n'
}

# Warn about prompt directories not listed in sources.
# Scans for `rules/` / `agents/` / `skills/` directories anywhere under the
# intelligence source tree and any sibling tree with the same basename
# (e.g. nested per-component intelligence folders). Anything found that is
# not in `sources.*` is flagged. No folder name is hardcoded — the
# intelligence directory is whatever holds `config.yaml`.
warn_unsynced() {
    local repo_root="$1"
    local config_file="$2"

    local all_sources=()
    local src ign section
    for section in rules agents skills; do
        load_yaml_list "$config_file" "$section"
        while IFS= read -r src; do
            [ -z "$src" ] && continue
            all_sources+=("$src")
        done <<< "$IS_YAML_LIST"
    done

    # Collect ignore + submodule patterns.
    local ignores=()
    for section in ignore submodules; do
        load_yaml_list "$config_file" "$section"
        while IFS= read -r ign; do
            [ -z "$ign" ] && continue
            ignores+=("$ign")
        done <<< "$IS_YAML_LIST"
    done

    # The manifest sits at the repo root, so the content dir cannot be derived
    # from its location — it comes from the env contract the CLI exports.
    local intel_basename
    if [ "${IS_CLI:-0}" = "1" ]; then
        intel_basename="${IS_CONTENT_REL:-intelligence}"
        intel_basename="${intel_basename##*/}"
    else
        intel_basename="$(dirname "$config_file")"
        intel_basename="${intel_basename##*/}"
    fi

    local warnings=0

    # Prune instead of post-filtering: the old scan walked every directory in
    # the repository — .git object stores and node_modules trees included —
    # and then discarded the hits, which alone took minutes in a large
    # monorepo. Results under these names were never actionable: generated
    # tool outputs, the package store, dependency and build trees.
    while IFS= read -r found_dir; do
        local rel_dir="${found_dir#$repo_root/}"

        # Skip generated output directories and common excludes. The package
        # store (.intelligence/) is CLI-managed content reached through its own
        # sources entries — flagging it would warn on every installed package.
        case "$rel_dir" in
            .claude/*|.cursor/*|.github/*|.codex/*|.agents/*|.intelligence/*|*/node_modules/*|*/vendor/*|*/dist/*) continue ;;
        esac
        # Initial onboarding backups are immutable migration evidence, never
        # source directories. Suggesting one would reintroduce legacy content.
        case "/$rel_dir/" in
            *"/$intel_basename/_backup/"*) continue ;;
        esac

        # Skip ignore/submodule patterns.
        local skip=false
        for ign in "${ignores[@]+"${ignores[@]}"}"; do
            case "$rel_dir" in
                "$ign"/*|*/"$ign"/*) skip=true; break ;;
            esac
        done
        [ "$skip" = true ] && continue

        # Only flag directories whose ancestry includes a folder with the
        # same basename as the intelligence source dir (so we catch
        # `Intelligence/rules`, `apps/billing/intelligence/rules`, etc.,
        # but not unrelated `rules/` / `agents/` directories elsewhere).
        case "/$rel_dir/" in
            *"/$intel_basename/"*) ;;
            *) continue ;;
        esac

        # Check if directory has content worth syncing (globs, no subprocess:
        # any *.md directly inside, or a SKILL.md at depth one or two —
        # `-e` because the old `find -name` matched any entry type).
        local has_content=false f
        for f in "$found_dir"/*.md; do
            [ -e "$f" ] && has_content=true
            break
        done
        if [ "$has_content" = false ] && [ -e "$found_dir/SKILL.md" ]; then
            has_content=true
        fi
        if [ "$has_content" = false ]; then
            for f in "$found_dir"/*/SKILL.md; do
                [ -e "$f" ] && has_content=true
                break
            done
        fi
        [ "$has_content" = false ] && continue

        # Check if this directory is in any source array.
        local matched=false
        for src in "${all_sources[@]+"${all_sources[@]}"}"; do
            if [ "$rel_dir" = "$src" ]; then
                matched=true
                break
            fi
        done

        if [ "$matched" = false ]; then
            if [ $warnings -eq 0 ]; then
                echo ""
                echo "=== WARNING: Unsynced directories ==="
            fi
            echo "  NOT SYNCED: $rel_dir"
            warnings=$((warnings + 1))
        fi
    done < <(find "$repo_root" \( -name ".git" -o -name "node_modules" -o -name "vendor" -o -name "dist" -o -name ".claude" -o -name ".cursor" -o -name ".github" -o -name ".codex" -o -name ".agents" -o -name ".intelligence" \) -prune -o -type d \( -name "rules" -o -name "agents" -o -name "skills" -o -name "Rules" -o -name "Agents" -o -name "Skills" \) -print 2>/dev/null)

    if [ $warnings -gt 0 ]; then
        echo "  Add these paths to sources: in ${config_file##*/}"
    fi
}

# --- Config Parsing ---

# Read a simple list from config.yaml
# Format: key:\n  - "value1"\n  - "value2"
# Usage: readarray -t arr < <(read_yaml_list "config.yaml" "rules")
#
# Consults the load_yaml_list cache first: sync reads the same sections from
# the same manifest dozens of times, and each awk spawn costs tens of
# milliseconds on Windows. The cache is only ever populated by
# load_yaml_list, which the engine calls for a manifest it never mutates, so
# a CLI process that edits the manifest keeps reading the file directly.
read_yaml_list() {
    local file="$1"
    local section="$2"
    case "$section" in
        rules|agents|skills|ignore|submodules)
            local cached_file cached_val
            eval "cached_file=\"\${IS_YL_${section}_FILE:-}\""
            if [ -n "$cached_file" ] && [ "$cached_file" = "$file" ]; then
                eval "cached_val=\"\${IS_YL_${section}_VAL}\""
                [ -n "$cached_val" ] && printf '%s\n' "$cached_val"
                return 0
            fi
            ;;
    esac
    awk -v section="$section" '
        {
            sub(/\r$/, "")
        }
        /^[a-z]/ { current_section = ""; depth = 0 }
        /^  [a-z]/ { current_section = ""; depth = 0 }
        $0 ~ "^" section ":" { current_section = section; depth = 0; next }
        $0 ~ "^  " section ":" { current_section = section; depth = 2; next }
        current_section == section && depth == 0 && /^  - / {
            val = $0
            sub(/^  - /, "", val)
            gsub(/["\047]/, "", val)
            print val
        }
        current_section == section && depth == 2 && /^    - / {
            val = $0
            sub(/^    - /, "", val)
            gsub(/["\047]/, "", val)
            print val
        }
    ' "$file"
}

# load_yaml_list <file> <section> — fill the global IS_YAML_LIST with the
# section's entries (newline-separated) and cache the result for
# read_yaml_list and later load_yaml_list calls. Lets in-process loops
# iterate a section without forking; the engine warms the cache once per run.
# Only sections whose names are identifier-safe are cached.
load_yaml_list() {
    local file="$1" section="$2" cached_file
    case "$section" in
        rules|agents|skills|ignore|submodules)
            eval "cached_file=\"\${IS_YL_${section}_FILE:-}\""
            if [ -n "$cached_file" ] && [ "$cached_file" = "$file" ]; then
                eval "IS_YAML_LIST=\"\${IS_YL_${section}_VAL}\""
                return 0
            fi
            IS_YAML_LIST="$(read_yaml_list "$file" "$section")"
            eval "IS_YL_${section}_FILE=\$file; IS_YL_${section}_VAL=\$IS_YAML_LIST"
            ;;
        *)
            IS_YAML_LIST="$(read_yaml_list "$file" "$section")"
            ;;
    esac
}

# load_targets_cache <file> — parse the whole targets: section once into the
# global IS_TGT_TSV (one `name<TAB>enabled<TAB>output` row per target),
# replicating is_target_enabled and get_target_output semantics: inline and
# block forms, first occurrence wins, `enabled` defaults to 0 when the block
# ends without one and to empty at end of file. The engine warms this once;
# both readers consult it before spawning awk.
load_targets_cache() {
    local file="$1"
    if [ "${IS_TGT_FILE:-}" = "$file" ]; then
        return 0
    fi
    IS_TGT_TSV="$(awk '
        function flush_target(at_sibling) {
            if (name == "") return
            if (enabled == "" && at_sibling) enabled = 0
            printf "%s\t%s\t%s\n", name, enabled, output
            name = ""
        }
        { sub(/\r$/, "") }
        /^targets:[[:space:]]*$/ { in_targets = 1; next }
        /^[a-zA-Z]/ { in_targets = 0 }
        # The per-target readers scanned forward for the FIRST line containing
        # `enabled:` / `output:` after the target header, checking it before
        # the block-end test — so a sibling header line could donate its own
        # inline values to a block that lacked them. These two rules run
        # before the header rule below to keep that reading.
        name != "" && enabled == "" && /enabled:/ {
            enabled = ($0 ~ /true/) ? 1 : 0
        }
        name != "" && output == "" && /output:/ {
            val = $0
            sub(/.*output:[[:space:]]*["\047]?/, "", val)
            sub(/["\047]?[[:space:]]*}?$/, "", val)
            output = val
        }
        in_targets && $0 ~ /^  [a-zA-Z0-9_-]+:/ {
            flush_target(1)
            line = $0
            name = substr(line, 3)
            sub(/:.*$/, "", name)
            enabled = ""; output = ""
            if (line ~ /enabled:[[:space:]]*true/) enabled = 1
            else if (line ~ /enabled:[[:space:]]*false/) enabled = 0
            if (match(line, /output:[[:space:]]*/)) {
                rest = substr(line, RSTART + RLENGTH)
                if (match(rest, /[,}]/)) rest = substr(rest, 1, RSTART - 1)
                gsub(/^["\047]|["\047][[:space:]]*$/, "", rest)
                sub(/[[:space:]]+$/, "", rest)
                output = rest
            }
            next
        }
        name != "" && /^  [a-zA-Z]/ { flush_target(1) }
        END { flush_target(0) }
    ' "$file")"
    IS_TGT_FILE="$file"
}

# _targets_cache_row <target> — scan the cached TSV; sets IS_TGT_ROW_ENABLED /
# IS_TGT_ROW_OUTPUT. Returns 1 when the target has no row (reader falls back
# to empty, same as the awk scan finding nothing).
_targets_cache_row() {
    local target="$1" n e o
    IS_TGT_ROW_ENABLED=""
    IS_TGT_ROW_OUTPUT=""
    while IFS=$'\t' read -r n e o; do
        if [ "$n" = "$target" ]; then
            IS_TGT_ROW_ENABLED="$e"
            IS_TGT_ROW_OUTPUT="$o"
            return 0
        fi
    done <<< "$IS_TGT_TSV"
    return 1
}

# target_enabled_var <file> <target> — fork-free is_target_enabled: sets
# IS_TGT_ENABLED instead of printing. Falls back to the awk reader when the
# cache does not cover the file.
# shellcheck disable=SC2034  # IS_TGT_ENABLED is the return channel read by sync.sh
target_enabled_var() {
    local file="$1" target="$2"
    if [ "${IS_TGT_FILE:-}" = "$file" ]; then
        _targets_cache_row "$target" || true
        IS_TGT_ENABLED="$IS_TGT_ROW_ENABLED"
    else
        IS_TGT_ENABLED="$(is_target_enabled "$file" "$target")"
    fi
}

# target_output_var <file> <target> — fork-free get_target_output: sets
# IS_TGT_OUTPUT instead of printing.
# shellcheck disable=SC2034  # IS_TGT_OUTPUT is the return channel read by sync.sh
target_output_var() {
    local file="$1" target="$2"
    if [ "${IS_TGT_FILE:-}" = "$file" ]; then
        _targets_cache_row "$target" || true
        IS_TGT_OUTPUT="$IS_TGT_ROW_OUTPUT"
    else
        IS_TGT_OUTPUT="$(get_target_output "$file" "$target")"
    fi
}

# Check if a target is enabled in config.yaml (scoped to targets: section)
# Usage: is_target_enabled "config.yaml" "claude"
is_target_enabled() {
    local file="$1"
    local target="$2"
    if [ "${IS_TGT_FILE:-}" = "$file" ]; then
        _targets_cache_row "$target" || true
        [ -n "$IS_TGT_ROW_ENABLED" ] && printf '%s\n' "$IS_TGT_ROW_ENABLED"
        return 0
    fi
    awk -v target="$target" '
        { sub(/\r$/, "") }

        # Enter/leave the targets: section
        /^targets:[[:space:]]*$/ { in_targets = 1; next }
        /^[a-zA-Z]/ { in_targets = 0 }

        in_targets && $0 ~ "^  " target ":" {
            if ($0 ~ /enabled:[[:space:]]*true/) { print 1; exit }
            if ($0 ~ /enabled:[[:space:]]*false/) { print 0; exit }
            in_target = 1; next
        }
        in_target && /enabled:/ {
            if ($0 ~ /true/) { print 1 } else { print 0 }
            exit
        }
        in_target && /^  [a-zA-Z]/ { print 0; exit }
    ' "$file"
}

# Get an arbitrary field from a target's config block.
# Handles both inline (`claude: { enabled: true, output: ".claude" }`)
# and block form. Uses POSIX awk only — no gawk-specific 3-arg match().
# Usage: get_target_field "config.yaml" "claude" "output"
get_target_field() {
    local file="$1"
    local target="$2"
    local field="$3"
    awk -v target="$target" -v field="$field" '
        { sub(/\r$/, "") }
        /^targets:[[:space:]]*$/ { in_targets = 1; next }
        /^[a-zA-Z]/ { in_targets = 0 }

        in_targets && $0 ~ "^  " target ":" {
            line = $0
            inline_pat = "[ {,]" field ":[[:space:]]*"
            if (match(line, inline_pat)) {
                # Strip everything up to and including the field key.
                rest = substr(line, RSTART + RLENGTH)
                # Cut at the next comma or closing brace.
                if (match(rest, /[,}]/)) {
                    rest = substr(rest, 1, RSTART - 1)
                }
                # Strip surrounding quotes and trailing space.
                gsub(/^["\047]|["\047][[:space:]]*$/, "", rest)
                sub(/[[:space:]]+$/, "", rest)
                if (rest != "") { print rest; exit }
            }
            in_target = 1; next
        }
        in_target && $0 ~ "^    " field ":[[:space:]]*" {
            val = $0
            sub(/.*:[[:space:]]*["\047]?/, "", val)
            sub(/["\047]?[[:space:]]*$/, "", val)
            print val
            exit
        }
        in_target && /^  [a-zA-Z]/ { exit }
    ' "$file"
}

# Get output directory for a target (scoped to targets: section).
# POSIX awk — no 3-arg match().
# Usage: get_target_output "config.yaml" "claude"
get_target_output() {
    local file="$1"
    local target="$2"
    if [ "${IS_TGT_FILE:-}" = "$file" ]; then
        _targets_cache_row "$target" || true
        [ -n "$IS_TGT_ROW_OUTPUT" ] && printf '%s\n' "$IS_TGT_ROW_OUTPUT"
        return 0
    fi
    awk -v target="$target" '
        { sub(/\r$/, "") }

        /^targets:[[:space:]]*$/ { in_targets = 1; next }
        /^[a-zA-Z]/ { in_targets = 0 }

        in_targets && $0 ~ "^  " target ":" {
            line = $0
            if (match(line, /output:[[:space:]]*/)) {
                rest = substr(line, RSTART + RLENGTH)
                if (match(rest, /[,}]/)) {
                    rest = substr(rest, 1, RSTART - 1)
                }
                gsub(/^["\047]|["\047][[:space:]]*$/, "", rest)
                sub(/[[:space:]]+$/, "", rest)
                if (rest != "") { print rest; exit }
            }
            in_target = 1; next
        }
        in_target && /output:/ {
            val = $0
            sub(/.*output:[[:space:]]*["\047]?/, "", val)
            sub(/["\047]?[[:space:]]*}?$/, "", val)
            print val
            exit
        }
        in_target && /^  [a-zA-Z]/ { exit }
    ' "$file"
}

# Read a multi-line block scalar (| or > style) from a target's field.
# Usage: get_target_block "config.yaml" "agents" "header"
# Reads YAML of the shape:
#   targets:
#     agents:
#       header: |
#         # Project
#         one-liner
# Strips the common content indent from all lines in the block.
get_target_block() {
    local file="$1"
    local target="$2"
    local field="$3"
    awk -v target="$target" -v field="$field" '
        { sub(/\r$/, "") }

        /^targets:[[:space:]]*$/ { in_targets = 1; next }
        /^[a-zA-Z]/ { in_targets = 0 }

        # State 0: looking for "  <target>:" under targets
        state == 0 && in_targets && $0 ~ "^  " target ":[[:space:]]*$" {
            state = 1
            next
        }

        # State 1: inside target block, looking for "    <field>: |"
        state == 1 {
            if ($0 ~ /^[^ ]/) { exit }             # top-level key — exit
            if ($0 ~ /^  [a-zA-Z]/) { exit }       # another target — exit
            if ($0 ~ "^[[:space:]]+" field ":[[:space:]]*[|>][[:space:]]*$") {
                match($0, /^[[:space:]]+/)
                field_indent = RLENGTH
                state = 2
                block_indent = 0
            }
            next
        }

        # State 2: collecting block contents
        state == 2 {
            if ($0 ~ /^[[:space:]]*$/) {
                print ""
                next
            }
            match($0, /^[[:space:]]*/)
            cur_indent = RLENGTH
            if (cur_indent <= field_indent) { exit }
            if (block_indent == 0) { block_indent = cur_indent }
            if (cur_indent < block_indent) { exit }
            print substr($0, block_indent + 1)
        }
    ' "$file"
}

# Read a scalar field out of a top-level config block: `section:` -> `  key:`.
# The single two-level reader — `get_nested_yaml_value` and `get_target_field`
# cover the three-level shapes (`models.<ide>.<tier>`, `targets.<name>.<field>`).
# Usage: get_yaml_field "config.yaml" "external" "dir"
get_yaml_field() {
    local file="$1"
    local section="$2"
    local key="$3"
    awk -v section="$section" -v key="$key" '
        { sub(/\r$/, "") }
        $0 ~ "^" section ":" { in_section = 1; next }
        in_section && /^[a-zA-Z]/ { exit }
        in_section && $0 ~ "^  " key ":" {
            val = $0
            sub(/.*:[[:space:]]*["\047]?/, "", val)
            sub(/["\047]?[[:space:]]*$/, "", val)
            print val
            exit
        }
    ' "$file"
}

# Get project name from config.yaml (project.name)
get_project_name() {
    get_yaml_field "$1" "project" "name"
}

# Immediate sub-keys of a top-level block, one per line (`packs:` → pack names).
# Block form only: a pack always spans several lines, so the inline `{...}` form
# that `get_target_field` accommodates has no use here.
# Usage: readarray -t names < <(read_yaml_keys "config.yaml" "packs")
read_yaml_keys() {
    local file="$1" section="$2"
    [ -f "$file" ] || return 0
    awk -v section="$section" '
        { sub(/\r$/, "") }
        $0 ~ "^" section ":[[:space:]]*$" { in_sec = 1; next }
        /^[A-Za-z]/ { in_sec = 0 }
        in_sec && /^  [A-Za-z0-9_][A-Za-z0-9._-]*:[[:space:]]*$/ {
            k = $0
            sub(/^[[:space:]]+/, "", k)
            sub(/:[[:space:]]*$/, "", k)
            print k
        }
    ' "$file"
}
