#!/bin/bash
# Whether Claude Code loads the always-on rules twice in this project, and the
# settings entry that stops it (decision 0025). Sourced by `status --check`,
# which prints it as a note, and by `sync`, which prints it as a warning on
# every run. One evaluation and one wording serve both, so they cannot drift.
#
# Claude Code 2.1.277 and later reads AGENTS.md as project instructions when no
# CLAUDE.md, .claude/CLAUDE.md or CLAUDE.local.md exists in the project or above
# it, and keeps loading .claude/rules/ beside it (code.claude.com/docs/en/memory).
# With both targets enabled every always-on rule then loads twice. The contract
# preserves settings.json, so the exclude is the owner's to add.
#
# Sync evaluates it on every run, cache hits included, after the preflight
# and before the render, so nothing here starts a process on the way: a cache
# hit is budgeted in processes.

# claude_md_above <dir> - whether <dir> or a directory above it holds a
# CLAUDE.md, .claude/CLAUDE.md or CLAUDE.local.md, any of which keeps Claude
# Code from reading AGENTS.md. The user's own ~/.claude/CLAUDE.md does not.
claude_md_above() {
    local d="$1" up
    while :; do
        [ ! -e "$d/CLAUDE.md" ] && [ ! -e "$d/CLAUDE.local.md" ] || return 0
        if [ -e "$d/.claude/CLAUDE.md" ] && ! [ "$d" -ef "${HOME:-}" ]; then return 0; fi
        up="${d%/*}"
        [ -n "$d" ] && [ "$up" != "$d" ] || return 1
        d="$up"
    done
}

# _claude_glob_re_var <glob> - IS_CLAUDE_GLOB_RE, the anchored extended regular
# expression for one claudeMdExcludes glob: `**/` any run of directories, `**`
# anything, `*` and `?` within one path segment, every other character itself.
_claude_glob_re_var() {
    local glob="$1" i=0 c out="^" specials='\^$.|+()[]{}'
    while [ "$i" -lt "${#glob}" ]; do
        c="${glob:i:1}"
        if [ "$c" = "*" ] && [ "${glob:i+1:1}" = "*" ]; then
            i=$((i + 1))
            if [ "${glob:i+1:1}" = "/" ]; then
                i=$((i + 1))
                out="$out(.*/)?"
            else
                out="$out.*"
            fi
        elif [ "$c" = "*" ]; then
            out="${out}[^/]*"
        elif [ "$c" = "?" ]; then
            out="${out}[^/]"
        else
            case "$specials" in
                *"$c"*) out="$out\\$c" ;;
                *) out="$out$c" ;;
            esac
        fi
        i=$((i + 1))
    done
    IS_CLAUDE_GLOB_RE="$out\$"
}

# _claude_excludes_var <settings-file> - IS_CLAUDE_EXCLUDES, the strings of the
# file's claudeMdExcludes array, one per line, read up to the first entry that
# is not a string. Returns 1 when the file has no such array.
_claude_excludes_var() {
    local buf="" s v c i
    IS_CLAUDE_EXCLUDES=""
    IFS= read -r -d '' buf < "$1" || true
    case "$buf" in *'"claudeMdExcludes"'*) ;; *) return 1 ;; esac
    s="${buf#*\"claudeMdExcludes\"}"
    s="${s#"${s%%[![:space:]]*}"}"
    case "$s" in :*) s="${s#:}" ;; *) return 1 ;; esac
    s="${s#"${s%%[![:space:]]*}"}"
    case "$s" in \[*) s="${s#\[}" ;; *) return 1 ;; esac
    while :; do
        s="${s#"${s%%[![:space:],]*}"}"
        case "$s" in \"*) s="${s#\"}" ;; *) break ;; esac
        v="${s%%\"*}"
        case "$v" in
            *\\*)
                # An escape can hide a quote, so this string is read a
                # character at a time.
                v="" i=0
                while [ "$i" -lt "${#s}" ]; do
                    c="${s:i:1}"
                    if [ "$c" = "\\" ]; then
                        i=$((i + 1))
                        v="$v${s:i:1}"
                    elif [ "$c" = '"' ]; then
                        break
                    else
                        v="$v$c"
                    fi
                    i=$((i + 1))
                done
                s="${s:i+1}"
                ;;
            *)
                # No closing quote: the array ends here.
                [ "$v" != "$s" ] || break
                s="${s#"$v"\"}"
                ;;
        esac
        IS_CLAUDE_EXCLUDES="$IS_CLAUDE_EXCLUDES$v"$'\n'
    done
}

# claude_md_excluded <path> <settings>... - whether an entry of
# claudeMdExcludes in one of the settings files matches <path>. Claude Code
# matches those globs against absolute paths; a Windows path is tried in both
# the Git Bash spelling and the drive spelling (`/d/x`, `D:/x`), and the second
# costs a process, so it is asked for only when the first spelling misses.
claude_md_excluded() {
    local path="$1" alt="" alt_read=0 f pattern
    shift
    for f in "$@"; do
        [ -f "$f" ] || continue
        _claude_excludes_var "$f" || continue
        while IFS= read -r pattern; do
            [ -n "$pattern" ] || continue
            _claude_glob_re_var "$pattern"
            if [[ $path =~ $IS_CLAUDE_GLOB_RE ]]; then return 0; fi
            if [ "$alt_read" = 0 ]; then
                alt_read=1
                if command -v cygpath >/dev/null 2>&1; then alt="$(cygpath -m "$path")"; fi
            fi
            if [ -n "$alt" ] && [[ $alt =~ $IS_CLAUDE_GLOB_RE ]]; then return 0; fi
        done <<< "$IS_CLAUDE_EXCLUDES"
    done
    return 1
}

# claude_double_load_var <root> <manifest> - IS_CLAUDE_DOUBLE_LOAD, why Claude
# Code loads the always-on rules twice here, or empty when it does not; and
# IS_CLAUDE_DOUBLE_LOAD_JSON, the settings entry that stops it. A target
# without an output renders where the engine puts it.
# shellcheck disable=SC2034  # both are the return channel check.sh and sync.sh read
claude_double_load_var() {
    local root="$1" manifest="$2" claude_out agents_md
    IS_CLAUDE_DOUBLE_LOAD="" IS_CLAUDE_DOUBLE_LOAD_JSON=""
    load_targets_cache "$manifest"
    target_enabled_var "$manifest" claude
    [ "$IS_TGT_ENABLED" = 1 ] || return 0
    target_enabled_var "$manifest" agents
    [ "$IS_TGT_ENABLED" = 1 ] || return 0
    target_output_var "$manifest" agents
    agents_output_path_var "${IS_TGT_OUTPUT:-.agents}"
    adapter_contract_rel_path "$IS_AGENTS_OUTPUT_PATH"
    agents_md="$IS_ADAPTER_REL_PATH"
    target_output_var "$manifest" claude
    adapter_contract_rel_path "${IS_TGT_OUTPUT:-.claude}"
    claude_out="$IS_ADAPTER_REL_PATH"
    case "/$agents_md" in
        */.agents/*) return 0 ;;
        */AGENTS.md) ;;
        *) return 0 ;;
    esac
    if claude_md_above "$root" || [ -e "$root/$claude_out/CLAUDE.md" ] \
        || claude_md_excluded "$root/$agents_md" \
            "$root/$claude_out/settings.json" "$root/$claude_out/settings.local.json"; then
        return 0
    fi
    IS_CLAUDE_DOUBLE_LOAD="Claude Code 2.1.277 and later reads $agents_md when there is no CLAUDE.md, $claude_out/CLAUDE.md or CLAUDE.local.md, so the always-on rules load twice: from $claude_out/rules/ and from $agents_md. Sync never edits settings; put this key in $claude_out/settings.json:"
    IS_CLAUDE_DOUBLE_LOAD_JSON="{ \"claudeMdExcludes\": [\"**/$agents_md\"] }"
}
