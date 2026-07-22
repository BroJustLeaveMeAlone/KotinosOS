#!/usr/bin/env bash
#
# Disk housekeeping.
#
# The user should never meet "disk full". On an appliance nobody is watching
# free space, and by the time a modern desktop starts failing because of it, the
# failures are confusing and unrelated-looking -- an app that will not save, an
# update that half-applies.
#
# Runs on a timer and only acts when space is genuinely short, so a machine with
# room is left alone entirely. Reclaims in order of least regret: caches the
# system can rebuild, then old container images, then old snapshots. User files
# are never touched.
#
# Every action is logged, because disk space silently disappearing is alarming
# and disk space silently *appearing* should be explicable.

set -uo pipefail

STATE_DIR=/var/lib/kotinos
CLEANUP_LOG="${STATE_DIR}/cleanup.log"

# Start work at 80% used; stop once back under 70%. The gap prevents the timer
# from running cleanup on every single tick when sitting near the threshold.
HIGH_WATER=80
LOW_WATER=70

log() {
    printf '%s  %s\n' "$(date -u +%FT%TZ)" "$*" >> "${CLEANUP_LOG}"
    echo "kotinos-cleanup: $*"
}

usage_percent() {
    df --output=pcent /var 2>/dev/null | tail -1 | tr -dc '0-9'
}

used="$(usage_percent)"
[[ -z "${used}" ]] && { echo "cannot read /var usage"; exit 1; }

install -d -m 0755 "${STATE_DIR}"

if (( used < HIGH_WATER )); then
    # Deliberately silent in the normal case: a log line every hour saying
    # "nothing to do" makes the interesting lines harder to find.
    exit 0
fi

log "disk at ${used}%, above ${HIGH_WATER}% -- reclaiming"

# --- 1. rebuildable caches --------------------------------------------------
# Zero risk: everything here regenerates on demand.
if command -v dnf >/dev/null 2>&1; then
    dnf clean all >/dev/null 2>&1 && log "cleared package metadata cache"
fi

if command -v journalctl >/dev/null 2>&1; then
    journalctl --vacuum-size=200M >/dev/null 2>&1 && log "trimmed journal to 200M"
fi

# Thumbnail and font caches for every user; these rebuild silently.
for home in /var/home/*; do
    [[ -d "${home}" ]] || continue
    for cache in "${home}/.cache/thumbnails" "${home}/.cache/fontconfig"; do
        [[ -d "${cache}" ]] && rm -rf "${cache:?}"/* 2>/dev/null
    done
done
log "cleared user thumbnail and font caches"

used="$(usage_percent)"
(( used < LOW_WATER )) && { log "back to ${used}%, done"; exit 0; }

# --- 2. unused container images ---------------------------------------------
# Images not backing a deployment. bootc keeps what it needs; this removes what
# nothing references.
if command -v podman >/dev/null 2>&1; then
    podman image prune -af >/dev/null 2>&1 && log "pruned unreferenced container images"
fi

used="$(usage_percent)"
(( used < LOW_WATER )) && { log "back to ${used}%, done"; exit 0; }

# --- 3. old snapshots -------------------------------------------------------
# Last, and never all of them. Snapshots are the safety net, so this trims the
# oldest routine ones while refusing to touch the pre-escalation snapshots that
# exist precisely for the worst case.
if command -v snapper >/dev/null 2>&1; then
    before="$(snapper -c var list 2>/dev/null | grep -c '^[0-9]')"
    snapper -c var cleanup number >/dev/null 2>&1
    snapper -c var cleanup timeline >/dev/null 2>&1
    after="$(snapper -c var list 2>/dev/null | grep -c '^[0-9]')"
    log "snapshot cleanup: ${before} -> ${after} restore points (escalation snapshots kept)"
fi

used="$(usage_percent)"
if (( used >= HIGH_WATER )); then
    # Worth surfacing: everything safe has been reclaimed and it was not enough,
    # which is a real problem the user has to know about rather than a routine
    # tidy-up. The settings app should show this.
    log "WARNING: still ${used}% after cleanup -- user action needed"
else
    log "finished at ${used}%"
fi
