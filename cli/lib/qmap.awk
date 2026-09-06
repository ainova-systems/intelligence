# Shared tokenizer for the CLI-owned quoted-key map and scalar document shape.
# Reader modes ignore unrelated YAML. Lock mode validates the whole document
# before publishing rows, so a bad later entry never yields a partial result.
BEGIN {
    mode = ENVIRON["QMAP_MODE"]
    block = ENVIRON["QMAP_BLOCK"]
    wanted_key = ENVIRON["QMAP_KEY"]
    wanted_field = ENVIRON["QMAP_FIELD"]
    expected_version = ENVIRON["QMAP_EXPECTED_VERSION"]
    source_file = ENVIRON["QMAP_FILE"]
    strict = (mode == "lock" || mode == "validate")
    sep = sprintf("%c", 31)
    single_quote = sprintf("%c", 39)
}

function error_at(reason, line) {
    if (problem == "") {
        problem = reason
        problem_line = line
    }
}

# quoted() also parses keys. quote_end leaves the caller at the delimiter;
# decoded contains literal bytes, with the writer's two escapes decoded once.
function quoted(s,    i, c, escaped) {
    decoded = ""
    quote_end = 0
    for (i = 2; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\"") {
            quote_end = i
            return 1
        }
        if (c == "\\") {
            if (++i > length(s)) return 0
            escaped = substr(s, i, 1)
            if (escaped == "\\" || escaped == "\"") c = escaped
            else {
                if (strict) return 0
                c = "\\" escaped
            }
        }
        if (strict && c ~ /[[:cntrl:]]/) return 0
        decoded = decoded c
    }
    return 0
}

function scalar(s,    tail) {
    decoded = ""
    empty_scalar = 0
    sub(/^[ \t]+/, "", s)
    if (s == "" || s ~ /^#/) {
        empty_scalar = 1
        return 1
    }
    if (s ~ /^"/) {
        if (!quoted(s)) return 0
        tail = substr(s, quote_end + 1)
        return !strict || tail ~ /^([ \t]*|[ \t]+#.*)$/
    }
    sub(/[ \t]+#.*$/, "", s)
    sub(/[ \t]+$/, "", s)
    if (strict) {
        if (s ~ /[[:cntrl:]]/ || substr(s, 1, 1) == single_quote) return 0
        if (s ~ /^[!&*\[\]{}>|%@`]/ || s ~ /^[?:-]([ \t]|$)/ || s ~ /"|:[ \t]/) return 0
        if (s ~ /^(null|Null|NULL|~|true|True|TRUE|false|False|FALSE)$/) return 0
    }
    decoded = s
    return 1
}

# Tokenization is shared by permissive reads and strict lock validation.
function token(line,    text, colon, tail) {
    kind = ""
    key = ""
    value = ""
    empty = 0
    if (line ~ /^[A-Za-z_]/) {
        kind = "top"
        text = line
    } else if (line ~ /^    [A-Za-z_]/) {
        kind = "field"
        text = substr(line, 5)
    } else if (line ~ /^  "/) {
        kind = "package"
        text = substr(line, 3)
        if (!quoted(text)) return 0
        key = decoded
        tail = substr(text, quote_end + 1)
        if (substr(tail, 1, 1) != ":") return 0
        if (!scalar(substr(tail, 2))) return 0
        value = decoded
        empty = empty_scalar
        return 1
    } else return 0
    colon = index(text, ":")
    if (!colon) return 0
    key = substr(text, 1, colon - 1)
    if (strict && key !~ /^[A-Za-z_][A-Za-z0-9_]*$/) return 0
    if (!scalar(substr(text, colon + 1))) return 0
    value = decoded
    empty = empty_scalar
    return 1
}

{
    sub(/\r$/, "")
    if ($0 ~ /^[ \t]*(#.*)?$/) next
    if (!token($0)) {
        if (strict) {
            context = ""
            if (key ~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
                if (kind == "field" && package != "") context = "package " package ", field " key ": "
                else if (kind == "top") context = "field " key ": "
            }
            error_at(context "malformed lock structure or unsupported scalar", NR)
        }
        if ($0 ~ /^[^ #\t]/) { in_block = 0; package = "" }
        next
    }
    if (kind == "top") {
        in_block = (key == block && empty)
        package = ""
        if (strict && top_seen[key]++) error_at("duplicate top-level field " key, NR)
        if (!(key in top_value)) top_value[key] = value
        if (mode == "top" && key == wanted_key && !found) { result = value; found = 1 }
        if (strict) {
            if (key == block) {
                block_seen = 1
                if (!empty) error_at(block " must be a block map", NR)
            } else if (empty) error_at("expected scalar for " key, NR)
        }
        next
    }
    if (kind == "package" && in_block) {
        package = key
        row_count++
        row_name[row_count] = key
        row_line[row_count] = NR
        if (strict) {
            if (key == "") error_at("empty package key", NR)
            if (package_seen[key]++) error_at("duplicate package " key, NR)
            if (!empty) error_at("expected field map for " key, NR)
        }
        if (mode == "value" && key == wanted_key && !found) { result = value; found = 1 }
        next
    }
    if (kind == "field" && in_block && package != "") {
        identity = package SUBSEP key
        if (strict && field_seen[identity]++) error_at("duplicate field " package "." key, NR)
        if (!(identity in field_value)) field_value[identity] = value
        if (strict && empty) error_at("expected scalar for " package "." key, NR)
        if (mode == "field" && package == wanted_key && key == wanted_field && !found) {
            result = value
            found = 1
        }
        next
    }
    if (strict) error_at("malformed lock structure: expected top-level scalar or quoted package field", NR)
}

END {
    # Read the format header before interpreting a future body's shape. Errors
    # were retained during the single pass so header placement does not matter.
    if (mode == "lock" && top_value["lockfile_version"] != expected_version) {
        version = top_value["lockfile_version"]
        print source_file " has unsupported or missing lockfile_version '" (version == "" ? "<missing>" : version) "' — expected " expected_version > "/dev/stderr"
        exit 1
    }
    if (strict && problem != "") {
        print source_file ":" problem_line ": " problem > "/dev/stderr"
        exit 1
    }
    if (strict && !block_seen) {
        print source_file ": missing " block " block" > "/dev/stderr"
        exit 1
    }
    if (mode == "lock") print "V" sep top_value["lockfile_version"] sep top_value["engine_version"]
    if (mode == "rows" || mode == "lock" || mode == "keys") {
        for (i = 1; i <= row_count; i++) {
            name = row_name[i]
            if (mode == "keys") print name
            else {
                row = name sep field_value[name SUBSEP "requested"] sep field_value[name SUBSEP "url"] sep field_value[name SUBSEP "path"] sep field_value[name SUBSEP "resolved"] sep field_value[name SUBSEP "sha"]
                if (mode == "lock") print "R" sep row sep row_line[i]
                else print row
            }
        }
    } else if (found) print result
}
