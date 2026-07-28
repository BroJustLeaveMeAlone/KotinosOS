#!/usr/bin/env bash
#
# "Go back to yesterday" -- the human-facing front end to the M2 snapshot engine.
#
# M2 built a working restore mechanism and gave it no face. A safety net nobody
# can find is not a safety net, so this presents snapshots the way a person
# thinks about them ("yesterday afternoon", "before I unlocked admin mode")
# rather than as numbered subvolumes.
#
# Deliberately a thin wrapper over kotinos-recover rather than a reimplementation:
# there should be exactly one restore path, tested once. This adds vocabulary and
# confirmation, not logic.
#
# The graphical version belongs in the settings app; this is the mechanism it
# will call, and is usable on its own from a terminal or a rescue boot.

set -uo pipefail

SNAPSHOT_ROOT=/var/.snapshots
RECOVER=/usr/libexec/kotinos-recover

ASSUME_YES=0

usage() {
    cat <<'EOF'
Usage: kotinos-go-back [when] [--yes]

  kotinos-go-back                 show restore points, newest first
  kotinos-go-back yesterday       restore the newest point from before today
  kotinos-go-back last-safe       restore the last point taken before admin mode
  kotinos-go-back <id>            restore a specific point
  --yes                           skip the confirmation prompt

Restores your files. It does not touch the operating system -- use
`bootc rollback` for that, or let the machine do it automatically when a boot
fails its health checks.
EOF
}

# Turn a timestamp into something a person would say.
humanise() {
    local when="$1" now age_days
    [[ -z "${when}" ]] && { echo "unknown time"; return; }
    now=$(date +%s)
    local then_s
    then_s=$(date -d "${when}" +%s 2>/dev/null) || { echo "${when}"; return; }
    age_days=$(( (now - then_s) / 86400 ))

    case "${age_days}" in
        0) echo "today, $(date -d "${when}" '+%H:%M')" ;;
        1) echo "yesterday, $(date -d "${when}" '+%H:%M')" ;;
        [2-6]) echo "${age_days} days ago, $(date -d "${when}" '+%A %H:%M')" ;;
        *) echo "$(date -d "${when}" '+%-d %B, %H:%M')" ;;
    esac
}

snapshot_field() {
    local id="$1" field="$2"
    grep -o "<${field}>[^<]*" "${SNAPSHOT_ROOT}/${id}/info.xml" 2>/dev/null | cut -d'>' -f2
}

list_points() {
    printf '%-6s %-28s %s\n' "ID" "WHEN" "WHAT WAS HAPPENING"
    local ids
    mapfile -t ids < <(find "${SNAPSHOT_ROOT}" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null \
                       | grep -E '^[0-9]+$' | sort -rn)
    for id in "${ids[@]}"; do
        [[ -d "${SNAPSHOT_ROOT}/${id}/snapshot" ]] || continue
        local when desc
        when="$(snapshot_field "${id}" date)"
        desc="$(snapshot_field "${id}" description)"
        printf '%-6s %-28s %s\n' "${id}" "$(humanise "${when}")" "${desc:-routine backup}"
    done
}

# Newest snapshot taken before midnight today.
find_yesterday() {
    local cutoff ids
    cutoff=$(date -d "today 00:00" +%s)
    mapfile -t ids < <(find "${SNAPSHOT_ROOT}" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null \
                       | grep -E '^[0-9]+$' | sort -rn)
    for id in "${ids[@]}"; do
        local when then_s
        when="$(snapshot_field "${id}" date)"
        then_s=$(date -d "${when}" +%s 2>/dev/null) || continue
        if (( then_s < cutoff )); then echo "${id}"; return 0; fi
    done
    return 1
}

# Newest snapshot the escalation hook took before admin mode was granted.
find_last_safe() {
    local ids
    mapfile -t ids < <(find "${SNAPSHOT_ROOT}" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null \
                       | grep -E '^[0-9]+$' | sort -rn)
    for id in "${ids[@]}"; do
        if grep -q 'kotinos-event=escalation' "${SNAPSHOT_ROOT}/${id}/info.xml" 2>/dev/null; then
            echo "${id}"; return 0
        fi
    done
    return 1
}

# --yes may appear on either side of the when-argument, so it is pulled out
# before the case below rather than adding a branch to it.
args=()
for arg in "$@"; do
    case "${arg}" in
        --yes|-y) ASSUME_YES=1 ;;
        *)        args+=("${arg}") ;;
    esac
done
set -- "${args[@]+"${args[@]}"}"

target=""
case "${1:-}" in
    ""|list)     list_points; exit 0 ;;
    -h|--help)   usage; exit 0 ;;
    yesterday)   target="$(find_yesterday)" || { echo "No restore point from before today."; exit 1; } ;;
    last-safe)   target="$(find_last_safe)" || { echo "No pre-admin-mode restore point found."; exit 1; } ;;
    *[!0-9]*)    echo "Unrecognised: $1"; usage; exit 2 ;;
    *)           target="$1" ;;
esac

[[ -d "${SNAPSHOT_ROOT}/${target}/snapshot" ]] || { echo "No restore point ${target}."; exit 1; }

when="$(humanise "$(snapshot_field "${target}" date)")"
desc="$(snapshot_field "${target}" description)"

echo "About to restore your files to how they were ${when}."
[[ -n "${desc}" ]] && echo "  (${desc})"
echo
echo "Anything created since then will be lost. The operating system is not affected."
echo

# Actually ask. This file's header has always claimed it adds "confirmation",
# and until now it did not: it printed the warning above and went straight into
# an rsync --delete over every home directory. A warning nobody can answer is
# not a confirmation.
#
# --yes exists because the settings app and any scripted caller need a way
# through that is explicit rather than accidental. A non-interactive run with no
# --yes refuses instead of assuming consent, since the assumption that costs
# nothing when wrong is the one that does not restore.
if (( ! ASSUME_YES )); then
    if [[ ! -t 0 ]]; then
        echo "Not running interactively and --yes was not given; refusing to restore." >&2
        exit 1
    fi
    read -r -p "Type 'restore' to go ahead, anything else to stop: " answer
    if [[ "${answer}" != "restore" ]]; then
        echo "Left everything as it is."
        exit 0
    fi
    echo
fi

# Snapshot the current state first. Restoring is itself a destructive act, and
# "undo the undo" has to be possible or people will not risk using this.
#
# Failing this is fatal rather than cosmetic. It used to be best-effort: if the
# snapshot failed the restore went ahead anyway, quietly removing the only route
# back from a decision the user was told they could reverse.
if command -v snapper >/dev/null 2>&1; then
    if snapper -c var create --description "before restoring to point ${target}" \
            --cleanup-algorithm number --userdata "kotinos-event=pre-restore" >/dev/null 2>&1; then
        echo "Saved where you are now, in case you want to come back."
    else
        echo "Could not save where you are now, so this restore would be irreversible." >&2
        echo "Refusing to continue. Check 'snapper -c var list' and the disk space first." >&2
        exit 1
    fi
else
    echo "snapper is unavailable, so this restore would be irreversible." >&2
    echo "Refusing to continue." >&2
    exit 1
fi

exec "${RECOVER}" --snapshot "${target}" --yes
