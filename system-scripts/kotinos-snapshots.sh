#!/usr/bin/env bash
#
# Snapshot setup for the user-data volume.
#
# snapper's config registration creates a .snapshots subvolume inside the
# target, so it cannot happen at image build time: /var is its own btrfs
# subvolume and does not inherit the image's /var. Same reason first-boot
# provisioning exists. Runs once, gated by a stamp.
#
# The target is /var, not /home. Fedora bootc symlinks /home -> /var/home and
# /root -> /var/roothome, so /var is where every byte of user data lives.

set -euo pipefail

CONFIG_NAME="${KOTINOS_SNAPPER_CONFIG:-var}"
STAMP_DIR=/var/lib/kotinos
STAMP="${STAMP_DIR}/.snapshots-configured"

log() { echo "kotinos-snapshots: $*"; }

if ! findmnt --target /var >/dev/null 2>&1; then
    log "ERROR: /var is not mounted; refusing to configure"
    exit 1
fi

if [[ -e "${STAMP}" ]]; then
    log "already configured; nothing to do"
    exit 0
fi

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
    ALLOW_GROUPS=wheel \
    SYNC_ACL=yes

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

install -d -m 0755 "${STAMP_DIR}"
printf 'configured=%s\nconfig=%s\n' "$(date -u +%FT%TZ)" "${CONFIG_NAME}" > "${STAMP}"

log "creating baseline snapshot"
snapper --config "${CONFIG_NAME}" create \
    --description "baseline: first boot" \
    --cleanup-algorithm number \
    --userdata "kotinos-event=firstboot" || log "WARNING: baseline snapshot failed"

log "done"
