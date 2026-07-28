#!/usr/bin/env bash
#
# Pre-escalation safety capture.
#
# Runs immediately before admin mode is granted, so there is always a known-good
# point to return to from whatever happens next. Two independent captures,
# because there are two independent failure modes:
#
#   1. ostree deployment pin -- protects the OS. Pinning keeps the current
#      deployment from being garbage-collected by later upgrades, so
#      `bootc rollback` still has somewhere to go days later.
#   2. snapper snapshot of /var -- protects user data, which bootc rollback
#      deliberately never touches.
#
# Called by the admin-mode gate (M5). Exits non-zero if either capture fails:
# the caller should treat that as "do not open the door", since the whole point
# is that escalation is survivable.

set -uo pipefail

CONFIG_NAME="${KOTINOS_SNAPPER_CONFIG:-var}"
REASON="${1:-admin escalation}"
STAMP_DIR=/var/lib/kotinos
LOG_TAG="kotinos-escalate"

log() { echo "${LOG_TAG}: $*"; }
fail=0

# --- 1. Pin the current OS deployment ------------------------------------
# `ostree admin pin 0` marks the booted deployment as retained. Without it a
# couple of upgrades can evict the deployment the user would want back.
if command -v ostree >/dev/null 2>&1; then
    if ostree admin pin 0 >/dev/null 2>&1; then
        log "pinned current deployment"
    else
        log "ERROR: failed to pin deployment"
        fail=1
    fi
else
    log "ERROR: ostree not available"
    fail=1
fi

# --- 2. Snapshot user data ------------------------------------------------
# Tagged 'important' so it survives ordinary cleanup longer than a routine
# timeline snapshot.
if command -v snapper >/dev/null 2>&1; then
    # --print-number makes snapper report the number it just created, on stdout.
    # This used to run a second `snapper list --columns number | tail -1` and
    # take whatever came last, which is only the new snapshot if the listing
    # happens to be sorted that way and nothing else created one in between.
    # Asking the command that did the work is both simpler and actually correct,
    # and this is the pre-escalation record -- the identifier we log here is what
    # someone reads back when they need to undo whatever admin mode did.
    if snap_id="$(snapper --config "${CONFIG_NAME}" create \
            --print-number \
            --description "pre-escalation: ${REASON}" \
            --cleanup-algorithm number \
            --userdata "kotinos-event=escalation,important=yes" 2>/dev/null)"; then
        snap_id="${snap_id//[[:space:]]/}"
        log "created /var snapshot ${snap_id:-?}"
    else
        log "ERROR: failed to snapshot /var"
        fail=1
    fi
else
    log "ERROR: snapper not available"
    fail=1
fi

if [[ ${fail} -ne 0 ]]; then
    log "capture incomplete -- caller should refuse escalation"
    exit 1
fi

install -d -m 0755 "${STAMP_DIR}"
printf 'last_escalation=%s\nreason=%s\n' "$(date -u +%FT%TZ)" "${REASON}" \
    > "${STAMP_DIR}/.last-escalation"

log "safety capture complete"
