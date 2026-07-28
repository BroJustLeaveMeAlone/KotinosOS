#!/usr/bin/env bash
#
# Explain where the disk space went.
#
# Exists because of one specific confusion that copy-on-write snapshots create
# and never explain: you delete a 40 GB folder, and the free space does not
# move. Every instinct says something is broken. What is actually happening is
# that restore points from before the deletion still reference those blocks, so
# the space comes back when those age out -- correct behaviour, invisible cause.
#
# A safety net that looks like a bug is one people switch off. So this answers
# the question directly, in the terms the user asked it.

set -uo pipefail

SNAPSHOT_ROOT=/var/.snapshots
CLEANUP_LOG=/var/lib/kotinos/cleanup.log

human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1}B"; }

echo "Disk space"
echo

# --- the headline numbers ---------------------------------------------------
read -r total used avail pcent <<< "$(df --output=size,used,avail,pcent -B1 /var 2>/dev/null | tail -1 | tr -d '%')"
echo "  Total       $(human "${total}")"
echo "  In use      $(human "${used}")  (${pcent}%)"
echo "  Free        $(human "${avail}")"
echo

# --- what restore points are holding ----------------------------------------
# btrfs reports exclusive data per subvolume: blocks referenced ONLY by that
# snapshot. That is precisely the space that would come back if it were deleted,
# which is the number the user actually wants -- not the snapshot's apparent
# size, which counts blocks shared with the live filesystem and would free
# nothing.
if command -v btrfs >/dev/null 2>&1; then
    held=0
    count=0
    # `btrfs qgroup show --raw` prints four columns:
    #
    #   Qgroupid    Referenced    Exclusive   Path
    #   0/257       2130444288       5079040   @var
    #   0/262       2122608640      11608064   @var/.snapshots/2/snapshot
    #
    # This used to read six fields and take the fifth as Exclusive, so the value
    # was always empty, every row failed the numeric test, and the whole section
    # below silently never printed -- the one explanation this script exists to
    # give. It is only three lines from the top of the file that says so.
    #
    # Only snapshot subvolumes are counted. Summing every qgroup would add @ and
    # @var, which are the live filesystem rather than anything a restore point is
    # holding, and would have reported nearly the entire disk as held by
    # snapshots. That would have been a worse bug than printing nothing, so the
    # field-count fix alone was not enough.
    while read -r _ _ excl path; do
        [[ "${excl}" =~ ^[0-9]+$ ]] || continue
        [[ "${path}" == *"/.snapshots/"*"/snapshot" ]] || continue
        held=$(( held + excl ))
        count=$(( count + 1 ))
    done < <(btrfs qgroup show --raw /var 2>/dev/null | tail -n +3)

    if (( count > 0 && held > 0 )); then
        echo "  Held by restore points   $(human "${held}")"
        echo
        echo "  This is space that older versions of your files are still using."
        echo "  If you have deleted something large recently and the free space"
        echo "  did not change, this is why: the machine is still holding a copy"
        echo "  so you can get it back. It is released automatically as those"
        echo "  restore points age out."
        echo
    fi
fi

# --- restore points ---------------------------------------------------------
if [[ -d "${SNAPSHOT_ROOT}" ]]; then
    n="$(find "${SNAPSHOT_ROOT}" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | grep -cE '[0-9]+$')"
    oldest_dir="$(find "${SNAPSHOT_ROOT}" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null \
                  | grep -E '^[0-9]+$' | sort -n | head -1)"
    oldest_when=""
    if [[ -n "${oldest_dir}" && -r "${SNAPSHOT_ROOT}/${oldest_dir}/info.xml" ]]; then
        oldest_when="$(grep -o '<date>[^<]*' "${SNAPSHOT_ROOT}/${oldest_dir}/info.xml" | cut -d'>' -f2)"
    fi
    echo "  Restore points           ${n}"
    [[ -n "${oldest_when}" ]] && echo "  Oldest goes back to      ${oldest_when}"
    echo
fi

# --- the biggest things in the user's data ----------------------------------
echo "  Largest folders in your files:"
for home in /var/home/*; do
    [[ -d "${home}" ]] || continue
    du -h --max-depth=1 "${home}" 2>/dev/null | sort -rh | sed -n '2,6p' | sed 's/^/    /'
done
echo

# --- what housekeeping has been doing ---------------------------------------
if [[ -s "${CLEANUP_LOG}" ]]; then
    echo "  Recent housekeeping:"
    tail -3 "${CLEANUP_LOG}" | sed 's/^/    /'
    echo
fi

echo "  To free space now:  kotinos-cleanup"
echo "  To see restore points:  kotinos-go-back"
