#!/usr/bin/env bash
#
# Restore user data from a snapshot.
#
# Lives in /usr because that is the one thing proven to survive: an
# `rm -rf /*` test destroyed /etc and /var/home but left /usr (read-only,
# image-managed) and the btrfs read-only snapshots completely intact.
#
# Deliberately does not depend on snapper's config, which lives in /etc and can
# itself be destroyed. It reads the snapshot tree directly so it still works on
# a system whose /etc is gone.
#
# Intended to run from a healthy deployment (or a rescue boot) against a damaged
# one. Restoring /var while running on top of it is possible for user data, but
# --full should be used from a rescue boot.

set -uo pipefail

SNAPSHOT_ROOT=/var/.snapshots
MODE=userdata
TARGET_SNAPSHOT=""
DRY_RUN=0
ASSUME_YES=0

usage() {
    cat <<'EOF'
Usage: kotinos-recover [options]

  --list              show available snapshots and exit
  --snapshot N        restore from snapshot N (default: newest usable)
  --full              restore all of /var, not just user data
                      (intended for a rescue boot, not the running system)
  --dry-run           show what would change, change nothing
  --yes               skip the confirmation prompt
  -h, --help          this text

Default restores /var/home and /var/roothome -- everything the user owns.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)     MODE=list ;;
        --snapshot)
            # Required, and required to be a number. This value becomes a path
            # component feeding an `rsync --delete`, so accepting anything else
            # means accepting a traversal into a directory that is about to be
            # copied over the user's home.
            [[ $# -ge 2 ]] || { echo "--snapshot needs a number" >&2; exit 2; }
            TARGET_SNAPSHOT="$2"
            [[ "${TARGET_SNAPSHOT}" =~ ^[0-9]+$ ]] || {
                echo "--snapshot must be a number, not '${TARGET_SNAPSHOT}'" >&2; exit 2; }
            shift ;;
        --full)     MODE=full ;;
        --dry-run)  DRY_RUN=1 ;;
        --yes|-y)   ASSUME_YES=1 ;;
        -h|--help)  usage; exit 0 ;;
        *)          echo "unknown option: $1" >&2; usage; exit 2 ;;
    esac
    shift
done

log() { echo "kotinos-recover: $*"; }

if [[ ! -d "${SNAPSHOT_ROOT}" ]]; then
    log "ERROR: no snapshot tree at ${SNAPSHOT_ROOT}"
    exit 1
fi

# Snapshots are numbered directories, each containing a 'snapshot' subvolume.
# Sort numerically so 10 beats 9.
mapfile -t SNAPS < <(find "${SNAPSHOT_ROOT}" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' \
                     | grep -E '^[0-9]+$' | sort -n)

if [[ ${#SNAPS[@]} -eq 0 ]]; then
    log "ERROR: no snapshots found"
    exit 1
fi

describe() {
    local n="$1" info="${SNAPSHOT_ROOT}/$1/info.xml" desc="" date=""
    if [[ -r "${info}" ]]; then
        desc="$(grep -o '<description>[^<]*' "${info}" 2>/dev/null | cut -d'>' -f2)"
        date="$(grep -o '<date>[^<]*' "${info}" 2>/dev/null | cut -d'>' -f2)"
    fi
    printf '%-5s %-20s %s\n' "${n}" "${date:-unknown}" "${desc:-(no description)}"
}

if [[ "${MODE}" == "list" ]]; then
    printf '%-5s %-20s %s\n' "ID" "DATE" "DESCRIPTION"
    for n in "${SNAPS[@]}"; do
        [[ -d "${SNAPSHOT_ROOT}/${n}/snapshot" ]] && describe "${n}"
    done
    exit 0
fi

# Pick the newest snapshot that actually has content.
if [[ -z "${TARGET_SNAPSHOT}" ]]; then
    for (( i=${#SNAPS[@]}-1; i>=0; i-- )); do
        if [[ -d "${SNAPSHOT_ROOT}/${SNAPS[$i]}/snapshot" ]]; then
            TARGET_SNAPSHOT="${SNAPS[$i]}"
            break
        fi
    done
fi

SRC="${SNAPSHOT_ROOT}/${TARGET_SNAPSHOT}/snapshot"
if [[ ! -d "${SRC}" ]]; then
    log "ERROR: snapshot ${TARGET_SNAPSHOT} not found at ${SRC}"
    exit 1
fi

log "restoring from snapshot ${TARGET_SNAPSHOT}"
describe "${TARGET_SNAPSHOT}"

# Confirm before overwriting. Everything below runs `rsync --delete` over live
# directories, so a mistyped snapshot number or an absent-minded re-run is
# destructive with no undo of its own -- kotinos-go-back takes a safety snapshot
# first, but this script can be, and in a rescue boot will be, called directly.
#
# --dry-run is exempt because it changes nothing, and a non-interactive caller
# must pass --yes rather than have consent assumed for it.
if (( DRY_RUN == 0 && ASSUME_YES == 0 )); then
    if [[ "${MODE}" == "full" ]]; then
        log "this will replace ALL of /var from snapshot ${TARGET_SNAPSHOT}"
    else
        log "this will replace /var/home and /var/roothome from snapshot ${TARGET_SNAPSHOT}"
    fi
    log "anything changed since then is removed; there is no undo from here"
    if [[ ! -t 0 ]]; then
        log "ERROR: not interactive and --yes was not given; refusing"
        exit 1
    fi
    read -r -p "Type 'restore' to go ahead, anything else to stop: " answer
    [[ "${answer}" == "restore" ]] || { log "stopped; nothing was changed"; exit 0; }
fi

RSYNC_OPTS=(-aAXH --delete --info=stats1)
[[ ${DRY_RUN} -eq 1 ]] && RSYNC_OPTS+=(--dry-run) && log "DRY RUN -- nothing will change"

restore_path() {
    local rel="$1"
    if [[ ! -d "${SRC}/${rel}" ]]; then
        log "skipping ${rel} (not in snapshot)"
        return 0
    fi
    log "restoring /var/${rel}"
    # Created restrictively and only when missing. `install -d` without -m
    # RESETS an existing directory to 0755, which for /var/roothome means root's
    # home briefly world-readable -- and permanently so if the rsync below then
    # fails. rsync -a sets the real mode from the snapshot a moment later, so
    # starting closed and letting it widen is the safe direction to be wrong in.
    [[ -d "/var/${rel}" ]] || install -d -m 0700 "/var/${rel}"
    rsync "${RSYNC_OPTS[@]}" "${SRC}/${rel}/" "/var/${rel}/"
}

if [[ "${MODE}" == "full" ]]; then
    # .snapshots must be excluded or the restore would try to recurse into the
    # snapshot tree it is reading from.
    log "restoring all of /var (excluding .snapshots)"
    rsync "${RSYNC_OPTS[@]}" --exclude '/.snapshots' "${SRC}/" /var/
else
    restore_path home
    restore_path roothome
fi

if command -v restorecon >/dev/null 2>&1 && [[ ${DRY_RUN} -eq 0 ]]; then
    log "restoring SELinux contexts"
    restorecon -RF /var/home /var/roothome 2>/dev/null || log "WARNING: restorecon incomplete"
fi

log "done"
