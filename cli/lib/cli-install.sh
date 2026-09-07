#!/bin/bash
# The installed CLI's own npm installation — shared by `upgrade`, which
# replaces the tree it runs from, and `update`, which plans that step.
#
# npm is never asked where its global root is: `npm root -g` answers for the
# current configuration rather than for the running tree (nvm, a custom
# prefix), and npm redacts UUID-like path segments from everything it prints.
# The tree's own location and the shim npm linked for it say where it lives.

cli_on_windows() {
    case "${OSTYPE:-}" in msys*|cygwin*) return 0 ;; esac
    return 1
}

# native_path <posix-path> — the spelling a native program (npm, node) needs:
# Windows form under Git Bash, unchanged elsewhere.
native_path() {
    if cli_on_windows; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

# quote_for_shell <string> — one shell word for a command printed to be
# copied. Windows paths carry no `$` or backtick and cmd.exe reads single
# quotes literally, so they get double quotes; elsewhere single quotes with
# an embedded quote as '\''. sed rather than ${var//…}: Bash 3.2 (macOS)
# expands a backslash-quote replacement differently.
quote_for_shell() {
    if cli_on_windows; then
        printf '"%s"' "$1"
    else
        printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
    fi
}

# cli_install_classify <pkg_dir> <pkg> <bin> — where the running tree lives.
# Sets CLI_INSTALL_KIND to npm | npx | volta | pnpm | bun | yarn | nix |
# dependency | unknown, and CLI_INSTALL_PREFIX (POSIX spelling) for npm only.
#
# npm's global layout is `<prefix>/lib/node_modules/<pkg>` on POSIX and
# `<prefix>/node_modules/<pkg>` on Windows, and a project's own node_modules
# looks exactly like the latter. The shim npm links at the prefix root is
# what proves a prefix: `<prefix>/bin/<bin>` pointing into this tree, or
# `<prefix>/<bin>.cmd` naming it. Known foreign stores are named first
# because Volta's package images are laid out like an npm prefix without
# being one.
cli_install_classify() {
    local pkg_dir="$1" pkg="$2" bin="$3" prefix="" kind="unknown" shim target pkg_bs
    CLI_INSTALL_KIND=""; CLI_INSTALL_PREFIX=""
    case "$pkg_dir" in
        */_npx/*) kind="npx" ;;
        */.volta/*|*/Volta/*) kind="volta" ;;
        */.pnpm/*) kind="pnpm" ;;
        */.bun/install/global/*) kind="bun" ;;
        */yarn/global/*|*/Yarn/Data/global/*) kind="yarn" ;;
        /nix/store/*|/gnu/store/*) kind="nix" ;;
        *)
            if cli_on_windows; then
                case "$pkg_dir" in
                    */node_modules/"$pkg")
                        prefix="${pkg_dir%/node_modules/"$pkg"}"
                        prefix="${prefix:-/}"
                        shim="$prefix/$bin.cmd"
                        # The cmd shim spells its target with backslashes.
                        pkg_bs="$(printf '%s' "$pkg" | tr '/' '\\')"
                        if [ ! -f "$shim" ] || ! grep -Fq "node_modules\\$pkg_bs\\bin\\" "$shim"; then
                            prefix=""
                        fi
                        ;;
                esac
            else
                case "$pkg_dir" in
                    */lib/node_modules/"$pkg")
                        prefix="${pkg_dir%/lib/node_modules/"$pkg"}"
                        prefix="${prefix:-/}"
                        shim="$prefix/bin/$bin"
                        target=""
                        if [ -L "$shim" ]; then
                            target="$(readlink "$shim")"
                            case "$target" in /*) ;; *) target="$prefix/bin/$target" ;; esac
                            target="$(cd "$(dirname "$target")" 2>/dev/null && pwd -P || true)"
                        fi
                        [ "$target" = "$pkg_dir/bin" ] || prefix=""
                        ;;
                esac
            fi
            if [ -n "$prefix" ]; then
                kind="npm"
            else
                case "$pkg_dir" in */node_modules/"$pkg") kind="dependency" ;; esac
            fi
            ;;
    esac
    # Read by upgrade and update after the call — per-file shellcheck cannot see that.
    # shellcheck disable=SC2034
    CLI_INSTALL_KIND="$kind"
    # shellcheck disable=SC2034
    CLI_INSTALL_PREFIX="$prefix"
}

# cli_install_hint <kind> <pkg> <version-or-channel> — the command that
# upgrades a tree npm did not make, for the refusal message.
cli_install_hint() {
    local kind="$1" spec="$2@$3"
    case "$kind" in
        npx) printf 'nothing is installed globally (this run came through npx) — install it: npm install -g %s' "$spec" ;;
        volta) printf 'volta install %s' "$spec" ;;
        pnpm) printf 'pnpm add -g %s' "$spec" ;;
        bun) printf 'bun add -g %s' "$spec" ;;
        yarn) printf 'yarn global add %s' "$spec" ;;
        nix) printf 'this tree is a Nix/Guix store path — upgrade it with that package manager (%s)' "$spec" ;;
        dependency) printf 'this is a project dependency — move it in package.json: npm install -D %s' "$spec" ;;
        *) printf 'upgrade it with the tool that installed it (ask for %s), or pull it if it is a checkout' "$spec" ;;
    esac
}

# cli_registry_version <pkg> <channel> [native-prefix] — the version the
# registry serves on that dist-tag, validated; prints nothing and fails when
# npm does not answer with one. With a prefix the lookup runs in global mode
# at that prefix — the configuration `npm install -g --prefix` will use, so
# the plan and the install cannot read different registries. `--no-json`
# overrides a `json=true` in any npmrc, which would quote the answer.
cli_registry_version() {
    local pkg="$1" channel="$2" prefix="${3:-}" out
    if [ -n "$prefix" ]; then
        out="$(npm view --global --prefix "$prefix" --no-json "$pkg" "dist-tags.$channel" 2>/dev/null || true)"
    else
        out="$(npm view --no-json "$pkg" "dist-tags.$channel" 2>/dev/null || true)"
    fi
    out="${out//[$' \t\r\n']/}"
    is_npm_version "$out" || return 1
    printf '%s' "$out"
}
