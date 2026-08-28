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
