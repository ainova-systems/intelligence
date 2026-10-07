#!/bin/bash
# Internal package alias operation: set, replace or remove the alias a package
# declares in `packages:`. `sources:` spells that package's directories as
# <alias>:<dir> (decision 0019); the alias is the CLI's to write, like the rest
# of the block, and one alias names exactly one package.
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

USAGE="usage: intelligence package alias <@scope/name> <alias>
       intelligence package alias <@scope/name> --remove"

[ $# -eq 2 ] || die "$USAGE"
name="$1"
want="$2"

require_cli_project
project_lock_hold "$IP_ROOT"
manifest="$IP_ROOT/intelligence.yaml"
assert_valid_pkg_name "$name"

known=0
while IFS= read -r k; do
    [ "$k" = "$name" ] && known=1
done < <(qmap_keys "$manifest" "packages")
[ "$known" -eq 1 ] || die "package '$name' is not in the manifest — 'intelligence package list' shows the declared ones"

current="$(package_alias_of "$manifest" "$name")"

if [ "$want" = "--remove" ]; then
    # An entry can only spell a well-formed alias, so only a well-formed one can
    # still be in use; a malformed one is dropped like any other.
    [ -z "$current" ] || assert_alias_unused "$manifest" "$name" "$current" remove
    if [ -z "$(qmap_field "$manifest" "packages" "$name" "alias")" ]; then
        echo "$name declares no alias"
        exit 0
    fi
    qmap_delete_field "$manifest" "packages" "$name" "alias"
    echo "$name: alias removed"
    exit 0
fi

case "$want" in -*) die "$USAGE" ;; esac
assert_valid_alias "$want"
if [ "$current" = "$want" ]; then
    echo "$name: alias $want (unchanged)"
    exit 0
fi
assert_alias_free "$manifest" "$name" "$want"
[ -z "$current" ] || assert_alias_unused "$manifest" "$name" "$current" replace
qmap_set "$manifest" "packages" "$name" "alias" "$want"
echo "$name: alias $want — sources: may name its directories $want:<dir>"
