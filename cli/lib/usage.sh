#!/bin/bash
# The usage text of every public command and subcommand, sourced by the
# dispatcher to answer `--help`, `-h` and `help <command>`, and by a command
# for the usage error it prints. One text per command: help and the error read
# the same block, so they cannot disagree. A block opens with its synopsis,
# `Usage:` and any continuation lines, which ends at the first empty line.
#
# Sourcing it starts no process. `sync`, which runs on every save, still
# sources it only for its usage error.

# cli_usage_top <engine-version> - the top-level help.
cli_usage_top() {
    cat <<EOF
intelligence — build, version and distribute AI agent intelligence
(engine $1${INTELLIGENCE_NPM_VERSION:+, package $INTELLIGENCE_NPM_VERSION})

Usage: intelligence <command> [args]

  init [--preview|--apply]  Initialize, convert, restore or align this project
    --targets a,b --dir name --bare --no-sync   New-project options
    --force               Accept a dirty worktree during legacy project conversion
  sync [adapter] [--compact] [--force] [--check]  Restore locked content, then render enabled adapters
    --compact            On success show context, warnings and final status; on failure show diagnostics
    --force              Render again and refresh discovery of unconfigured source directories
    --check              Change no generated file; exit 0 when up to date, 2 when sync is needed
  update [@scope/name]    Show an update plan; ask before applying it
    --preview             Show the plan without asking or writing
    --apply               Apply the plan without asking
    --latest              Move one named package past its range to the newest version
  upgrade [--next] [--preview|--apply]  Replace the installed CLI with the newest npm version
    --next                Follow the prerelease line instead of the stable one
  package <command>       add | remove | alias | list | search
  source <command>        add | remove | list — the sources: block (own directories)
  adapter <command>       list | create | enable | disable | remove
  status [--check]        Project state; --check runs deep consistency checks
  registry <list|add|remove>  Manage the trusted registry list (add <repo-url>)
  version                 Print CLI and engine versions

Run 'intelligence <command> --help' for a command's options.
EOF
}

# cli_usage_group <command> - whether the command takes a subcommand.
cli_usage_group() {
    case "$1" in package|source|adapter|registry) return 0 ;; esac
    return 1
}

# cli_usage_var <command> [<subcommand>] - IS_CLI_USAGE, the block for that
# command; return 1 when there is no such command or subcommand.
cli_usage_var() {
    IS_CLI_USAGE=""
    case "$1/${2:-}" in
        init/)
            read -r -d '' IS_CLI_USAGE <<'EOF' || true
Usage: intelligence init [--targets a,b] [--dir name] [--bare] [--no-sync]
                         [--preview|--apply] [--force]

Set up a new project, convert a legacy Intelligence Sync project, or restore
this one: its missing package store, every enabled adapter's Git policy, then
a sync of the project as committed.

  --preview        Show what would happen and write nothing to the project
  --apply          Proceed without asking; legacy conversion asks otherwise
  --targets a,b    New project: the adapters to enable beside agents
  --dir name       New project: the content directory, intelligence by default
  --bare           New project: leave out the engine content package
  --no-sync        Stop before the sync
  --force          Legacy conversion: accept a dirty worktree
  -h, --help       Show this help
EOF
            ;;
        sync/)
            read -r -d '' IS_CLI_USAGE <<'EOF' || true
Usage: intelligence sync [adapter] [--compact] [--force] [--check]

Restore locked content, then render enabled adapters. Naming an enabled
adapter renders that one only.

  --compact        On success show context, warnings and final status; on failure show diagnostics
  --force          Render again and refresh discovery of unconfigured source directories
  --check          Change no generated file; exit 0 when up to date, 2 when sync is needed
  -h, --help       Show this help
EOF
            ;;
        update/)
            read -r -d '' IS_CLI_USAGE <<'EOF' || true
Usage: intelligence update [@scope/name] [--latest] [--preview|--apply]

Show the plan for the installed CLI, the project's versions and its packages,
then ask before applying it. Only update moves the project's versions.

  @scope/name      Plan for this package only
  --latest         Move the named package past its range to the newest version
  --preview        Show the plan without asking or writing
  --apply          Apply the plan without asking
  -h, --help       Show this help
EOF
            ;;
        upgrade/)
            read -r -d '' IS_CLI_USAGE <<'EOF' || true
Usage: intelligence upgrade [--next] [--preview|--apply]

Replace the installed CLI with the newest npm version on its channel. It
touches no project.

  --next           Follow the prerelease line instead of the stable one
  --preview        Show the upgrade without installing it
  --apply          Install without asking
  -h, --help       Show this help
EOF
            ;;
        status/)
            read -r -d '' IS_CLI_USAGE <<'EOF' || true
Usage: intelligence status [--check]

Show the project: its mode, manifest, lock, engine content and bundled engine.

  --check          Run deep consistency checks; exit 1 when one fails
  -h, --help       Show this help
EOF
            ;;
        version/)
            read -r -d '' IS_CLI_USAGE <<'EOF' || true
Usage: intelligence version

Print the CLI and engine versions. -v and --version do the same.

  -h, --help       Show this help
EOF
            ;;
        package/)
            read -r -d '' IS_CLI_USAGE <<'EOF' || true
Usage: intelligence package <add|remove|alias|list|search> [args]

Manage the packages this project installs.

  add <spec>                    Install a package and wire its sources, then sync
  remove <@scope/name>          Remove a package and its sources, then sync
  alias <@scope/name> <alias>   Set the alias sources: may name its directories by
  list                          Requested and locked state of each package
  search [term]                 What the trusted registries offer
  -h, --help                    Show this help

Run 'intelligence package <command> --help' for a command's options.
EOF
            ;;
        package/add)
            read -r -d '' IS_CLI_USAGE <<'EOF' || true
Usage: intelligence package add <spec> [--name @scope/name] [--alias <alias>] [--no-sync]

Resolve and fetch a package, wire its directories into sources:, write the
manifest and the lock, then sync.

  <spec> is one of:
    @scope/name[@range]        through the project's trusted registries only
    github:org/repo[#path]     directly from GitHub
    git+<url>[@ref][#path]     directly from any Git host

  --name @scope/name   Record the package under this name
  --alias <alias>      The alias sources: may name its directories by
  --no-sync            Stop before the sync
  -h, --help           Show this help
EOF
            ;;
        package/remove)
            read -r -d '' IS_CLI_USAGE <<'EOF' || true
Usage: intelligence package remove <@scope/name> [--force] [--no-sync]

Remove a package: its manifest entry, every sources: entry that names it, its
lock row and its store content, then sync.

  --force          Required to remove the engine content package
  --no-sync        Stop before the sync
  -h, --help       Show this help
EOF
            ;;
        package/alias)
            read -r -d '' IS_CLI_USAGE <<'EOF' || true
Usage: intelligence package alias <@scope/name> <alias>
       intelligence package alias <@scope/name> --remove

Set, replace or remove the alias sources: may name a package's directories by,
as <alias>:<dir>. It does not sync.

  --remove         Drop the alias
  -h, --help       Show this help
EOF
            ;;
        package/list)
            read -r -d '' IS_CLI_USAGE <<'EOF' || true
Usage: intelligence package list

Show each package's requested and locked version, whether its content is
installed, and its alias.

  -h, --help       Show this help
EOF
            ;;
        package/search)
            read -r -d '' IS_CLI_USAGE <<'EOF' || true
Usage: intelligence package search [term]

Show what the trusted registries offer and what this project already has. A
term keeps the packages whose name or description contains it.

  -h, --help       Show this help
EOF
            ;;
        source/)
            read -r -d '' IS_CLI_USAGE <<'EOF' || true
Usage: intelligence source <add|remove|list> [args]

Manage the project's own directories in the sources: block. Installed package
content belongs to 'intelligence package'.

  add <rules|agents|skills> <dir>      Add a directory, last in its section by default
  remove <rules|agents|skills> <dir>   Drop a directory's entry
  list                                 Every section in override order
  -h, --help                           Show this help

Run 'intelligence source <command> --help' for a command's options.
EOF
            ;;
        source/add)
            read -r -d '' IS_CLI_USAGE <<'EOF' || true
Usage: intelligence source add <rules|agents|skills> <dir> [--first|--last|--before <entry>|--after <entry>]

Add a project directory to one section of sources:. A later entry overrides an
earlier one, so where it lands decides which artifacts win. Adding an entry the
section holds changes nothing; adding it with a position moves it.

  --last             At the end of the section, after every package (default)
  --first            At the start of the section
  --before <entry>   Just before an entry the section lists
  --after <entry>    Just after an entry the section lists
  -h, --help         Show this help
EOF
            ;;
        source/remove)
            read -r -d '' IS_CLI_USAGE <<'EOF' || true
Usage: intelligence source remove <rules|agents|skills> <dir>

Drop a directory's entry from sources:. The directory is untouched; its
artifacts leave the generated output at the next sync.

  -h, --help       Show this help
EOF
            ;;
        source/list)
            read -r -d '' IS_CLI_USAGE <<'EOF' || true
Usage: intelligence source list

Show every section of sources: in override order, marking package content.

  -h, --help       Show this help
EOF
            ;;
        adapter/)
            read -r -d '' IS_CLI_USAGE <<'EOF' || true
Usage: intelligence adapter <list|create|enable|disable|remove> [name]

Manage the adapters that render this project into each tool.

  list                       Built-in and project adapters, state and output
  create <name>              Scaffold a project adapter
  enable <name>              Enable an adapter, then sync
  disable <name>             Disable an adapter and keep its output
  remove <name> [--apply]    Delete a disabled project adapter's source
  -h, --help                 Show this help

Run 'intelligence adapter <command> --help' for a command's options.
EOF
            ;;
        adapter/list)
            read -r -d '' IS_CLI_USAGE <<'EOF' || true
Usage: intelligence adapter list

Show every built-in and project adapter, its source, state and output. A
project adapter overrides a built-in of the same name.

  -h, --help       Show this help
EOF
            ;;
        adapter/create)
            read -r -d '' IS_CLI_USAGE <<'EOF' || true
Usage: intelligence adapter create <name>

Scaffold <content-dir>/adapters/<name>.sh from the bundled template. It never
overwrites an adapter. A name matches [a-z][a-z0-9_]*.

  -h, --help       Show this help
EOF
            ;;
        adapter/enable)
            read -r -d '' IS_CLI_USAGE <<'EOF' || true
Usage: intelligence adapter enable <name>

Enable an adapter in the manifest, apply its Git policy, then sync. A failed
sync restores the manifest and the ignore files.

  -h, --help       Show this help
EOF
            ;;
        adapter/disable)
            read -r -d '' IS_CLI_USAGE <<'EOF' || true
Usage: intelligence adapter disable <name>

Disable an adapter in the manifest. Its generated output stays for a cleanup
you approve.

  -h, --help       Show this help
EOF
            ;;
        adapter/remove)
            read -r -d '' IS_CLI_USAGE <<'EOF' || true
Usage: intelligence adapter remove <name> [--apply]

Delete a disabled project adapter's source. Generated output is kept.

  --apply          Delete without asking
  -h, --help       Show this help
EOF
            ;;
        registry/)
            read -r -d '' IS_CLI_USAGE <<'EOF' || true
Usage: intelligence registry <list|add|remove> [args]

Manage the project's trust list of registries, the only way a package name
resolves. Without a command, list.

  list                              Each registry in trust order
  add <repository-url> [--force]    Trust a registry that serves an index.yaml
  remove <repository-url>           Stop trusting a registry
  -h, --help                        Show this help

Run 'intelligence registry <command> --help' for a command's options.
EOF
            ;;
        registry/list)
            read -r -d '' IS_CLI_USAGE <<'EOF' || true
Usage: intelligence registry list

Show each trusted registry in trust order with the number of packages it
declares. The first registry to declare a name wins.

  -h, --help       Show this help
EOF
            ;;
        registry/add)
            read -r -d '' IS_CLI_USAGE <<'EOF' || true
Usage: intelligence registry add <repository-url> [--force]

Trust a Git repository that holds an index.yaml, after reading it. Every name
it declares then installs by name.

  --force          Record a registry that cannot be read yet
  -h, --help       Show this help
EOF
            ;;
        registry/remove)
            read -r -d '' IS_CLI_USAGE <<'EOF' || true
Usage: intelligence registry remove <repository-url>

Stop trusting a registry. Packages already installed keep their locked source.

  -h, --help       Show this help
EOF
            ;;
        *) return 1 ;;
    esac
}

# cli_help <strict> <command> [<argument>...] - print a command's usage and
# exit 0. For `--help` (strict 0) the first argument picks a subcommand when it
# names one, and the group's usage answers otherwise; `help <command>
# [<subcommand>]` (strict 1) refuses what names nothing.
cli_help() {
    local strict="$1" command="$2" sub="${3:-}"
    # `help sync --help` asks for what `help sync` prints.
    case "$sub" in -h|--help) sub="" ;; esac
    if cli_usage_group "$command" && [ -n "$sub" ] && cli_usage_var "$command" "$sub"; then
        printf '%s\n' "$IS_CLI_USAGE"
        exit 0
    fi
    if [ "$strict" = 1 ] && [ -n "$sub" ]; then
        if cli_usage_group "$command"; then
            echo "ERROR: unknown command 'intelligence $command $sub'. Run 'intelligence help $command'." >&2
        elif cli_usage_var "$command"; then
            echo "ERROR: 'intelligence $command' takes no command. Run 'intelligence help $command'." >&2
        else
            echo "ERROR: unknown command '$command'. Run 'intelligence help'." >&2
        fi
        exit 1
    fi
    if cli_usage_var "$command"; then
        printf '%s\n' "$IS_CLI_USAGE"
        exit 0
    fi
    echo "ERROR: unknown command '$command'. Run 'intelligence help'." >&2
    exit 1
}

# cli_usage_die <command> [<subcommand>] - the usage error: the block's
# synopsis on stderr, and exit 1.
cli_usage_die() {
    local nl=$'\n' synopsis
    cli_usage_var "$@" || cli_usage_var "$1" || true
    synopsis="${IS_CLI_USAGE%%"$nl$nl"*}"
    echo "ERROR: ${CLI_INPUT_CONTEXT:-}usage: ${synopsis#Usage: }" >&2
    echo "       Run 'intelligence $* --help' for the options." >&2
    exit 1
}
