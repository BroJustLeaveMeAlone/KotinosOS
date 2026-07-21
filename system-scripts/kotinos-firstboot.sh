#!/usr/bin/env bash
#
# First-boot provisioning.
#
# Accounts cannot be created at image build time: /var is its own btrfs
# subvolume and does not inherit the image's /var, so systemd-tmpfiles lays
# down a bare skeleton and anything baked in is discarded. Every home lives
# under /var (/home -> /var/home, /root -> /var/roothome), so the account has
# to be created here, on the booted machine.
#
# Runs exactly once, gated by a stamp file in /var.

set -euo pipefail

CONF=/usr/lib/kotinos/firstboot.conf
STAMP_DIR=/var/lib/kotinos
STAMP="${STAMP_DIR}/.provisioned"

log() { echo "kotinos-firstboot: $*"; }

[[ -r "${CONF}" ]] && . "${CONF}"

USERNAME="${KOTINOS_USER:-kotinos}"
USER_GROUPS="${KOTINOS_GROUPS:-wheel}"
USER_SHELL="${KOTINOS_SHELL:-/bin/bash}"
KEYFILE="${KOTINOS_AUTHORIZED_KEYS:-/usr/lib/kotinos/authorized_keys}"
HOME_DIR="/var/home/${USERNAME}"

# /var must be the real mount, not the pre-mount directory, or we would
# provision into a filesystem that is about to be hidden.
if ! findmnt --target /var >/dev/null 2>&1; then
    log "ERROR: /var is not mounted; refusing to provision"
    exit 1
fi

if [[ -e "${STAMP}" ]]; then
    log "already provisioned; nothing to do"
    exit 0
fi

if getent passwd "${USERNAME}" >/dev/null 2>&1; then
    log "user ${USERNAME} already exists; not modifying it"
else
    log "creating user ${USERNAME} (groups: ${USER_GROUPS})"
    # Home is set explicitly: useradd's default would go through the /home
    # symlink, and being explicit keeps it obvious where the data lands.
    useradd \
        --create-home \
        --home-dir "${HOME_DIR}" \
        --shell "${USER_SHELL}" \
        --groups "${USER_GROUPS}" \
        "${USERNAME}"

    # Locked password: login is by key until the first-run experience (M3)
    # collects a real one. Locked is not the same as empty -- an empty
    # password would allow passwordless console login.
    passwd --lock "${USERNAME}" >/dev/null
fi

if [[ -s "${KEYFILE}" ]]; then
    log "installing authorized_keys for ${USERNAME}"
    install -d -m 0700 -o "${USERNAME}" -g "${USERNAME}" "${HOME_DIR}/.ssh"
    install -m 0600 -o "${USERNAME}" -g "${USERNAME}" "${KEYFILE}" "${HOME_DIR}/.ssh/authorized_keys"
else
    log "no authorized_keys supplied at ${KEYFILE}; skipping"
fi

# SELinux labels: files created here inherit the wrong type, and sshd will
# silently refuse a correctly-formed authorized_keys that is mislabelled.
if command -v restorecon >/dev/null 2>&1; then
    log "restoring SELinux contexts on ${HOME_DIR}"
    restorecon -RF "${HOME_DIR}" || log "WARNING: restorecon failed"
fi

install -d -m 0755 "${STAMP_DIR}"
printf 'provisioned=%s\nuser=%s\n' "$(date -u +%FT%TZ)" "${USERNAME}" > "${STAMP}"
log "done"
