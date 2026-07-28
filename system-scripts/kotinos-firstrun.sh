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

ACCENT="#0f766e"          # teal, matching the wreath
COLOUR_SCHEME="auto"
BROWSER="firefox"
SEARCH="duckduckgo"

# Parsed, not sourced, for the same reasons as the vault's config: a stray
# quote in an answers file should cost that one answer, not abort setup and
# leave a half-configured desktop. The risk here is smaller than the vault's --
# this file lives in read-only /usr rather than /etc, so it is not user-writable
# -- but the failure mode is identical and the parser is six lines.
#
# The graphical wizard writes this file, so it is also the boundary between a
# UI and a shell script. Keeping it inert means the wizard can never emit
# something that executes, however it is later changed.
if [[ -r "${CONF}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line%%[[:space:]]#*}"
        [[ "${line}" == \#* || -z "${line}" ]] && continue
        # Reported as a malformed line rather than falling through to the key
        # handling, where a line with no '=' turns into a key made of the whole
        # sentence with its spaces stripped -- a confusing way to say "this is
        # not a setting".
        if [[ "${line}" != *=* ]]; then
            log "ignoring line without a setting in ${CONF}: ${line}"
            continue
        fi
        key="${line%%=*}"
        value="${line#*=}"
        key="${key//[[:space:]]/}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        [[ "${value}" == \"*\" ]] && value="${value:1:-1}"
        [[ "${value}" == \'*\' ]] && value="${value:1:-1}"
        case "${key}" in
            KOTINOS_ACCENT)        ACCENT="${value}" ;;
            KOTINOS_COLOUR_SCHEME) COLOUR_SCHEME="${value}" ;;
            KOTINOS_BROWSER)       BROWSER="${value}" ;;
            KOTINOS_SEARCH)        SEARCH="${value}" ;;
            "")                    ;;
            *) log "ignoring unknown setting '${key}' in ${CONF}" ;;
        esac
    done < "${CONF}"
fi

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
#
# Validated first, because $((16#zz)) is a fatal arithmetic error rather than a
# zero: an accent of "teal" or a truncated "#0f76" would abort here, or write a
# malformed value into kdeglobals and leave the desktop looking wrong for a
# reason nobody would connect to a config file.
hex="${ACCENT#\#}"
if [[ ! "${hex}" =~ ^[0-9a-fA-F]{6}$ ]]; then
    log "accent '${ACCENT}' is not a 6-digit hex colour; using the default"
    hex="0f766e"
fi
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
