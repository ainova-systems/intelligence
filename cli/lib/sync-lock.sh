#!/bin/bash
# One writer per project at a time. The engine clears and rewrites every
# adapter's output, the store restore and package operations replace package
# directories, and target and alignment edits rewrite the manifest. Two of these
# overlapping interleave their writes and both report success over a corrupted
# tree, so every script that writes shared project state holds this lock while it
# does: `project_lock_hold` at its start.
#
# `mkdir` is the lock: it creates or fails atomically on every filesystem the
# CLI supports. The owner file names the holder — pid, host, start time, process
# group and a token — so a refusal says who it is, a child of the holder can
# join instead of refusing, and a holder that died can be told from one whose
# writers still run. Taking over a dead holder's lock happens under a second
# lock, so two runs that judged the same lock stale cannot both take it.
#
# `sync --check` holds the lock too, because it may restore the package store
# and compares a copy of the live outputs. It writes nothing a person keeps, so
# a holder that is a check marks its lock with a `kind` file, and a writing
# command that finds such a holder waits for it instead of refusing (decision
# 0022): a status check that runs every few minutes must never make the
# person's own sync fail. A check never waits in line — it refuses any holder
# at once — so it is never queued behind a writer; one that arrives as a lock is
# released can still take it first, and the waiting writer's bound then starts
# again for that check. A writing holder is refused at once, as before.

SYNC_LOCK_HELD=""
SYNC_LOCK_TOKEN=""
# What this process takes the lock for: "check" for `sync --check`, empty for
# every writer. Set before the lock is taken.
SYNC_LOCK_KIND=""
# How long a writer waits for each check that holds the lock, in seconds. Kept
# in the environment only so the lock suite can exercise the bound quickly.
SYNC_LOCK_CHECK_WAIT="${INTELLIGENCE_SYNC_LOCK_CHECK_WAIT:-300}"

sync_lock_now() {
    if [ -n "${EPOCHSECONDS:-}" ]; then
        IS_NOW="$EPOCHSECONDS"
    else
        IS_NOW="$(date +%s)"
    fi
}

# sync_lock_pgid — set IS_PGID to this process's group, "" when unknown. The
# engine and its jobs inherit the group, so it outlives a killed wrapper for as
# long as any writer it started still runs.
sync_lock_pgid() {
    local stat
    local -a fields
    IS_PGID=""
    # Cygwin and MSYS publish the group on its own; composing their stat file
    # takes tens of milliseconds.
    if [ -r "/proc/$$/pgid" ] && IFS= read -r IS_PGID < "/proc/$$/pgid"; then
        :
    elif [ -r "/proc/$$/stat" ] && IFS= read -r stat < "/proc/$$/stat"; then
        # pid (comm) state ppid pgrp …: comm may hold spaces, so cut after it.
        read -r -a fields <<< "${stat##*) }"
        IS_PGID="${fields[2]:-}"
    else
        IS_PGID="$(ps -o pgid= -p "$$" 2>/dev/null || true)"
        IS_PGID="${IS_PGID//[[:space:]]/}"
    fi
    case "$IS_PGID" in ''|*[!0-9]*|0|1) IS_PGID="" ;; esac
}

sync_lock_write_owner() {
    # The kind goes first, before anything that costs time: whoever can read
    # the owner can read the kind too.
    [ -z "$SYNC_LOCK_KIND" ] || printf '%s\n' "$SYNC_LOCK_KIND" > "$1/kind"
    sync_lock_now
    sync_lock_pgid
    SYNC_LOCK_TOKEN="$$.$IS_NOW.$RANDOM$RANDOM"
    printf '%s %s %s %s %s\n' "$$" "${HOSTNAME:-unknown}" "$IS_NOW" "${IS_PGID:--}" "$SYNC_LOCK_TOKEN" > "$1/owner"
}

# sync_lock_read_owner <lock> — set IS_LOCK_PID / _HOST / _SINCE / _PGID /
# _TOKEN; returns 1 when the folder has no readable owner yet.
sync_lock_read_owner() {
    IS_LOCK_PID="" IS_LOCK_HOST="" IS_LOCK_SINCE="" IS_LOCK_PGID="" IS_LOCK_TOKEN=""
    [ -f "$1/owner" ] || return 1
    read -r IS_LOCK_PID IS_LOCK_HOST IS_LOCK_SINCE IS_LOCK_PGID IS_LOCK_TOKEN < "$1/owner" \
        || [ -n "$IS_LOCK_PID" ] || return 1
    case "$IS_LOCK_PID" in ''|*[!0-9]*) return 1 ;; esac
    case "$IS_LOCK_PGID" in ''|*[!0-9]*|0|1) IS_LOCK_PGID="" ;; esac
}

# sync_lock_holder_gone — true only when no process of the holder remains: its
# whole process group when the owner recorded one, else its pid. Only "No such
# process" proves that; a permission refusal is another user's live process,
# and any other answer keeps the lock.
sync_lock_holder_gone() {
    local target="$IS_LOCK_PID" answer
    [ -z "$IS_LOCK_PGID" ] || target="-$IS_LOCK_PGID"
    answer="$(LC_ALL=C kill -0 -- "$target" 2>&1)" && return 1
    case "$answer" in *"No such process"*) return 0 ;; esac
    return 1
}

# sync_lock_is_stale <lock> — its holder can no longer write: gone from this
# machine, or a folder that never got an owner and is past a minute old. A
# holder on another machine (a shared filesystem) is never judged from here.
sync_lock_is_stale() {
    if sync_lock_read_owner "$1"; then
        [ "$IS_LOCK_HOST" = "${HOSTNAME:-unknown}" ] || return 1
        sync_lock_holder_gone
        return
    fi
    [ -d "$1" ] && [ -n "$(find "$1" -maxdepth 0 -mmin +1 2>/dev/null)" ]
}

# sync_lock_held_by_check <lock> — true when the holder marked its lock as a
# `sync --check`. A lock without the mark is a writer's, or an older CLI's.
sync_lock_held_by_check() {
    local kind=""
    # The group silences the redirection too: a kind released between the
    # test and the read must not print a stray error a caller would show.
    [ -f "$1/kind" ] && { IFS= read -r kind < "$1/kind"; } 2>/dev/null
    [ "$kind" = check ]
}

# sync_lock_tmpdirs <lock> — SYNC_LOCK_TMPDIRS, the temporary directories
# outside the lock that its holder's runs named in `scratch.<pid>.tmpdir`
# files. A run killed outright never reaches the trap that removes its own, so
# whoever releases or takes over the lock removes them. A record is only a
# file in the project, so it names nothing to remove unless the directory is
# one the CLI made: an absolute, real `intelligence-check-*` directory holding
# the marker `.intelligence-check` that the check writes first.
sync_lock_tmpdirs() {
    local record dir
    SYNC_LOCK_TMPDIRS=()
    for record in "$1"/scratch.*.tmpdir; do
        [ -f "$record" ] || continue
        dir=""
        IFS= read -r dir < "$record" || [ -n "$dir" ] || continue
        case "$dir" in /*) ;; *) continue ;; esac
        case "$dir" in *[[:cntrl:]]*|*/./*|*/../*|*/.|*/..) continue ;; esac
        case "${dir##*/}" in intelligence-check-?*) ;; *) continue ;; esac
        [ -d "$dir" ] && [ ! -L "$dir" ] && [ -f "$dir/.intelligence-check" ] || continue
        SYNC_LOCK_TMPDIRS+=("$dir")
    done
}

# Removing an abandoned copy can take long; it never keeps the lock looking
# ownerless or a takeover in progress.
sync_lock_remove_tmpdirs() {
    [ "${#SYNC_LOCK_TMPDIRS[@]}" -eq 0 ] || rm -rf "${SYNC_LOCK_TMPDIRS[@]}" 2>/dev/null || true
    SYNC_LOCK_TMPDIRS=()
}
SYNC_LOCK_TMPDIRS=()

# sync_lock_acquire <root> — take <root>/.intelligence/sync.lock, or refuse.
# A writer waits for each check that holds it for up to SYNC_LOCK_CHECK_WAIT
# seconds; a check refuses at once.
sync_lock_acquire() {
    local root="$1" lock="$1/.intelligence/sync.lock" took age="" started="$SECONDS" told=0 ownerless=""
    local holder="" seen
    # A process start costs tens of milliseconds on Git Bash: skip the usual case.
    [ -d "$root/.intelligence" ] || mkdir -p "$root/.intelligence" || die "cannot create $root/.intelligence"
    while :; do
        took=0
        SYNC_LOCK_TMPDIRS=()
        if mkdir "$lock" 2>/dev/null; then
            took=1
        elif sync_lock_is_stale "$lock" && mkdir "$lock.takeover" 2>/dev/null; then
            # The takeover lock is taken only for a lock that already looks
            # stale: a command waiting for a live check must never hold it,
            # since one interrupted mid-wait would leave it behind for good.
            # Judge again under it: another run may have taken the lock over
            # since this one looked.
            if sync_lock_is_stale "$lock"; then
                sync_lock_tmpdirs "$lock"
                rm -rf "$lock"
                mkdir "$lock" 2>/dev/null && took=1
            fi
            rmdir "$lock.takeover"
            # Their records went with the lock: remove them now even when
            # another run took it first. A lock this run took gets its owner
            # before any of that time is spent.
            [ "$took" = 1 ] || sync_lock_remove_tmpdirs
        elif [ -d "$lock.takeover" ] && [ -n "$(find "$lock.takeover" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
            # A takeover runs for milliseconds. Removing an abandoned one is itself
            # a check-then-delete race, so it is left to a person.
            die "a takeover of $lock was abandoned; if no intelligence command is running in this project, remove $lock.takeover"
        fi
        if [ "$took" = 1 ]; then
            sync_lock_write_owner "$lock" || { rm -rf "$lock"; die "cannot write $lock/owner"; }
            sync_lock_remove_tmpdirs
            SYNC_LOCK_HELD="$lock"
            return 0
        fi
        if [ "$SYNC_LOCK_KIND" != check ] && sync_lock_held_by_check "$lock"; then
            # A later ownerless moment belongs to another holder's start or
            # release, and gets its own few seconds.
            ownerless=""
            # The bound is per check: one that took the lock while this
            # command waited starts its own count.
            if sync_lock_read_owner "$lock"; then
                seen="$IS_LOCK_PID $IS_LOCK_SINCE $IS_LOCK_TOKEN"
                if [ "$seen" != "$holder" ]; then
                    holder="$seen"
                    started="$SECONDS"
                fi
            fi
            [ $((SECONDS - started)) -lt "$SYNC_LOCK_CHECK_WAIT" ] || break
            if [ "$told" = 0 ]; then
                # A caller that buffers this command's output (sync --compact)
                # names a descriptor for the terminal, so a wait of minutes
                # is never silent.
                # Not one `>&"${fd:-2}"`: the group's 2>/dev/null, which keeps
                # a closed descriptor quiet, would swallow the default too.
                if [ -n "${IS_LOCK_NOTICE_FD:-}" ]; then
                    { echo "waiting for intelligence sync --check to release $lock" >&"$IS_LOCK_NOTICE_FD"; } 2>/dev/null \
                        || echo "waiting for intelligence sync --check to release $lock" >&2
                else
                    echo "waiting for intelligence sync --check to release $lock" >&2
                fi
                told=1
            fi
        elif ! sync_lock_read_owner "$lock"; then
            # No owner: a holder between its mkdir and its owner file, or one
            # being released. Both last moments, so look again for a few
            # seconds from the first sight before calling it a run that is
            # still starting.
            [ -n "$ownerless" ] || ownerless="$SECONDS"
            [ $((SECONDS - ownerless)) -lt 3 ] || break
        else
            break
        fi
        sleep 1
    done
    if sync_lock_read_owner "$lock"; then
        sync_lock_now
        case "$IS_LOCK_SINCE" in ''|*[!0-9]*) ;; *) age=", for $((IS_NOW - IS_LOCK_SINCE))s" ;; esac
        die "another intelligence sync is running in this project (pid $IS_LOCK_PID on $IS_LOCK_HOST$age). Wait for it to finish; if no such process exists, remove $lock"
    fi
    die "another intelligence sync is starting in this project. Wait for it to finish; if none is running, remove $lock"
}

# project_lock_hold <root> — hold the project lock for the rest of this script.
# A script started by the holder joins it instead (INTELLIGENCE_SYNC_LOCK names
# the lock and its token): the holder releases it, unless `exec` made this
# process the holder, which then releases it on exit.
project_lock_hold() {
    local root="$1" lock="$1/.intelligence/sync.lock" held="${INTELLIGENCE_SYNC_LOCK:-}"
    if [ -n "$held" ] && [ "${held%%|*}" = "$lock" ] && sync_lock_read_owner "$lock" \
        && [ -n "$IS_LOCK_TOKEN" ] && [ "$IS_LOCK_TOKEN" = "${held#*|}" ]; then
        if [ "$IS_LOCK_PID" = "$$" ]; then
            SYNC_LOCK_HELD="$lock"
            SYNC_LOCK_TOKEN="$IS_LOCK_TOKEN"
            trap 'sync_lock_release' EXIT
            trap 'exit 130' INT TERM
        fi
        return 0
    fi
    sync_lock_acquire "$root"
    export INTELLIGENCE_SYNC_LOCK="$lock|$SYNC_LOCK_TOKEN"
    trap 'sync_lock_release' EXIT
    trap 'exit 130' INT TERM
}

# sync_lock_release — drop the lock this process holds, and only that one.
sync_lock_release() {
    [ -n "$SYNC_LOCK_HELD" ] || return 0
    if sync_lock_read_owner "$SYNC_LOCK_HELD" && [ "$IS_LOCK_TOKEN" = "$SYNC_LOCK_TOKEN" ]; then
        # While the owner still stands, so a waiter keeps waiting.
        sync_lock_tmpdirs "$SYNC_LOCK_HELD"
        sync_lock_remove_tmpdirs
        # A check's owner goes first: `rm -rf` alone could expose a moment with
        # the owner still there and the kind gone, and a command waiting for
        # the check would be refused in it. Without the owner, a waiter sees a
        # check or a lock still starting, and waits either way.
        [ ! -f "$SYNC_LOCK_HELD/kind" ] || rm -f "$SYNC_LOCK_HELD/owner"
        rm -rf "$SYNC_LOCK_HELD"
    fi
    SYNC_LOCK_HELD=""
}

# project_lock_scratch <root> — set IS_LOCK_SCRATCH to a path prefix inside the
# lock this process holds or joined, for files that live only as long as the
# run: releasing the lock removes them with it, so a hot path needs no process
# to create or delete a temporary directory. Names carry the pid, because a
# joined child shares the directory with its holder.
# shellcheck disable=SC2034  # IS_LOCK_SCRATCH is the return channel
project_lock_scratch() {
    local lock="$1/.intelligence/sync.lock"
    [ -d "$lock" ] && [ ! -L "$lock" ] || return 1
    IS_LOCK_SCRATCH="$lock/scratch.$$"
}
