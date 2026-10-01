#!/bin/bash
# One sync per project at a time. The engine clears and rewrites every adapter's
# output and the store restore replaces package directories, so two overlapping
# runs interleave their writes and both report success over a corrupted tree.
#
# `mkdir` is the lock: it creates or fails atomically on every filesystem the
# CLI supports. The owner file names the holder, so a refusal says who it is and
# a holder that died can be told from one still working. Takeover of a dead
# holder's lock happens under a second lock, so two runs that both judged the
# same lock stale cannot both take it.

# A lock or takeover folder with no owner file is a run that died between
# creating it and writing its owner; past this age it is taken over.
SYNC_LOCK_ORPHAN_MINUTES=1
SYNC_LOCK_HELD=""

sync_lock_now() {
    if [ -n "${EPOCHSECONDS:-}" ]; then
        IS_NOW="$EPOCHSECONDS"
    else
        IS_NOW="$(date +%s)"
    fi
}

sync_lock_write_owner() {
    sync_lock_now
    printf '%s %s %s\n' "$$" "${HOSTNAME:-unknown}" "$IS_NOW" > "$1/owner"
}

# sync_lock_read_owner <lock> — set IS_LOCK_PID / IS_LOCK_HOST / IS_LOCK_SINCE;
# returns 1 when the folder has no readable owner yet.
sync_lock_read_owner() {
    IS_LOCK_PID="" IS_LOCK_HOST="" IS_LOCK_SINCE=""
    [ -f "$1/owner" ] || return 1
    read -r IS_LOCK_PID IS_LOCK_HOST IS_LOCK_SINCE < "$1/owner" || [ -n "$IS_LOCK_PID" ] || return 1
    case "$IS_LOCK_PID" in ''|*[!0-9]*) return 1 ;; esac
}

# sync_lock_is_orphan <folder> — a folder without an owner, older than the
# grace period. The age check spawns find, but only on this rare path.
sync_lock_is_orphan() {
    [ -d "$1" ] || return 1
    sync_lock_read_owner "$1" && return 1
    [ -n "$(find "$1" -maxdepth 0 -mmin "+$SYNC_LOCK_ORPHAN_MINUTES" 2>/dev/null)" ]
}

# sync_lock_is_stale <lock> — its holder can no longer be running: a process on
# this machine that no longer exists, or an orphaned folder. A holder on another
# machine (a shared filesystem) is never judged from here.
sync_lock_is_stale() {
    if sync_lock_read_owner "$1"; then
        [ "$IS_LOCK_HOST" = "${HOSTNAME:-unknown}" ] || return 1
        kill -0 "$IS_LOCK_PID" 2>/dev/null && return 1
        return 0
    fi
    sync_lock_is_orphan "$1"
}

# sync_lock_acquire <root> — take <root>/.intelligence/sync.lock or refuse.
sync_lock_acquire() {
    local root="$1" lock="$1/.intelligence/sync.lock" took=0 age=""
    mkdir -p "$root/.intelligence" || die "cannot create $root/.intelligence"
    if mkdir "$lock" 2>/dev/null; then
        took=1
    else
        sync_lock_is_orphan "$lock.takeover" && rm -rf "$lock.takeover"
        if mkdir "$lock.takeover" 2>/dev/null; then
            # Judge again under the takeover lock: another run may have taken
            # it over since this one looked.
            if sync_lock_is_stale "$lock"; then
                rm -rf "$lock"
                mkdir "$lock" 2>/dev/null && took=1
            fi
            rm -rf "$lock.takeover"
        fi
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

# sync_lock_release — drop the lock this process holds, and only that one.
sync_lock_release() {
    [ -n "$SYNC_LOCK_HELD" ] || return 0
    if sync_lock_read_owner "$SYNC_LOCK_HELD" && [ "$IS_LOCK_PID" = "$$" ]; then
        rm -rf "$SYNC_LOCK_HELD"
    fi
    SYNC_LOCK_HELD=""
}
