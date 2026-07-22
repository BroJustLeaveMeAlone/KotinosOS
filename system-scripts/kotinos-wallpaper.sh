#!/usr/bin/env bash
#
# Time-of-day wallpaper.
#
# The desktop should track the day the way the light in a room does, without
# being asked to. Four images, changed on a timer.
#
# Runs as the user: the wallpaper is a per-user Plasma setting, and setting it
# as root writes files the user then cannot change.
#
# Deliberately does nothing if the user has chosen their own wallpaper. An
# appliance that quietly overwrites a personal choice every few hours is not
# being helpful, it is being broken -- so the first manual change opts out
# permanently.

set -uo pipefail

WALLPAPER_DIR=/usr/share/kotinos/wallpapers
STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/kotinos"
OPT_OUT="${STATE_DIR}/.wallpaper-manual"
LAST_SET="${STATE_DIR}/.wallpaper-last"

log() { echo "kotinos-wallpaper: $*"; }

# Which part of the day is it? Boundaries chosen so "day" covers working hours
# and the transitional images get a real slot rather than a token half hour.
hour=$(date +%-H)
if   (( hour >= 5  && hour < 9  )); then phase=dawn
elif (( hour >= 9  && hour < 17 )); then phase=day
elif (( hour >= 17 && hour < 21 )); then phase=dusk
else                                     phase=night
fi

target="${WALLPAPER_DIR}/kotinos-${phase}.png"
[[ -r "${target}" ]] || { log "no wallpaper for ${phase}"; exit 0; }

if [[ -e "${OPT_OUT}" ]]; then
    log "user has set their own wallpaper; leaving it alone"
    exit 0
fi

# Nothing to do if we already set this one.
if [[ -r "${LAST_SET}" ]] && [[ "$(cat "${LAST_SET}")" == "${phase}" ]]; then
    exit 0
fi

command -v plasma-apply-wallpaperimage >/dev/null 2>&1 || {
    log "plasma-apply-wallpaperimage unavailable; is this a Plasma session?"
    exit 0
}

if plasma-apply-wallpaperimage "${target}" >/dev/null 2>&1; then
    install -d -m 0700 "${STATE_DIR}"
    printf '%s' "${phase}" > "${LAST_SET}"
    log "set ${phase} wallpaper"
else
    log "could not apply wallpaper"
fi
