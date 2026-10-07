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

SYNC_LOCK_HELD=""
SYNC_LOCK_TOKEN=""

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

# sync_lock_acquire <root> — take <root>/.intelligence/sync.lock or refuse.
sync_lock_acquire() {
    local root="$1" lock="$1/.intelligence/sync.lock" took=0 age=""
    # A process start costs tens of milliseconds on Git Bash: skip the usual case.
    [ -d "$root/.intelligence" ] || mkdir -p "$root/.intelligence" || die "cannot create $root/.intelligence"
    if mkdir "$lock" 2>/dev/null; then
        took=1
    elif mkdir "$lock.takeover" 2>/dev/null; then
        # Judge again under the takeover lock: another run may have taken
        # it over since this one looked.
        if sync_lock_is_stale "$lock"; then
            rm -rf "$lock"
            mkdir "$lock" 2>/dev/null && took=1
        fi
        rmdir "$lock.takeover"
    elif [ -n "$(find "$lock.takeover" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
        # A takeover runs for milliseconds. Removing an abandoned one is itself
        # a check-then-delete race, so it is left to a person.
        die "a takeover of $lock was abandoned; if no intelligence command is running in this project, remove $lock.takeover"
    fi
    if [ "$took" = 1 ]; then
        sync_lock_write_owner "$lock" || { rm -rf "$lock"; die "cannot write $lock/owner"; }
        SYNC_LOCK_HELD="$lock"
        return 0
    fi
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
