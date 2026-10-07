#!/bin/bash
# The CLI-owned YAML shapes: quoted-key maps (`packages:`, `registries:` in
# the manifest, `packages:` in the lock and in registry indexes).
#
# The engine reads none of these blocks beyond the names and aliases in
# `packages:`, which resolve package references in `sources:`
# (engine/lib/common.sh), and its list readers cannot hold `@scope/name` keys —
# so this is the CLI's single, deliberate parser, scoped to exactly one shape:
#
#   block:
#     "@scope/name":            # 2-space indent, key always quoted
#       field: "value"          # 4-space indent
#     "@scope/other": "value"   # flat form (registries)
#
# Every editor stages to `<file>.cli.tmp` and `mv`s — the migrations
# discipline — and preserves unrelated lines and comments byte-for-byte.

# Package names are paths (store dirs) and YAML keys, so the charset is
# closed: scoped, one slash, no spaces / quotes / colons.
assert_valid_pkg_name() {
    case "$1" in
        @*/*) ;;
        *) die "invalid package name '$1' — expected @scope/name" ;;
    esac
    case "$1" in
        *[!@/A-Za-z0-9._-]*|*/*/*) die "invalid package name '$1' — allowed: letters, digits, . _ -, one '/'" ;;
    esac
    # Both segments become store path components fed to rm -rf: an empty one
    # ('@scope/') resolves to the whole scope dir, and a dot segment walks the
    # tree — either would turn one bad --name into deleting other packages.
    local scope="${1%%/*}" short="${1#*/}"
    case "${scope#@}" in
        ""|.|..) die "invalid package name '$1' — empty or dot scope" ;;
    esac
    case "$short" in
        ""|.|..) die "invalid package name '$1' — empty or dot name" ;;
    esac
}

# Target names become adapter filenames and shell function suffixes, so keep
# them inside the portable shell-identifier subset used by built-in adapters.
assert_valid_target_name() {
    case "$1" in
        ""|[!abcdefghijklmnopqrstuvwxyz]*|*[!abcdefghijklmnopqrstuvwxyz0123456789_]*)
            die "invalid target name '$1' — expected [a-z][a-z0-9_]*"
            ;;
    esac
}

# target_exists <manifest> <name> — distinguish a disabled target from one
# that is not declared at all. Both inline and block target shapes count.
target_exists() {
    local file="$1" target="$2"
    [ -f "$file" ] || return 1
    awk -v target="$target" '
        { sub(/\r$/, "") }
        /^targets:[[:space:]]*$/ { in_targets = 1; next }
        /^[A-Za-z]/ { in_targets = 0 }
        in_targets && $0 ~ "^  " target ":[[:space:]]*" { found = 1; exit }
        END { exit(found ? 0 : 1) }
    ' "$file"
}

# target_names <manifest> — declared target keys in manifest order.
target_names() {
    local file="$1"
    [ -f "$file" ] || return 0
    awk '
        { sub(/\r$/, "") }
        /^targets:[[:space:]]*$/ { in_targets = 1; next }
        in_targets && /^[A-Za-z]/ { in_targets = 0 }
        in_targets && /^  [a-z][a-z0-9_]*:/ {
            line = $0
            sub(/^  /, "", line)
            sub(/:.*/, "", line)
            print line
        }
    ' "$file"
}

# target_set_enabled <manifest> <name> <true|false> <default-output>
# Transactionally update only `enabled`, preserving every other target field
# and comment. A missing target is added in the compact form used by init.
target_set_enabled() {
    local file="$1" target="$2" enabled="$3" output="$4"
    local target_missing=1
    [ -f "$file" ] || die "no such file: $file"
    case "$enabled" in true|false) ;; *) die "internal: invalid target state '$enabled'" ;; esac
    target_exists "$file" "$target" && target_missing=0
    output="$(_yq_esc "$output")"
    QMAP_EDIT_VALUE="$output" _qmap_stage "$file" -v target="$target" -v enabled="$enabled" -v target_missing="$target_missing" '
        BEGIN { output = ENVIRON["QMAP_EDIT_VALUE"] }
        function entry() { return "  " target ": { enabled: " enabled ", output: \"" output "\" }" }
        function insert_missing_target() {
            if (in_targets && target_missing && !target_seen) { print entry(); target_seen = 1 }
        }
        function add_enabled_to_inline(line,    p) {
            p = index(line, "{")
            if (p > 0) return substr(line, 1, p) " enabled: " enabled "," substr(line, p + 1)
            return line
        }
        function flush_target() {
            if (in_target && !enabled_seen) print "    enabled: " enabled
            in_target = 0
        }
        function flush_targets() {
            flush_target()
            if (in_targets && !target_seen) { print entry(); target_seen = 1 }
            in_targets = 0
        }
        { sub(/\r$/, "") }
        /^targets:[[:space:]]*$/ { targets_seen = 1; in_targets = 1; print; next }
        in_targets && target_missing && target_entry_seen && /^#/ {
            flush_target()
            insert_missing_target()
            print
            next
        }
        # A blank line is not a target-section boundary: it may belong to a
        # block scalar such as targets.agents.header. Wait until the target
        # list reaches a top-level comment/key or EOF before inserting.
        in_targets && /^[A-Za-z]/ { flush_targets() }
        in_targets && /^  [A-Za-z]/ {
            target_entry_seen = 1
            flush_target()
            if ($0 ~ "^  " target ":[[:space:]]*") {
                target_seen = 1
                if (match($0, /enabled:[[:space:]]*(true|false)/)) {
                    print substr($0, 1, RSTART - 1) "enabled: " enabled substr($0, RSTART + RLENGTH)
                    enabled_seen = 1
                } else if ($0 ~ /\{/) {
                    print add_enabled_to_inline($0)
                    enabled_seen = 1
                } else {
                    print
                    in_target = 1
                    enabled_seen = 0
                }
                next
            }
        }
        in_target && /^    enabled:[[:space:]]*/ {
            print "    enabled: " enabled
            enabled_seen = 1
            next
        }
        { last = $0; print }
        END {
            flush_targets()
            if (!targets_seen) {
                if (last != "") print ""
                print "targets:"
                print entry()
            }
        }
    '
}

# _qmap_read <mode> <file> <block> [key] [field] [expected-lock-version]
# All scalar reads and strict lock records share one tokenizer. Environment
# transport preserves literal backslashes that awk -v would interpret again.
_qmap_read() {
    local mode="$1" file="$2"
    if [ ! -f "$file" ] || [ ! -r "$file" ]; then
        case "$mode" in
            lock|validate) echo "cannot read $file" >&2; return 1 ;;
            *) return 0 ;;
        esac
    fi
    QMAP_MODE="$mode" QMAP_FILE="$file" QMAP_BLOCK="${3:-}" \
        QMAP_KEY="${4:-}" QMAP_FIELD="${5:-}" QMAP_EXPECTED_VERSION="${6:-}" \
        LC_ALL=C awk -f "${BASH_SOURCE[0]%/*}/qmap.awk" < "$file"
}

# qmap_validate_document <file> <block> — structural validation only.
qmap_validate_document() { _qmap_read validate "$1" "$2"; }

# qmap_keys <file> <block> — quoted keys in document order.
qmap_keys() { _qmap_read keys "$1" "$2"; }

# qmap_field <file> <block> <key> <field> — decoded nested scalar.
qmap_field() { _qmap_read field "$1" "$2" "$3" "$4"; }

# qmap_value <file> <block> <key> — decoded flat scalar.
qmap_value() { _qmap_read value "$1" "$2" "$3"; }

# _qmap_stage <file> <awk-program> [awk args…] — run an editing pass, verify
# it produced output, commit. An editor that cannot place its edit exits
# non-zero; the staged file is dropped so a refused edit never reaches the
# manifest half-applied.
_qmap_stage() {
    local file="$1"; shift
    local tmp="$file.cli.tmp" rc=0
    awk "$@" "$file" > "$tmp" || rc=$?
    [ "$rc" -eq 0 ] || { rm -f "$tmp"; die "internal: manifest edit refused (awk exit $rc) for $file"; }
    [ -s "$tmp" ] || { rm -f "$tmp"; die "internal: manifest edit produced an empty file for $file"; }
    mv "$tmp" "$file"
}

# qmap_set <file> <block> <key> <field> <value> — upsert one field, creating
# the block and the key as needed.
# _yq_esc <string> — escape \ and " for a double-quoted YAML scalar.
_yq_esc() {
    local s="$1"
    s="${s//\\/\\\\}"
    printf '%s' "${s//\"/\\\"}"
}

qmap_set() {
    local file="$1" block="$2" key="$3" field="$4" value="$5"
    [ -f "$file" ] || die "no such file: $file"
    # url/path values can carry a `"`; escape before it reaches the quoted
    # scalar the writer emits.
    value="$(_yq_esc "$value")"
    QMAP_EDIT_VALUE="$value" _qmap_stage "$file" -v block="$block" -v key="$key" -v field="$field" '
        BEGIN { value = ENVIRON["QMAP_EDIT_VALUE"] }
        function keyline()   { return "  \"" key "\":" }
        function fieldline() { return "    " field ": \"" value "\"" }
        function flush_key() {
            # leaving the key without having written the field -> append it
            if (ink && !done) { print fieldline(); done = 1 }
            ink = 0
        }
        function flush_block() {
            if (inb && !keyseen && !done) { print keyline(); print fieldline(); keyseen = 1; done = 1 }
            inb = 0
        }
        { sub(/\r$/, "") }
        $0 ~ "^" block ":[ \t]*$" { blockseen = 1; inb = 1; print; next }
        inb && /^[^ #]/ { flush_key(); flush_block() }
        inb && /^  "/ {
            flush_key()
            s = substr($0, 4); q = index(s, "\"")
            if (q > 0 && substr(s, 1, q - 1) == key) { keyseen = 1; ink = 1 }
            print; next
        }
        inb && ink && /^    [A-Za-z_]/ {
            line = $0; sub(/^    /, "", line)
            c = index(line, ":")
            if (c > 0 && substr(line, 1, c - 1) == field) { print fieldline(); done = 1; next }
            print; next
        }
        { last = $0; print }
        END {
            flush_key(); flush_block()
            if (!blockseen) {
                # A block appended to a file that does not end blank would
                # otherwise glue itself onto the previous section.
                if (last != "") print ""
                print block ":"
                print keyline()
                print fieldline()
            }
        }
    '
}

# qmap_set_value <file> <block> <key> <value> — flat-form upsert.
qmap_set_value() {
    local file="$1" block="$2" key="$3" value="$4"
    [ -f "$file" ] || die "no such file: $file"
    value="$(_yq_esc "$value")"
    QMAP_EDIT_VALUE="$value" _qmap_stage "$file" -v block="$block" -v key="$key" '
        BEGIN { value = ENVIRON["QMAP_EDIT_VALUE"] }
        function entry() { return "  \"" key "\": \"" value "\"" }
        { sub(/\r$/, "") }
        $0 ~ "^" block ":[ \t]*$" { blockseen = 1; inb = 1; print; next }
        inb && /^[^ #]/ { if (!done) { print entry(); done = 1 }; inb = 0 }
        inb && /^  "/ {
            s = substr($0, 4); q = index(s, "\"")
            if (q > 0 && substr(s, 1, q - 1) == key) { print entry(); done = 1; next }
        }
        { last = $0; print }
        END {
            if (inb && !done) { print entry(); done = 1 }
            if (!blockseen) {
                if (last != "") print ""
                print block ":"
                print entry()
            }
        }
    '
}

# qmap_delete_key <file> <block> <key> — drop the key and everything indented
# under it. Flat-form entries are one line, block-form keys take their fields
# with them. The block header stays even when it empties.
qmap_delete_key() {
    local file="$1" block="$2" key="$3"
    [ -f "$file" ] || return 0
    _qmap_stage "$file" -v block="$block" -v key="$key" '
        { sub(/\r$/, "") }
        $0 ~ "^" block ":[ \t]*$" { inb = 1; print; next }
        inb && /^[^ #]/ { inb = 0; drop = 0 }
        inb && /^  "/ {
            s = substr($0, 4); q = index(s, "\"")
            drop = (q > 0 && substr(s, 1, q - 1) == key)
            if (drop) next
        }
        inb && drop && /^    / { next }
        { print }
    '
}

# qmap_delete_field <file> <block> <key> <field> — drop one field from a
# quoted-key entry without disturbing its other fields or surrounding YAML.
qmap_delete_field() {
    local file="$1" block="$2" key="$3" field="$4"
    [ -f "$file" ] || return 0
    _qmap_stage "$file" -v block="$block" -v key="$key" -v field="$field" '
        { sub(/\r$/, "") }
        $0 ~ "^" block ":[ \t]*$" { inb = 1; print; next }
        inb && /^[^ #]/ { inb = 0; ink = 0 }
        inb && /^  "/ {
            s = substr($0, 4); q = index(s, "\"")
            ink = (q > 0 && substr(s, 1, q - 1) == key)
            print; next
        }
        inb && ink && /^    [A-Za-z_]/ {
            line = $0; sub(/^    /, "", line)
            c = index(line, ":")
            if (c > 0 && substr(line, 1, c - 1) == field) next
        }
        { print }
    '
}

# --- registries: a trust LIST, not a scope map -----------------------------
# The block holds registry repo URLs in trust order. Two shapes are read so
# early manifests keep working: the list form (`- "url"`) and the retired
# flat-map form (`"@scope": "url"` — the scope label is ignored, the URL is
# simply another registry).

# registries_list <file> — registry URLs, one per line, manifest order.
registries_list() {
    [ -f "$1" ] || return 0
    awk '
        { sub(/\r$/, "") }
        /^registries:[ \t]*$/ { inb = 1; next }
        inb && /^[^ #]/ { inb = 0 }
        inb {
            line = $0
            if (line ~ /^[ \t]*-[ \t]*/) {
                sub(/^[ \t]*-[ \t]*/, "", line)
            } else if (line ~ /^  "/) {
                c = index(line, ":")
                if (c == 0) next
                line = substr(line, c + 1)
            } else next
            sub(/^[ \t]+/, "", line)
            gsub(/["\x27]/, "", line)
            sub(/[ \t]+#.*$/, "", line)
            sub(/[ \t]+$/, "", line)
            if (line != "") print line
        }
    ' "$1"
}

# registries_add <file> <url> — idempotent append in list form.
registries_add() {
    local file="$1" url="$2" existing
    while IFS= read -r existing; do
        [ "$existing" = "$url" ] && return 0
    done < <(registries_list "$file")
    _qmap_stage "$file" -v url="$url" '
        function entry() { return "  - \"" url "\"" }
        { sub(/\r$/, "") }
        /^registries:[ \t]*$/ { blockseen = 1; inb = 1; print; next }
        inb && /^[^ #]/ { if (!done) { print entry(); done = 1 }; inb = 0 }
        { last = $0; print }
        END {
            if (inb && !done) { print entry(); done = 1 }
            if (!blockseen) {
                if (last != "") print ""
                print "registries:"
                print entry()
            }
        }
    '
}

# registries_remove <file> <url> — drop the entry, either shape.
registries_remove() {
    local file="$1" url="$2"
    [ -f "$file" ] || return 0
    _qmap_stage "$file" -v url="$url" '
        { sub(/\r$/, "") }
        /^registries:[ \t]*$/ { inb = 1; print; next }
        inb && /^[^ #]/ { inb = 0 }
        inb {
            line = $0
            v = ""
            if (line ~ /^[ \t]*-[ \t]*/) { v = line; sub(/^[ \t]*-[ \t]*/, "", v) }
            else if (line ~ /^  "/) { c = index(line, ":"); if (c > 0) v = substr(line, c + 1) }
            if (v != "") {
                sub(/^[ \t]+/, "", v)
                gsub(/["\x27]/, "", v)
                sub(/[ \t]+#.*$/, "", v)
                sub(/[ \t]+$/, "", v)
                if (v == url) next
            }
        }
        { print }
    '
}
# --- sources: an ORDERED list of content directories ------------------------
# Adapters copy sources in order and the last write wins, so position carries
# meaning: a later entry overrides a same-named artifact from an earlier one.
# Reading goes through the engine's own list parser, so the CLI sees exactly
# what the engine will render instead of a second reading of the same file.
# The editors read it raw — a package reference as written, which is what they
# compare and rewrite — and read_source_entries says what each one renders.

# sources_list_entries <file> <section> — entries of sources.<section> as
# written, one per line, in manifest order.
sources_list_entries() {
    [ -f "$1" ] || return 0
    read_yaml_list_raw "$1" "$2"
}

# sources_has_entry <file> <section> <entry> — true (0) when that section lists
# exactly this entry. Section-scoped and exact on purpose: one directory may
# legitimately appear under two sections, and a substring test over the whole
# file would silently refuse the second add — and would match a bare `- docs`
# against a neighbouring `- docs/api`.
sources_has_entry() {
    local file="$1" section="$2" entry="$3" listed
    [ -f "$file" ] || return 1
    while IFS= read -r listed; do
        [ "$listed" = "$entry" ] && return 0
    done < <(sources_list_entries "$file" "$section")
    return 1
}

# sources_add_entry <file> <section> <entry> [position] [anchor]
# Idempotent insert into sources.<section>, creating `sources:` and the section
# as needed. Position is `last` (default), `first`, `before` or `after`; the
# anchored forms take <anchor>, an entry the section already lists. The caller
# validates the anchor, and an edit that cannot be placed exits 3 rather than
# landing the entry somewhere else — a silently misplaced source changes which
# artifact wins.
sources_add_entry() {
    local file="$1" section="$2" entry="$3" pos="${4:-last}" anchor="${5:-}"
    sources_has_entry "$file" "$section" "$entry" && return 0
    _qmap_stage "$file" -v section="$section" -v entry="$entry" -v pos="$pos" -v anchor="$anchor" '
        function line() { return "    - \"" entry "\"" }
        function place() { print line(); done = 1 }
        # Blank lines inside sources: are held back so an insert lands next to
        # the entries it belongs with, not after the blank line that separates
        # one section from the next.
        function flush_tail(   i) { for (i = 1; i <= ntail; i++) print tail[i]; blanks = ntail; ntail = 0 }
        function open_section() { flush_tail(); print "  " section ":"; place(); if (blanks) print "" }
        function value(s,   v) {
            v = s
            sub(/^[ \t]*-[ \t]*/, "", v)
            gsub(/["\x27]/, "", v)
            sub(/[ \t]+#.*$/, "", v)
            sub(/[ \t]+$/, "", v)
            return v
        }
        BEGIN { anchored = (pos == "before" || pos == "after") }
        { sub(/\r$/, "") }
        /^sources:[ \t]*$/ { ins = 1; sourceseen = 1; print; next }
        ins && /^[^ #]/ {
            if (insec) { if (!done && pos == "last") place(); insec = 0 }
            if (!secseen && !done && !anchored) { open_section(); secseen = 1 }
            else flush_tail()
            ins = 0
        }
        ins && !insec && $0 ~ "^  " section ":[ \t]*$" {
            flush_tail(); secseen = 1; insec = 1; print
            if (pos == "first") place()
            next
        }
        ins && insec && /^  [A-Za-z_]/ {
            if (!done && pos == "last") place()
            insec = 0
            flush_tail()
        }
        insec && /^[ \t]*-/ {
            flush_tail()
            v = value($0)
            if (pos == "before" && v == anchor && !done) place()
            print
            if (pos == "after" && v == anchor && !done) place()
            next
        }
        ins && /^[ \t]*$/ { tail[++ntail] = $0; next }
        ins { flush_tail(); print; next }
        { last = $0; print }
        END {
            if (insec && !done && pos == "last") place()
            flush_tail()
            if (!done && !anchored) {
                if (ins && !secseen) { print "  " section ":"; place() }
                else if (!sourceseen) {
                    if (last != "") print ""
                    print "sources:"; print "  " section ":"; place()
                }
            }
            if (!done) exit 3
        }
    '
}

# sources_add_entry_first <file> <section> <entry> — insert at the TOP of
# sources.<section>. Package wiring uses it so project-owned entries stay later
# in the list — adapters copy sources in order and the last write wins, which
# is exactly the documented "your file overrides the package's" behavior.
sources_add_entry_first() {
    sources_add_entry "$1" "$2" "$3" first
}

# sources_remove_entry <file> <section> <entry> — remove `- "entry"` from
# sources.<section>.
sources_remove_entry() {
    local file="$1" section="$2" entry="$3"
    [ -f "$file" ] || return 0
    _qmap_stage "$file" -v section="$section" -v entry="$entry" '
        { sub(/\r$/, "") }
        /^sources:[ \t]*$/ { ins = 1; print; next }
        ins && /^[^ #]/ { ins = 0; insec = 0 }
        ins && $0 ~ "^  " section ":[ \t]*$" { insec = 1; print; next }
        ins && /^  [A-Za-z_]/ { insec = 0 }
        insec {
            line = $0
            sub(/^[ \t]*-[ \t]*/, "", line)
            gsub(/["\x27]/, "", line)
            sub(/[ \t]+#.*$/, "", line)
            sub(/[ \t]+$/, "", line)
            if (line == entry) next
        }
        { print }
    '
}

# --- package references and aliases ------------------------------------------
# `sources:` may name a package's directory by its store path, by the package's
# full name or by the alias its `packages:` entry declares (decision 0019). The
# engine's list parser (IS_PKG_REF_AWK in engine/lib/common.sh) is the only
# definition of those spellings; everything below reads through it, so the CLI
# never judges an entry differently from the way the engine renders it. The CLI
# itself only ever writes store paths, and writes an alias only through
# `package add --alias` and `package alias`.

# assert_valid_alias <alias> — refuse an alias the engine would never resolve.
assert_valid_alias() {
    pkg_alias_valid "$1" \
        || die "invalid alias '$1' — expected $IS_PKG_ALIAS_RULE"
}

# package_alias_of <file> <@scope/name> — the alias that package declares, when it
# is well formed; nothing otherwise (an invalid one resolves nothing).
package_alias_of() {
    local name alias verdict
    while IFS=$'\037' read -r name alias verdict; do
        [ "$name" = "$2" ] || continue
        [ "$verdict" = invalid ] || printf '%s' "$alias"
        return 0
    done < <(read_package_aliases "$1")
}

# assert_alias_free <file> <@scope/name> <alias> — refuse an alias another package
# already declares: one alias names exactly one package.
assert_alias_free() {
    local file="$1" self="$2" want="$3" name alias verdict
    while IFS=$'\037' read -r name alias verdict; do
        [ "$name" != "$self" ] && [ "$alias" = "$want" ] || continue
        die "alias '$want' already names $name — one alias names one package; choose another"
    done < <(read_package_aliases "$file")
}

# sources_alias_users <file> <alias> — every sources entry spelled <alias>:<dir>,
# one `sources.<section> '<entry>'` line each.
sources_alias_users() {
    local file="$1" alias="$2" section entry
    for section in rules agents skills; do
        while IFS= read -r entry; do
            case "$entry" in
                "$alias":*) printf "sources.%s '%s'\n" "$section" "$entry" ;;
            esac
        done < <(sources_list_entries "$file" "$section")
    done
}

# assert_alias_unused <file> <@scope/name> <alias> <remove|replace> — refuse to
# take away an alias `sources:` still spells entries with: they would stop
# resolving, and the package's content would leave the outputs in silence.
assert_alias_unused() {
    local file="$1" name="$2" alias="$3" verb="$4" users
    users="$(sources_alias_users "$file" "$alias")"
    [ -n "$users" ] || return 0
    echo "ERROR: cannot $verb alias '$alias' of $name — sources: still uses it:" >&2
    printf '%s\n' "$users" | sed 's/^/  /' >&2
    echo "  Spell those entries $name/<dir> instead, then $verb the alias." >&2
    exit 1
}

# sources_classify_entry <file> <entry> — `<state>\037<directory>` for an entry
# that is not in the manifest (yet): what the engine would render it as against
# the packages the manifest declares. States are pkr_parse's.
sources_classify_entry() {
    local file="$1"
    [ -f "$file" ] || file=/dev/null
    IS_PKR_CANDIDATE="$2" awk "$IS_PKG_REF_AWK"'
        { sub(/\r$/, ""); pkr_collect($0) }
        END { dir = pkr_expand(ENVIRON["IS_PKR_CANDIDATE"]); print PKR_STATE "\037" dir }
    ' "$file"
}

# sources_find_entry <file> <section> <entry> — print the entry of
# sources.<section>, as written, that names the same directory as <entry> in any
# spelling; fail when the section names it nowhere. An entry that renders
# nothing matches only itself.
sources_find_entry() {
    local file="$1" section="$2" entry="$3" want _state raw _st dir _rest
    [ -f "$file" ] || return 1
    IFS=$'\037' read -r _state want <<< "$(sources_classify_entry "$file" "$entry")"
    while IFS=$'\037' read -r raw _st dir _rest; do
        if [ "$raw" = "$entry" ] || { [ -n "$want" ] && [ "$dir" = "$want" ]; }; then
            printf '%s' "$raw"
            return 0
        fi
    done < <(read_source_entries "$file" "$section")
    return 1
}

# package_source_listed <file> <section> <store-dir> — true when sources.<section>
# already names <store-dir>, in whichever spelling.
package_source_listed() {
    local _raw _st dir _rest
    [ -f "$1" ] || return 1
    while IFS=$'\037' read -r _raw _st dir _rest; do
        [ "$dir" = "$3" ] && return 0
    done < <(read_source_entries "$1" "$2")
    return 1
}

# sources_remove_package <file> <@scope/name> [section...] — drop the package's
# entries from sources:, in every spelling. With sections, only the entry of
# sources.<section> that names the package's own <section> directory goes;
# without, every rules/agents/skills entry naming a directory inside the
# package. The references resolve through `packages:`, so call it while the
# package and its alias are still declared. Every other line survives byte for
# byte, and an unchanged file is not rewritten.
sources_remove_package() {
    local file="$1" name="$2" tmp rc=0
    shift 2
    [ -f "$file" ] || return 0
    tmp="$file.cli.tmp"
    awk -v name="$name" -v only=" $* " "$IS_PKG_REF_AWK"'
        BEGIN { store = ".intelligence/packages/" name }
        FNR == 1 { pass++ }
        pass == 1 { sub(/\r$/, ""); pkr_collect($0); next }
        { sub(/\r$/, "") }
        /^sources:[ \t]*$/ { ins = 1; print; next }
        ins && /^[^ #]/ { ins = 0; sec = "" }
        ins && /^  [A-Za-z_]/ {
            sec = $0
            sub(/^  /, "", sec)
            sub(/:.*$/, "", sec)
            if (sec != "rules" && sec != "agents" && sec != "skills") sec = ""
            print
            next
        }
        ins && sec != "" && /^[ \t]*-/ {
            v = $0
            sub(/^[ \t]*-[ \t]*/, "", v)
            gsub(/["\047]/, "", v)
            sub(/[ \t]+#.*$/, "", v)
            sub(/[ \t]+$/, "", v)
            dir = pkr_expand(v)
            if (only == "  ") drop = dir == store || index(dir, store "/") == 1
            else drop = index(only, " " sec " ") && dir == store "/" sec
            if (drop) { changed = 1; next }
        }
        { print }
        END { exit (changed ? 0 : 10) }
    ' "$file" "$file" > "$tmp" || rc=$?
    case "$rc" in
        0)
            [ -s "$tmp" ] || { rm -f "$tmp"; die "internal: sources edit produced an empty file for $file"; }
            mv "$tmp" "$file"
            ;;
        10) rm -f "$tmp" ;;
        *) rm -f "$tmp"; die "internal: sources edit refused (awk exit $rc) for $file" ;;
    esac
}
