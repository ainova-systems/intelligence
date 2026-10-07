# Shared tokenizer for the CLI-owned quoted-key map and scalar document shape.
# Reader modes ignore unrelated YAML. Lock mode validates the whole document
# before publishing rows, so a bad later entry never yields a partial result.
#
# One read per process: QMAP_MODE and friends describe it, the document
# arrives on stdin, and a strict failure exits 1 with its reason on stderr.
# Several reads per process: QMAP_JOBS holds one job per line (mode, block,
# key, field and expected lock version, unit-separated) and each job names its
# document as the matching file operand, so a command that needs the manifest,
# the lock and the CLI's package descriptor parses them in a single awk start.
# Every job then prints a header, "\036<status> <line count>", followed by that
# many lines, each behind a ">" so none is empty: its rows, or its error. Empty
# documents cannot be job operands (they yield no first line to start the job);
# the caller reads those alone.
BEGIN {
    sep = sprintf("%c", 31)
    single_quote = sprintf("%c", 39)
    multi = (ENVIRON["QMAP_JOBS"] != "")
    if (multi) job_count = split(ENVIRON["QMAP_JOBS"], job_spec, "\n")
    else configure(ENVIRON["QMAP_MODE"], ENVIRON["QMAP_BLOCK"], ENVIRON["QMAP_KEY"], ENVIRON["QMAP_FIELD"], ENVIRON["QMAP_EXPECTED_VERSION"], ENVIRON["QMAP_FILE"])
}

function configure(m, b, k, f, v, file) {
    mode = m
    block = b
    wanted_key = k
    wanted_field = f
    expected_version = v
    source_file = file
    strict = (mode == "lock" || mode == "validate")
    problem = ""; problem_line = 0
    in_block = 0; package = ""
    row_count = 0; found = 0; result = ""; block_seen = 0
    split("", row_name); split("", row_line)
    split("", package_seen); split("", field_seen); split("", field_value)
    split("", top_seen); split("", top_value)
    out_count = 0; failed = 0
}

# emit/fail keep the single-document output stream and exit status unchanged;
# a job buffers both so its header can state them first.
function emit(line) {
    if (multi) out[++out_count] = line
    else print line
}

function fail(message) {
    if (multi) {
        failed = 1
        out_count = 0
        out[++out_count] = message
        return
    }
    print message > "/dev/stderr"
    exit 1
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

# A job starts at its document's first line and ends where the next begins.
multi && FNR == 1 {
    if (job) finish()
    job++
    split(job_spec[job], spec, sep)
    configure(spec[1], spec[2], spec[3], spec[4], spec[5], FILENAME)
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
            error_at(context "malformed lock structure or unsupported scalar", FNR)
        }
        if ($0 ~ /^[^ #\t]/) { in_block = 0; package = "" }
        next
    }
    if (kind == "top") {
        in_block = (key == block && empty)
        package = ""
        if (strict && top_seen[key]++) error_at("duplicate top-level field " key, FNR)
        if (!(key in top_value)) top_value[key] = value
        if (mode == "top" && key == wanted_key && !found) { result = value; found = 1 }
        if (strict) {
            if (key == block) {
                block_seen = 1
                if (!empty) error_at(block " must be a block map", FNR)
            } else if (empty) error_at("expected scalar for " key, FNR)
        }
        next
    }
    if (kind == "package" && in_block) {
        package = key
        row_count++
        row_name[row_count] = key
        row_line[row_count] = FNR
        if (strict) {
            if (key == "") error_at("empty package key", FNR)
            if (package_seen[key]++) error_at("duplicate package " key, FNR)
            if (!empty) error_at("expected field map for " key, FNR)
        }
        if (mode == "value" && key == wanted_key && !found) { result = value; found = 1 }
        next
    }
    if (kind == "field" && in_block && package != "") {
        identity = package SUBSEP key
        if (strict && field_seen[identity]++) error_at("duplicate field " package "." key, FNR)
        if (!(identity in field_value)) field_value[identity] = value
        if (strict && empty) error_at("expected scalar for " package "." key, FNR)
        if (mode == "field" && package == wanted_key && key == wanted_field && !found) {
            result = value
            found = 1
        }
        next
    }
    if (strict) error_at("malformed lock structure: expected top-level scalar or quoted package field", FNR)
}

# The end of one document: its rows or its error, through emit/fail.
function finish(    i) {
    finish_rows()
    if (multi) {
        printf "%c%d %d\n", 30, failed, out_count
        for (i = 1; i <= out_count; i++) print ">" out[i]
    }
}

function finish_rows(    version, count, fields, tops, i, f, name, row) {
    # Read the format header before interpreting a future body's shape. Errors
    # were retained during the single pass so header placement does not matter.
    if (mode == "lock" && top_value["lockfile_version"] != expected_version) {
        version = top_value["lockfile_version"]
        fail(source_file " has unsupported or missing lockfile_version '" (version == "" ? "<missing>" : version) "' — expected " expected_version)
        return
    }
    if (strict && problem != "") {
        fail(source_file ":" problem_line ": " problem)
        return
    }
    if (strict && !block_seen) {
        fail(source_file ": missing " block " block")
        return
    }
    if (mode == "lock") emit("V" sep top_value["lockfile_version"] sep top_value["engine_version"])
    if (mode == "fieldrows") {
        # One row per package key, as `keys` lists them: the name, then each
        # field QMAP_FIELD names (space separated), as qmap_field decodes it.
        count = split(wanted_field, fields, " ")
        for (i = 1; i <= row_count; i++) {
            name = row_name[i]
            row = name
            for (f = 1; f <= count; f++) row = row sep field_value[name SUBSEP fields[f]]
            emit(row)
        }
    } else if (mode == "rows" || mode == "lock" || mode == "keys") {
        for (i = 1; i <= row_count; i++) {
            name = row_name[i]
            if (mode == "keys") emit(name)
            else {
                row = name sep field_value[name SUBSEP "requested"] sep field_value[name SUBSEP "url"] sep field_value[name SUBSEP "path"] sep field_value[name SUBSEP "resolved"] sep field_value[name SUBSEP "sha"]
                if (mode == "lock") emit("R" sep row sep row_line[i])
                else emit(row)
            }
        }
    } else if (mode == "tops") {
        # Several top-level scalars in one pass: QMAP_KEY lists them, space
        # separated; each present one prints as key<US>value.
        count = split(wanted_key, tops, " ")
        for (i = 1; i <= count; i++) if (tops[i] in top_value) emit(tops[i] sep top_value[tops[i]])
    } else if (found) emit(result)
}

END {
    if (multi) {
        if (job) finish()
    } else finish()
}
