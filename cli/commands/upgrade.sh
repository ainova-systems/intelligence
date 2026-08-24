#!/bin/bash
# intelligence upgrade — bring the project to this CLI's engine: restage the
# engine content, apply v2 schema migrations (none yet — the chain starts
# empty by design), restamp sync_version, sync.
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

require_v2
manifest="$IP_ROOT/intelligence.yaml"

stamp="$(read_engine_stamp "$manifest")"
eng="$(bundled_engine_version)"
if [ -n "$stamp" ] && _ver_gt "$stamp" "$eng"; then
    die "manifest schema $stamp is newer than this CLI's engine $eng — update the CLI first: npm i -g @ainova-systems/intelligence@latest"
fi

# v2 schema migrations live HERE, not in the engine's chain (that one owns
# vendored layouts). Same discipline: ascending, append-only, each migration
# self-detects and no-ops when already applied.
# V2_MIGRATIONS=( )  — first entry arrives with the first breaking v2 change.

stage_engine_content "$IP_ROOT/.intelligence/engine"
echo "  engine content restaged ($eng)"
stamp_version "$manifest" "$eng"
echo "  sync_version -> $eng"

exec bash "$CLI_DIR/commands/sync.sh"
