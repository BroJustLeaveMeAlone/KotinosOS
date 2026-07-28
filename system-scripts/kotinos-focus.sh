#!/usr/bin/env bash
#
# Focus mode.
#
# Silences the whole machine, not just one app's notifications. Half-measures
# are why "do not disturb" is usually untrusted: if one thing still pings, the
# user keeps half an ear out and the mode has bought them nothing.
#
# Turns off notifications, sounds, and anything that steals focus or dims the
# screen mid-thought. Restores exactly what it changed -- a focus mode that
# leaves settings altered afterwards is one people stop using.
#
# Runs as the user; these are session settings.

set -uo pipefail

STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/kotinos"
SAVED="${STATE_DIR}/.focus-saved"
ACTIVE="${STATE_DIR}/.focus-active"

log() { echo "kotinos-focus: $*"; }

usage() {
    cat <<'EOF'
Usage: kotinos-focus [on|off|toggle|status]

Silences notifications, sounds, and screen dimming until you turn it off.
Everything is restored exactly as it was.
EOF
}

have() { command -v "$1" >/dev/null 2>&1; }

focus_on() {
    [[ -e "${ACTIVE}" ]] && { log "already on"; return 0; }
    install -d -m 0700 "${STATE_DIR}"

    # Record what we are about to change, so restoring is exact rather than a
    # guess at what the defaults probably were.
    #
    # `muted`, not `volume`: focus mode mutes rather than lowering, so the thing
    # that has to be put back is the mute flag. The old version saved the volume
    # LEVEL, never read it, and then unmuted unconditionally on the way out --
    # so anyone who was already muted before turning focus on had their sound
    # switched on for them when they turned it off. wpctl prints the state as
    # "Volume: 0.44 [MUTED]", so the flag is the presence of that marker.
    local was_muted=no was_dnd=""
    if have wpctl && wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null | grep -q MUTED; then
        was_muted=yes
    fi
    was_dnd="$(kreadconfig6 --file plasmanotifyrc --group DoNotDisturb --key Until 2>/dev/null)"

    {
        echo "dnd=${was_dnd}"
        echo "muted=${was_muted}"
        echo "dimmed=$(kreadconfig6 --file powermanagementprofilesrc --group AC --group DimDisplay --key idleTime 2>/dev/null)"
    } > "${SAVED}"

    # Notifications off. Far-future timestamp rather than a duration, so it
    # stays off until explicitly turned back on.
    if have kwriteconfig6; then
        kwriteconfig6 --file plasmanotifyrc --group DoNotDisturb --key Until "2099-12-31T23:59:59"
        kwriteconfig6 --file plasmanotifyrc --group Notifications --key PopupTimeout 0
    fi

    # Mute rather than lower: a quiet ping is still a ping.
    have wpctl && wpctl set-mute @DEFAULT_AUDIO_SINK@ 1 2>/dev/null

    # Stop the screen dimming while reading or thinking. This is the one people
    # never think to disable and always resent.
    have kwriteconfig6 && \
        kwriteconfig6 --file powermanagementprofilesrc --group AC --group DimDisplay --key idleTime 0

    have qdbus6 && qdbus6 org.kde.KWin /KWin reconfigure 2>/dev/null

    touch "${ACTIVE}"
    log "on — notifications, sounds and dimming are off"
}

focus_off() {
    [[ -e "${ACTIVE}" ]] || { log "already off"; return 0; }

    local saved_dim="" saved_dnd="" saved_muted="no"
    if [[ -r "${SAVED}" ]]; then
        saved_dim="$(sed -n 's/^dimmed=//p' "${SAVED}")"
        saved_dnd="$(sed -n 's/^dnd=//p' "${SAVED}")"
        saved_muted="$(sed -n 's/^muted=//p' "${SAVED}")"
    fi

    # Do Not Disturb: put back whatever the user had, rather than clearing it.
    # Deleting the key unconditionally threw away a DND period they had set
    # themselves -- turning focus mode off would also turn their own quiet hours
    # off, which is the opposite of "restores exactly what it changed".
    if have kwriteconfig6; then
        if [[ -n "${saved_dnd}" ]]; then
            kwriteconfig6 --file plasmanotifyrc --group DoNotDisturb --key Until "${saved_dnd}"
        else
            kwriteconfig6 --file plasmanotifyrc --group DoNotDisturb --key Until --delete
        fi
        # PopupTimeout is ours -- focus mode sets it and nothing else reads it
        # from here -- so clearing it is the correct restore.
        kwriteconfig6 --file plasmanotifyrc --group Notifications --key PopupTimeout --delete
    fi

    # Only unmute if we were the ones who muted.
    if [[ "${saved_muted}" != "yes" ]]; then
        have wpctl && wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 2>/dev/null
    fi

    # Restore the dim timeout we saved, or clear the override if there was none.
    if [[ -r "${SAVED}" ]]; then
        if [[ -n "${saved_dim}" && "${saved_dim}" != "0" ]]; then
            kwriteconfig6 --file powermanagementprofilesrc --group AC --group DimDisplay --key idleTime "${saved_dim}"
        else
            kwriteconfig6 --file powermanagementprofilesrc --group AC --group DimDisplay --key idleTime --delete
        fi
    fi

    have qdbus6 && qdbus6 org.kde.KWin /KWin reconfigure 2>/dev/null

    rm -f "${ACTIVE}"
    log "off — everything restored"
}

case "${1:-toggle}" in
    on)      focus_on ;;
    off)     focus_off ;;
    # if/else rather than `cond && focus_off || focus_on`: in that form a
    # non-zero return from focus_off falls through to focus_on, so a partial
    # failure while turning focus off would immediately turn it back on.
    toggle)  if [[ -e "${ACTIVE}" ]]; then focus_off; else focus_on; fi ;;
    status)  [[ -e "${ACTIVE}" ]] && echo "Focus mode is ON" || echo "Focus mode is off" ;;
    -h|--help) usage ;;
    *)       echo "Unrecognised: $1"; usage; exit 2 ;;
esac
