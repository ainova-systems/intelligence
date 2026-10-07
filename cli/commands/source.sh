#!/bin/bash
# intelligence source <add|remove|list> — the `sources:` block of the manifest.
#
# Sources are an ORDERED list of directories the engine renders, and the order
# is the override rule: adapters copy in order, the last write wins. So the
# command's real job is placement, and its default is the end of the section —
# the project's own territory, where a directory the project added wins over
# every installed package. `--before` / `--after` cover the other intent:
# content that should behave like a package (a pack developed in the repository
# that ships it) belongs after the store entries and before the project's.
#
# Installed package content is NOT managed here: `.intelligence/` entries are
# written by `package add` and removed by `package remove`, and so are the
# entries that name a package's directory by its full name or alias
# (`@scope/name/<dir>`, `<alias>:<dir>`, decision 0019). Any of those spellings
# is still a valid `--before` / `--after` anchor: that is how a directory lands
# next to a package.
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

USAGE="usage: intelligence source <command>
  add <rules|agents|skills> <dir> [--first|--last|--before <entry>|--after <entry>]
  remove <rules|agents|skills> <dir>
  list"

SECTIONS="rules agents skills"

assert_source_section() {
    case "${1:-}" in
        rules|agents|skills) ;;
        "") die "$USAGE" ;;
        *) die "unknown source kind '$1' — expected rules, agents or skills" ;;
    esac
}

# `normalize_source_dir` reduces `./x/`, `x/.` and `x/./y` to the one spelling
# the manifest stores; it lives beside the classifier in cli-common so a typed
# path and a manifest entry are judged as the same thing. Nothing else is
# repaired — a source entry decides which artifact wins, so a path the user did
# not type is the wrong kind of help.

# assert_not_package_reference <manifest> <dir> <add|remove> — refuse an entry
# the engine reads as a package reference: a directory of a package `packages:`
# declares, by full name or alias, or an alias no package declares. It is
# package territory however it is spelled.
assert_not_package_reference() {
    local state rendered rest pkg
    IFS=$'\037' read -r state rendered <<< "$(sources_classify_entry "$1" "$2")"
    rest="${rendered#.intelligence/packages/}"
    pkg="${rest%%/*}/"
    rest="${rest#*/}"
    pkg="$pkg${rest%%/*}"
    case "$state/$3" in
        path/*) return 0 ;;
        ok/add) die "'$2' names a directory of the installed package $pkg — 'intelligence package add' wires a package's directories into sources" ;;
        ok/remove) die "'$2' is installed package content — remove the package instead: intelligence package remove $pkg" ;;
        */add) die "'$2' is a package reference, not a project directory — 'intelligence package add' wires a package's directories into sources" ;;
        *) die "'$2' is a package reference, not a project directory — 'intelligence package remove <@scope/name>' removes a package's entries" ;;
    esac
}

# assert_valid_source_dir <root> <dir> — refuse what the engine cannot report.
# The shape checks are `source_entry_problem`, shared with `status --check` so
# one definition covers both the entry about to be written and the one already
# in the manifest; the package rules are this command's alone, because a
# package entry is legitimate when `package add` wrote it or a person spelled
# it by the package's name.
assert_valid_source_dir() {
    local root="$1" dir="$2" problem
    [ -n "$dir" ] || die "$USAGE"
    case "$dir" in
        *\\*) die "invalid source '$dir' — manifest paths use '/': ${dir//\\//}" ;;
        .intelligence|.intelligence/*)
            die "'$dir' is inside the CLI-managed package store — install content with 'intelligence package add', and it is wired into sources automatically"
            ;;
    esac
    assert_not_package_reference "$root/intelligence.yaml" "$dir" add
    problem="$(source_entry_problem "$root" "$dir")"
    [ -z "$problem" ] || die "invalid source '$dir': it $problem"
}

# Print one section with its override direction and the state of each entry.
# Position is the whole point of the block, so every mutation ends by showing
# the order it produced rather than only naming what it wrote. Entries are
# listed as written and judged by the directory the engine renders them as.
print_section() {
    local manifest="$1" root="$2" section="$3" entry state dir n=0 note
    echo "sources.$section (a later entry overrides an earlier one):"
    [ -f "$manifest" ] || { echo "  (none)"; return 0; }
    while IFS=$'\037' read -r entry state dir _; do
        [ -n "$entry" ] || continue
        n=$((n + 1))
        note=""
        case "$state" in
            path|ok)
                case "$dir" in
                    .intelligence/*) note="  package" ;;
                esac
                [ -d "$root/$dir" ] || note="$note  MISSING"
                ;;
            *) note="  UNRESOLVED — intelligence status --check" ;;
        esac
        printf '  %d. %s%s\n' "$n" "$entry" "$note"
    done < <(read_source_entries "$manifest" "$section")
    [ "$n" -eq 0 ] && echo "  (none)"
    return 0
}

action="${1:-}"
[ -n "$action" ] || die "$USAGE"
shift

case "$action" in
    add)
        section="${1:-}"
        dir="${2:-}"
        assert_source_section "$section"
        [ -n "$dir" ] || die "$USAGE"
        shift 2
        pos="last"
        anchor=""
        pos_given=0
        while [ $# -gt 0 ]; do
            case "$1" in
                --first|--last)
                    [ "$pos_given" -eq 0 ] || die "only one position may be given"
                    pos="${1#--}"; pos_given=1; shift
                    ;;
                --before|--after)
                    [ "$pos_given" -eq 0 ] || die "only one position may be given"
                    [ -n "${2:-}" ] || die "$1 needs the entry to place this source next to"
                    pos="${1#--}"; anchor="$(normalize_source_dir "$2")"; pos_given=1; shift 2
                    ;;
                *) die "$USAGE" ;;
            esac
        done

        require_cli_project
        dir="$(normalize_source_dir "$dir")"
        assert_valid_source_dir "$IP_ROOT" "$dir"
        [ "$anchor" != "$dir" ] || die "cannot place '$dir' relative to itself"
        ensure_project_current "$IP_ROOT"
        manifest="$IP_ROOT/intelligence.yaml"

        # The anchor may be spelled differently from the entry it means — a
        # package's store path, full name or alias — so it is matched by the
        # directory it names and placed against the entry as written.
        if [ -n "$anchor" ]; then
            if ! listed="$(sources_find_entry "$manifest" "$section" "$anchor")"; then
                echo "ERROR: sources.$section does not list '$anchor'." >&2
                print_section "$manifest" "$IP_ROOT" "$section" >&2
                exit 1
            fi
            anchor="$listed"
        fi

        if sources_has_entry "$manifest" "$section" "$dir"; then
            if [ "$pos_given" -eq 0 ]; then
                echo "already listed: sources.$section holds $dir"
                print_section "$manifest" "$IP_ROOT" "$section"
                exit 0
            fi
            sources_remove_entry "$manifest" "$section" "$dir"
            sources_add_entry "$manifest" "$section" "$dir" "$pos" "$anchor"
            echo "moved: $dir"
        else
            sources_add_entry "$manifest" "$section" "$dir" "$pos" "$anchor"
            echo "added: $dir"
        fi
        if [ ! -d "$IP_ROOT/$dir" ]; then
            echo "WARNING: $dir does not exist yet — sync skips a missing source and renders it once the directory appears." >&2
        fi
        print_section "$manifest" "$IP_ROOT" "$section"
        echo "Run 'intelligence sync' to render it."
        ;;
    remove)
        section="${1:-}"
        dir="${2:-}"
        assert_source_section "$section"
        [ -n "$dir" ] || die "$USAGE"
        [ $# -le 2 ] || die "$USAGE"
        dir="$(normalize_source_dir "$dir")"
        case "$dir" in
            .intelligence|.intelligence/*)
                die "'$dir' is installed package content — remove the package instead: intelligence package remove <@scope/name>"
                ;;
        esac

        require_cli_project
        manifest="$IP_ROOT/intelligence.yaml"
        assert_not_package_reference "$manifest" "$dir" remove
        ensure_project_current "$IP_ROOT"

        if ! sources_has_entry "$manifest" "$section" "$dir"; then
            echo "not listed: sources.$section does not hold $dir"
            print_section "$manifest" "$IP_ROOT" "$section"
            exit 0
        fi
        sources_remove_entry "$manifest" "$section" "$dir"
        echo "removed: $dir"
        echo "  The directory is untouched; its artifacts leave the generated output at the next sync."
        print_section "$manifest" "$IP_ROOT" "$section"
        echo "Run 'intelligence sync' to rewrite the outputs."
        ;;
    list)
        [ $# -eq 0 ] || die "$USAGE"
        require_cli_project
        manifest="$IP_ROOT/intelligence.yaml"
        for section in $SECTIONS; do
            print_section "$manifest" "$IP_ROOT" "$section"
        done
        ;;
    *)
        die "$USAGE"
        ;;
esac
