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

# Notice a wallpaper the user chose themselves, and stop.
#
# The opt-out file was only ever created by kotinos-theme, i.e. when the user
# picked a fixed look through our own tool. Someone who changed their wallpaper
# the ordinary way -- right-click the desktop, Configure, pick a picture -- got
# no opt-out at all, and this timer quietly put its own image back within the
# hour. That is precisely the "quietly overwrites a personal choice" behaviour
# the comment at the top of this file says it avoids.
#
# So compare what Plasma currently has against what we last set. If they differ,
# something other than this script changed it, and that is the user. Opting out
# is permanent and deliberate: guessing again later would reintroduce the same
# annoyance, and kotinos-theme <name> is how someone asks for the clock back.
current_wallpaper() {
    local cfg="${XDG_CONFIG_HOME:-${HOME}/.config}/plasma-org.kde.plasma.desktop-appletsrc"
    [[ -r "${cfg}" ]] || return 1
    # Last Image= wins; Plasma writes one per containment and they agree in the
    # single-screen case this is aimed at.
    grep -oP '^Image=\K.*' "${cfg}" 2>/dev/null | tail -1
}

if [[ -r "${LAST_SET}" ]]; then
    last_phase="$(cut -d' ' -f1 < "${LAST_SET}")"
    last_path="$(cut -d' ' -f2- < "${LAST_SET}")"
    now_path="$(current_wallpaper || true)"

    # Only judge when we can actually read what Plasma has; an unreadable config
    # must not be mistaken for a user choice, or the feature turns itself off on
    # a machine where nothing is wrong.
    if [[ -n "${now_path}" && -n "${last_path}" ]]; then
        # Plasma stores the path with a file:// prefix and sometimes a trailing
        # slash; compare on the basename to avoid chasing that formatting.
        if [[ "${now_path##*/}" != "${last_path##*/}" ]]; then
            install -d -m 0700 "${STATE_DIR}"
            touch "${OPT_OUT}"
            log "wallpaper was changed elsewhere; leaving it alone from now on"
            exit 0
        fi
    fi

    # Nothing to do if we already set this one.
    [[ "${last_phase}" == "${phase}" ]] && exit 0
fi

command -v plasma-apply-wallpaperimage >/dev/null 2>&1 || {
    log "plasma-apply-wallpaperimage unavailable; is this a Plasma session?"
    exit 0
}

if plasma-apply-wallpaperimage "${target}" >/dev/null 2>&1; then
    install -d -m 0700 "${STATE_DIR}"
    # Record the path as well as the phase. The phase alone answers "have I
    # already done this hour"; the path is what lets the check above tell our
    # own wallpaper apart from one the user chose.
    printf '%s %s' "${phase}" "${target}" > "${LAST_SET}"
    log "set ${phase} wallpaper"
else
    log "could not apply wallpaper"
fi
