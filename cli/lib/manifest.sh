#!/bin/bash
# The CLI-owned YAML shapes: quoted-key maps (`packages:`, `registries:` in
# the manifest, `packages:` in the lock and in registry indexes).
#
# The engine deliberately never reads these blocks, and its readers cannot
# hold `@scope/name` keys — so this is the CLI's single, deliberate parser,
# scoped to exactly one shape:
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
}

# qmap_keys <file> <block> — quoted keys, one per line.
qmap_keys() {
    [ -f "$1" ] || return 0
    awk -v block="$2" '
        { sub(/\r$/, "") }
        $0 ~ "^" block ":[ \t]*$" { inb = 1; next }
        inb && /^[^ #]/ { inb = 0 }
        inb {
            if ($0 ~ /^  "/) {
                s = substr($0, 4)
                q = index(s, "\"")
                if (q > 0) print substr(s, 1, q - 1)
            }
        }
    ' "$1"
}

# qmap_field <file> <block> <key> <field> — 4-indent field value under a
# quoted key; strips surrounding quotes and a trailing unquoted comment.
qmap_field() {
    [ -f "$1" ] || return 0
    awk -v block="$2" -v key="$3" -v field="$4" '
        { sub(/\r$/, "") }
        $0 ~ "^" block ":[ \t]*$" { inb = 1; next }
        inb && /^[^ #]/ { inb = 0; ink = 0 }
        inb && /^  "/ {
            s = substr($0, 4); q = index(s, "\"")
            ink = (q > 0 && substr(s, 1, q - 1) == key)
            next
        }
        inb && ink && /^    [A-Za-z_]/ {
            line = $0
            sub(/^    /, "", line)
            c = index(line, ":")
            if (c == 0) next
            if (substr(line, 1, c - 1) != field) next
            v = substr(line, c + 1)
            sub(/^[ \t]+/, "", v)
            if (v ~ /^"/) { v = substr(v, 2); q2 = index(v, "\""); if (q2 > 0) v = substr(v, 1, q2 - 1) }
            else { sub(/[ \t]+#.*$/, "", v); sub(/[ \t]+$/, "", v) }
            print v
            exit
        }
    ' "$1"
}

# qmap_value <file> <block> <key> — flat form: `  "key": "value"`.
qmap_value() {
    [ -f "$1" ] || return 0
    awk -v block="$2" -v key="$3" '
        { sub(/\r$/, "") }
        $0 ~ "^" block ":[ \t]*$" { inb = 1; next }
        inb && /^[^ #]/ { inb = 0 }
        inb && /^  "/ {
            s = substr($0, 4); q = index(s, "\"")
            if (q == 0 || substr(s, 1, q - 1) != key) next
            v = substr(s, q + 1)
            sub(/^:[ \t]*/, "", v)
            if (v ~ /^"/) { v = substr(v, 2); q2 = index(v, "\""); if (q2 > 0) v = substr(v, 1, q2 - 1) }
            else { sub(/[ \t]+#.*$/, "", v); sub(/[ \t]+$/, "", v) }
            if (v != "") print v
            exit
        }
    ' "$1"
}

# _qmap_stage <file> <awk-program> [awk args…] — run an editing pass, verify
# it produced output, commit.
_qmap_stage() {
    local file="$1"; shift
    local tmp="$file.cli.tmp"
    awk "$@" "$file" > "$tmp"
    [ -s "$tmp" ] || { rm -f "$tmp"; die "internal: manifest edit produced an empty file for $file"; }
    mv "$tmp" "$file"
}

# qmap_set <file> <block> <key> <field> <value> — upsert one field, creating
# the block and the key as needed.
qmap_set() {
    local file="$1" block="$2" key="$3" field="$4" value="$5"
    [ -f "$file" ] || die "no such file: $file"
    _qmap_stage "$file" -v block="$block" -v key="$key" -v field="$field" -v value="$value" '
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
        { print }
        END {
            flush_key(); flush_block()
            if (!blockseen) {
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
    _qmap_stage "$file" -v block="$block" -v key="$key" -v value="$value" '
        function entry() { return "  \"" key "\": \"" value "\"" }
        { sub(/\r$/, "") }
        $0 ~ "^" block ":[ \t]*$" { blockseen = 1; inb = 1; print; next }
        inb && /^[^ #]/ { if (!done) { print entry(); done = 1 }; inb = 0 }
        inb && /^  "/ {
            s = substr($0, 4); q = index(s, "\"")
            if (q > 0 && substr(s, 1, q - 1) == key) { print entry(); done = 1; next }
        }
        { print }
        END {
            if (inb && !done) { print entry(); done = 1 }
            if (!blockseen) { print block ":"; print entry() }
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

# sources_remove_entry <file> <section> <entry> — remove `- "entry"` from
# sources.<section>. Inverse of the engine-side _mig_add_source.
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
