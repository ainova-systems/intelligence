---
paths:
  - "cli/**"
  - "engine/**"
  - "npm/**"
description: "Shell conventions for the CLI, the engine and the distribution build"
---

# Shell conventions

Bash with `set -euo pipefail`, LF endings — `.gitattributes` normalizes the whole
tree because the engine parses its inputs on Windows, macOS and Linux alike.

Engine and CLI code may rely on Bash, awk and ordinary POSIX utilities. jq, Python
and GNU-only awk extensions are not guaranteed in a consuming project, so they are
not available here either.

The floor is Bash 3.2: macOS ships it as `/bin/bash` and CI runs the suites there,
so a construct that works on Bash 5 is not evidence. Pattern substitution is the
sharp edge — 3.2 keeps the backslash of an escaped separator in the REPLACEMENT
(`${p//\/.\//\/}` yields `a\/b`) — so build such a string by iterating over its
parts instead. That host also brings BSD userland, where `sed -i` takes a suffix
argument and GNU's `1i <text>` is a syntax error: edit through a temp file and
`mv` instead of in place. A local run on Git Bash cannot see either class of bug.

A reader that rewrites a file it does not own must round-trip the bytes it keeps.
awk on Windows reads in text mode, so passing a CRLF file through it silently
rewrites the whole file as LF — for a `.gitignore`, where a `\r` is part of the
pattern Git matches, that is a content change. Read and write such a file with
`read`/`printf`.

Strip `\r` in awk readers: manifests, rules and frontmatter reach the engine from
CRLF checkouts.

Validate every manifest, registry, package-name, URL and ref value before it reaches
a Git argument or a filesystem operation. These are untrusted inputs that end up in
`rm -rf` targets and in `git` option positions.

Reuse the parsers and helpers in `engine/lib/common.sh` and `cli/lib/`. A second YAML
or frontmatter parser inside a command or an adapter is a drift source, not a
convenience.

Stage a filesystem change and verify it, then replace project state. A migration that
fails halfway must leave the project untouched.

Comments explain a constraint or the intent behind it — not syntax the reader can
already see.
