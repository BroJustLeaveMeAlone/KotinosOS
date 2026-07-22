#!/usr/bin/env bash
#
# First-run setup, executed once per user on first graphical login.
#
# Applies the defaults that make a fresh machine feel finished rather than
# generic: accent colour, light/dark following the clock, and the browser and
# search engine the user picked. Everything here is a *default* the user can
# change afterwards; none of it is enforcement.
#
# Runs as the user, not as root. These are per-user Plasma settings and writing
# them as root would create files the user cannot later modify -- a mistake that
# looks fine until someone tries to change their own wallpaper.
#
# The interactive wizard (asking name, accent, browser) belongs to the graphical
# first-run app. This script applies the answers and provides sane defaults when
# there are none, so an unattended install still ends up somewhere sensible.

set -uo pipefail

CONF=/usr/lib/kotinos/firstrun.conf
STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/kotinos"
STAMP="${STATE_DIR}/.firstrun-done"

log() { echo "kotinos-firstrun: $*"; }

[[ -r "${CONF}" ]] && . "${CONF}"

ACCENT="${KOTINOS_ACCENT:-#0f766e}"          # teal, matching the wreath
COLOUR_SCHEME="${KOTINOS_COLOUR_SCHEME:-auto}"
BROWSER="${KOTINOS_BROWSER:-firefox}"
SEARCH="${KOTINOS_SEARCH:-duckduckgo}"

if [[ -e "${STAMP}" ]]; then
    log "already run for ${USER}; nothing to do"
    exit 0
fi

command -v kwriteconfig6 >/dev/null 2>&1 || {
    log "kwriteconfig6 unavailable; is this a Plasma session?"
    exit 0
}

# --- Accent colour ----------------------------------------------------------
# Plasma wants comma-separated RGB, not hex.
hex="${ACCENT#\#}"
rgb="$((16#${hex:0:2})),$((16#${hex:2:2})),$((16#${hex:4:2}))"
kwriteconfig6 --file kdeglobals --group General --key AccentColor "${rgb}"
kwriteconfig6 --file kdeglobals --group General --key accentColorFromWallpaper false
log "accent set to ${ACCENT}"

# --- Light / dark -----------------------------------------------------------
# "auto" follows sunrise and sunset, which is the comfort default: the machine
# should track the day without being asked.
case "${COLOUR_SCHEME}" in
    dark)  kwriteconfig6 --file kdeglobals --group General --key ColorScheme "BreezeDark" ;;
    light) kwriteconfig6 --file kdeglobals --group General --key ColorScheme "BreezeLight" ;;
    auto|*)
        kwriteconfig6 --file kdeglobals --group General --key ColorScheme "BreezeLight"
        kwriteconfig6 --file kwinrc --group NightColor --key Active true
        kwriteconfig6 --file kwinrc --group NightColor --key Mode Automatic
        ;;
esac
log "colour scheme: ${COLOUR_SCHEME}"

# --- Default browser --------------------------------------------------------
if command -v xdg-settings >/dev/null 2>&1; then
    for candidate in "${BROWSER}.desktop" "org.mozilla.${BROWSER}.desktop"; do
        if xdg-settings set default-web-browser "${candidate}" 2>/dev/null; then
            log "default browser: ${candidate}"
            break
        fi
    done
fi

# --- Search engine ----------------------------------------------------------
# Privacy-respecting by default, consistent with the product's stance. The user
# can change it; it simply should not default to tracking them.
kwriteconfig6 --file kuriikwsfilterrc --group General --key DefaultWebShortcut "${SEARCH}"
log "search engine: ${SEARCH}"

# --- Motion -----------------------------------------------------------------
# Animation *speed* only. The spring-physics motion system is M3.5; this makes
# sure the desktop is not shipping Plasma's default timing in the meantime.
kwriteconfig6 --file kdeglobals --group KDE --key AnimationDurationFactor 0.85

install -d -m 0700 "${STATE_DIR}"
printf 'completed=%s\naccent=%s\nbrowser=%s\nsearch=%s\n' \
    "$(date -u +%FT%TZ)" "${ACCENT}" "${BROWSER}" "${SEARCH}" > "${STAMP}"

log "done"
