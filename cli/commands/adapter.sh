#!/bin/bash
# intelligence adapter new <name>
#
# Scaffold a project-owned adapter from the bundled engine template. This is
# deliberately only scaffolding: researching the tool and implementing its
# format are judgement work owned by the install-adapter skill.
set -euo pipefail
source "$CLI_DIR/lib/cli-common.sh"

subcommand="${1:-}"
name="${2:-}"
[ $# -le 2 ] || die "usage: intelligence adapter new <name>"
[ "$subcommand" = "new" ] && [ -n "$name" ] || die "usage: intelligence adapter new <name>"
assert_valid_target_name "$name"

require_v2
manifest="$IP_ROOT/intelligence.yaml"
content_dir="$(manifest_intelligence_dir "$manifest")"

# The destination is project-owned. Refuse path traversal and package-store
# overlap even if a hand-edited manifest supplies a hostile content dir.
case "$content_dir" in
    ""|/*|.|..|../*|*/../*|*/..|.intelligence|.intelligence/*)
        die "unsafe project.intelligence_dir '$content_dir'"
        ;;
esac

# Existing path components must resolve inside the repository. This catches a
# content-dir symlink before mkdir or the final write can escape the project.
repo_phys="$(cd "$IP_ROOT" && pwd -P)"
probe="$IP_ROOT"
old_ifs="$IFS"; IFS='/'; read -r -a parts <<< "$content_dir"; IFS="$old_ifs"
for part in "${parts[@]}"; do
    [ -n "$part" ] || continue
    probe="$probe/$part"
    if [ -e "$probe" ] || [ -L "$probe" ]; then
        probe_phys="$(cd "$probe" 2>/dev/null && pwd -P)" || die "cannot resolve project content path '$content_dir'"
        case "$probe_phys" in "$repo_phys"|"$repo_phys"/*) ;; *) die "project.intelligence_dir resolves outside the repository: '$content_dir'" ;; esac
    fi
done

template="$IS_ENGINE_DIR/adapters/_template.sh"
[ -f "$template" ] || die "corrupt CLI installation: bundled adapter template is missing"
adapter_dir="$IP_ROOT/$content_dir/adapters"
dest="$adapter_dir/$name.sh"
[ ! -e "$dest" ] || die "project adapter already exists: $content_dir/adapters/$name.sh"

mkdir -p "$adapter_dir"
adapter_phys="$(cd "$adapter_dir" && pwd -P)"
case "$adapter_phys" in
    "$repo_phys"|"$repo_phys"/*) ;;
    *) die "project adapter directory resolves outside the repository: '$content_dir/adapters'" ;;
esac
tmp="$(mktemp "$adapter_dir/.${name}.XXXXXX")"
trap '[ -z "${tmp:-}" ] || rm -f "$tmp"' EXIT
awk -v name="$name" '
    { gsub(/<agent-name>/, name); gsub(/<Agent Name>/, name); gsub(/<name>/, name); print }
' "$template" > "$tmp"
[ -s "$tmp" ] || die "adapter template produced an empty file"
mv "$tmp" "$dest"
tmp=""

echo "created: $content_dir/adapters/$name.sh"
echo "  implement sync_to_${name}(), then run: intelligence target enable $name"
