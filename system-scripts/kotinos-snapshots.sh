#!/usr/bin/env bash
#
# Snapshot setup for the user-data volume.
#
# snapper's config registration creates a .snapshots subvolume inside the
# target, so it cannot happen at image build time: /var is its own btrfs
# subvolume and does not inherit the image's /var. Same reason first-boot
# provisioning exists.
#
# The target is /var, not /home. Fedora bootc symlinks /home -> /var/home and
# /root -> /var/roothome, so /var is where every byte of user data lives.
#
# THE STAMP GATES THE BASELINE SNAPSHOT, NOT THE WHOLE SCRIPT.
#
# It used to gate everything, and that was wrong in a way only a security fix
# revealed. The retention block below carries the permission settings that
# decide who may delete snapshots, and those were once configured to let any
# wheel user destroy the entire safety net (see TODO.md). Fixing the script did
# nothing for a machine that had already been provisioned, because the stamp
# meant the corrected settings were never applied again -- the hole would have
# survived every future update, on exactly the machines that had been running
# longest.
#
# Everything above the baseline snapshot is idempotent by construction:
# create-config is guarded by a probe, set-config writes the same values, and
# `btrfs quota enable` no-ops when already on. So the script now runs every boot
# and re-asserts them, and only snapshot creation is stamped.

set -euo pipefail

CONFIG_NAME="${KOTINOS_SNAPPER_CONFIG:-var}"
STAMP_DIR=/var/lib/kotinos
STAMP="${STAMP_DIR}/.snapshots-configured"

log() { echo "kotinos-snapshots: $*"; }

if ! findmnt --target /var >/dev/null 2>&1; then
    log "ERROR: /var is not mounted; refusing to configure"
    exit 1
fi

already_configured=no
[[ -e "${STAMP}" ]] && already_configured=yes

if snapper --config "${CONFIG_NAME}" list >/dev/null 2>&1; then
    log "snapper config '${CONFIG_NAME}' already exists"
else
    log "creating snapper config '${CONFIG_NAME}' for /var"
    snapper --config "${CONFIG_NAME}" create-config /var
fi

# Retention. The disk budget matters more than the counts: a safety net that
# fills the disk is itself a failure, and on an appliance nobody is watching
# free space. SPACE_LIMIT caps snapshots at a fraction of the filesystem and
# FREE_LIMIT keeps a reserve free, both enforced by snapper's cleanup timer.
#
# ALLOW_GROUPS AND SYNC_ACL ARE EMPTY/NO ON PURPOSE. DO NOT SET THEM TO wheel.
#
# This previously read ALLOW_GROUPS=wheel and SYNC_ACL=yes, presumably so the
# user could look at their own restore points without a password. What it
# actually granted was full control, because snapper's ALLOW_GROUPS is not a
# read-only permission -- it authorises create AND delete through snapperd's
# D-Bus interface, with no polkit prompt.
#
# The adversarial test caught it (27 Jul 2026). The primary user is in wheel so
# they can sudo, so the primary user could run `snapper -c var delete N` and
# destroy every restore point on the machine without ever being asked for a
# password. Ransomware running as that user could do the same in one line, which
# is the exact scenario the safety net exists for. The central promise of this
# project -- nothing can delete your safety net -- was false, and it was false
# because of this setting, not because of anything the kernel or btrfs did.
#
# With these empty, snapshot management requires root, so it goes through
# password sudo or admin mode (M5). That is the boundary M4 says should be
# there. The cost is that a settings UI wanting to LIST snapshots must ask root
# rather than reading .snapshots directly -- which is the correct trade, since
# every scrap of the user's data lives inside those snapshots anyway.
log "applying retention policy"
snapper --config "${CONFIG_NAME}" set-config \
    TIMELINE_CREATE=yes \
    TIMELINE_CLEANUP=yes \
    TIMELINE_MIN_AGE=1800 \
    TIMELINE_LIMIT_HOURLY=6 \
    TIMELINE_LIMIT_DAILY=7 \
    TIMELINE_LIMIT_WEEKLY=4 \
    TIMELINE_LIMIT_MONTHLY=2 \
    TIMELINE_LIMIT_YEARLY=0 \
    NUMBER_CLEANUP=yes \
    NUMBER_MIN_AGE=1800 \
    NUMBER_LIMIT=20 \
    NUMBER_LIMIT_IMPORTANT=10 \
    SPACE_LIMIT=0.3 \
    FREE_LIMIT=0.2 \
    ALLOW_GROUPS="" \
    SYNC_ACL=no

# Quota groups, so the machine can answer "how much space are restore points
# actually using?". Without qgroups btrfs can report a snapshot's apparent size
# but not its *exclusive* size -- the blocks only that snapshot references, which
# is the only number that means anything to a user asking why deleting a large
# file freed nothing. kotinos-space reads this.
if btrfs quota enable /var >/dev/null 2>&1; then
    log "enabled btrfs quota groups on /var (for space accounting)"
else
    log "WARNING: could not enable quota groups; space reporting will be partial"
fi

# Everything above re-runs on every boot and is idempotent. Only the baseline
# snapshot is once-per-machine -- creating a fresh "first boot" snapshot on
# every boot would push real history out of the retention budget.
if [[ "${already_configured}" == yes ]]; then
    log "settings re-asserted; baseline snapshot already taken"
    exit 0
fi

install -d -m 0755 "${STAMP_DIR}"
printf 'configured=%s\nconfig=%s\n' "$(date -u +%FT%TZ)" "${CONFIG_NAME}" > "${STAMP}"

log "creating baseline snapshot"
snapper --config "${CONFIG_NAME}" create \
    --description "baseline: first boot" \
    --cleanup-algorithm number \
    --userdata "kotinos-event=firstboot" || log "WARNING: baseline snapshot failed"

log "done"
