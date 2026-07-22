#!/usr/bin/env bash
#
# Apply a theme preset.
#
# Sets accent, colour scheme and wallpaper together, because those three fight
# each other when chosen independently. A teal accent over an ember wallpaper is
# not a preference anyone expressed, it is what happens when three separate
# settings each look fine on their own.
#
# Runs as the user; these are session settings. Setting them as root creates
# files the user then cannot change.

set -uo pipefail

PRESETS=/usr/lib/kotinos/themes.conf
WALLPAPER_DIR=/usr/share/kotinos/wallpapers
STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/kotinos"

log() { echo "kotinos-theme: $*"; }

usage() {
    cat <<'EOF'
Usage: kotinos-theme [name]

  kotinos-theme            list the available looks
  kotinos-theme <name>     apply one

Each look sets the accent colour, light/dark behaviour and wallpaper together,
so they always match.
EOF
}

[[ -r "${PRESETS}" ]] || { echo "No presets installed at ${PRESETS}"; exit 1; }

list_presets() {
    printf '%-10s %-12s %-9s %s\n' "NAME" "LOOK" "SCHEME" "WALLPAPER"
    while IFS='|' read -r name label accent scheme paper; do
        [[ -z "${name}" || "${name}" == \#* ]] && continue
        printf '%-10s %-12s %-9s %s\n' "${name}" "${label}" "${scheme}" "${paper}"
    done < "${PRESETS}"
}

case "${1:-}" in
    ""|list)   list_presets; exit 0 ;;
    -h|--help) usage; exit 0 ;;
esac

wanted="$1"
found=""
while IFS='|' read -r name label accent scheme paper; do
    [[ -z "${name}" || "${name}" == \#* ]] && continue
    if [[ "${name}" == "${wanted}" ]]; then
        found=1
        break
    fi
done < "${PRESETS}"

[[ -n "${found}" ]] || { echo "No look called '${wanted}'. Try: kotinos-theme"; exit 1; }

command -v kwriteconfig6 >/dev/null 2>&1 || {
    log "kwriteconfig6 unavailable; is this a Plasma session?"
    exit 1
}

# --- accent -----------------------------------------------------------------
hex="${accent#\#}"
rgb="$((16#${hex:0:2})),$((16#${hex:2:2})),$((16#${hex:4:2}))"
kwriteconfig6 --file kdeglobals --group General --key AccentColor "${rgb}"
kwriteconfig6 --file kdeglobals --group General --key accentColorFromWallpaper false

# --- colour scheme ----------------------------------------------------------
case "${scheme}" in
    dark)
        kwriteconfig6 --file kdeglobals --group General --key ColorScheme "BreezeDark"
        kwriteconfig6 --file kwinrc --group NightColor --key Active false
        ;;
    light)
        kwriteconfig6 --file kdeglobals --group General --key ColorScheme "BreezeLight"
        kwriteconfig6 --file kwinrc --group NightColor --key Active false
        ;;
    auto|*)
        kwriteconfig6 --file kdeglobals --group General --key ColorScheme "BreezeLight"
        kwriteconfig6 --file kwinrc --group NightColor --key Active true
        kwriteconfig6 --file kwinrc --group NightColor --key Mode Automatic
        ;;
esac

# --- wallpaper --------------------------------------------------------------
install -d -m 0700 "${STATE_DIR}"
if [[ "${paper}" == "time" ]]; then
    # Hand back to the time-of-day switcher and let it choose now.
    rm -f "${STATE_DIR}/.wallpaper-manual" "${STATE_DIR}/.wallpaper-last"
    [[ -x /usr/libexec/kotinos-wallpaper ]] && /usr/libexec/kotinos-wallpaper >/dev/null 2>&1
else
    target="${WALLPAPER_DIR}/kotinos-${paper}.png"
    if [[ -r "${target}" ]] && command -v plasma-apply-wallpaperimage >/dev/null 2>&1; then
        plasma-apply-wallpaperimage "${target}" >/dev/null 2>&1
        # A fixed wallpaper is a deliberate choice, so stop the clock overriding
        # it an hour later.
        touch "${STATE_DIR}/.wallpaper-manual"
    fi
fi

printf '%s' "${wanted}" > "${STATE_DIR}/.theme"
log "applied '${label}'"
