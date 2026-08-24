#!/bin/bash
# Assemble the publishable npm package into npm/dist.
#
# The repo is the single source: cli/ and registry/ ship as-is, the engine is
# a verbatim copy of intelligence/sync/, and the version is injected into
# package.json (engine VERSION by default; release-npm passes an explicit one
# for prereleases — engine VERSION itself never carries a prerelease suffix).
#
# Usage: bash npm/build.sh [version]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(tr -d ' \t\r\n' < "$ROOT/intelligence/sync/scripts/VERSION")}"
DIST="$ROOT/npm/dist"

rm -rf "$DIST"
mkdir -p "$DIST/bin"
cp "$ROOT/npm/bin/intelligence.js" "$DIST/bin/intelligence.js"
cp -R "$ROOT/cli" "$DIST/cli"
rm -rf "$DIST/cli/tests"
cp -R "$ROOT/intelligence/sync" "$DIST/engine"
cp -R "$ROOT/registry" "$DIST/registry"
cp "$ROOT/npm/README.md" "$DIST/README.md"
cp "$ROOT/LICENSE" "$DIST/LICENSE"
awk -v ver="$VERSION" '{
    sub(/"version": "0\.0\.0-dev"/, "\"version\": \"" ver "\"")
    print
}' "$ROOT/npm/package.json" > "$DIST/package.json"

echo "built: npm/dist (@ainova-systems/intelligence@$VERSION)"
