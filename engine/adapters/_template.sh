#!/bin/bash
# intelligence-sync: Adapter template
# Scaffold this file with: intelligence adapter new <name>
#
# This file is NOT executable as-is — `<name>` placeholders below would be
# parsed by bash as input redirection (`<` operator). Replace every
# occurrence with your adapter name before sourcing.
#
# Required:
#   1. Implement sync_to_<name>() and its three content transforms
#   2. Enable it after implementation: intelligence target enable <name>
#      This adds the target to intelligence.yaml when it is absent:
#      targets:
#        <name>: { enabled: true, output: ".<name>" }
#
# The sync_to_<name>() function receives:
#   $1 = repo_root     — absolute path to the project root
#   $2 = config_file   — absolute path to intelligence.yaml
#   $3 = output_dir    — absolute path to the output directory (e.g., .myide/)
#
# Available library functions (from lib/common.sh):
#   normalize_file_to_lf(file)          — fix CRLF line endings
#   lint_frontmatter(file)              — warn about unquoted colons / leading tabs
#   get_frontmatter_value(key, file)    — extract YAML frontmatter value
#   has_frontmatter(file)               — check if file has --- header
#   has_paths(file)                     — check if file has paths: field
#   get_model(config, ide, tier)        — resolve model from config or default
#   get_model_default(ide, tier)        — hardcoded default for ide:tier
#   map_access_to_claude_tools(access)  — full->"" (no tools list; inherits all), readonly->restricted
#   map_access_to_claude_disallowed(access) — readonly->"Write, Edit", full->""
#   read_yaml_list(manifest, section)   — read a source list from intelligence.yaml
#   get_target_field(config, target, field) — read a target's config field

# Project adapters are sourced by engine/sync.sh after the shared library is
# loaded. Keep this template position-independent: after scaffolding it lives
# under the project's content directory, not beside engine/lib/.

# Sync rules for <agent-name>
# Typical transformations:
#   - Copy as-is (like Claude)
#   - Convert paths: to globs: (like Cursor)
#   - Merge into single file (like Copilot)
sync_<name>_rules() {
    local repo_root="$1"
    local config_file="$2"
    local output_dir="$3"

    # TODO: Implement rule sync logic
    echo "  rules: not implemented"
}

# Sync skills for <agent-name>
sync_<name>_skills() {
    local repo_root="$1"
    local config_file="$2"
    local output_dir="$3"

    # TODO: Implement skill sync logic
    echo "  skills: not implemented"
}

# Sync agents for <agent-name>
sync_<name>_agents() {
    local repo_root="$1"
    local config_file="$2"
    local output_dir="$3"

    # TODO: Implement agent sync logic
    echo "  agents: not implemented"
}

# Main entry point
sync_to_<name>() {
    local repo_root="$1"
    local config_file="$2"
    local output_dir="$3"

    echo "=== <Agent Name> ==="

    # Clean and create output directories
    rm -rf "$output_dir/rules" "$output_dir/agents" "$output_dir/skills"
    mkdir -p "$output_dir/rules" "$output_dir/skills" "$output_dir/agents"

    sync_<name>_rules "$repo_root" "$config_file" "$output_dir"
    sync_<name>_skills "$repo_root" "$config_file" "$output_dir"
    sync_<name>_agents "$repo_root" "$config_file" "$output_dir"
}
