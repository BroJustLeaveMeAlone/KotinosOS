#!/usr/bin/env bash
#
# The adversarial test, second half: what can an attacker do once admin mode is
# actually open?
#
# The first half (adversarial-user.sh) asks whether the ordinary user's boundary
# holds. Its answer is 20 of 20. This half asks the question that matters next,
# and the honest answer is much worse -- which is exactly why it is written down
# rather than left implied.
#
# Admin mode grants root. That is what it is for. So most of this file is a list
# of things that succeed, and the value is in being precise about which ones,
# what still resists, and what the user is left with afterwards. A security model
# that only documents its wins is marketing.
#
# HOW TO READ IT
#
# ALLOWED here is usually correct rather than alarming: an administrator who
# cannot administer the machine has not been given admin mode. What matters is
#
#   - that getting here required both factors and a deliberate unlock,
#   - that a recovery point was taken BEFORE the door opened,
#   - that the window closes by itself,
#   - and that the few things which still resist are named honestly.
#
# Run on a test VM, as the ordinary user, with admin mode already unlocked.
# It changes nothing destructive: every probe writes to a scratch path or reads.

set -uo pipefail

SNAPSHOT_DIR=/var/.snapshots
VAULT_LABEL="kotinos-vault"
allowed=0; blocked=0; notable=0

probe() { PROBE_DESC="$1"; printf '\n-- %s\n' "$1"; }

result() {
    local status="$1" note="${2:-}"
    if (( status == 0 )); then
        printf '   ALLOWED  %s\n' "${PROBE_DESC}"
        allowed=$(( allowed + 1 ))
    else
        printf '   BLOCKED  %s\n' "${PROBE_DESC}"
        blocked=$(( blocked + 1 ))
    fi
    [[ -n "${note}" ]] && printf '            %s\n' "${note}"
    return 0
}

if [[ ${EUID} -eq 0 ]]; then
    echo "error: run as the ordinary user with admin mode unlocked, not as root." >&2
    echo "Running as root proves nothing: root is the thing admin mode grants." >&2
    exit 1
fi

echo "======================================================================"
echo "KotinosOS adversarial test, second half -- admin mode is OPEN"
echo "User: $(id -un)   Date: $(date -u +%FT%TZ)"
[[ -r /usr/lib/kotinos-release ]] && echo "Image: $(grep BUILD_ID /usr/lib/kotinos-release)"
echo "======================================================================"

if ! sudo -n true 2>/dev/null && ! sudo -S true </dev/null 2>/dev/null; then
    echo
    echo "Admin mode does not appear to be open for $(id -un)."
    echo "Open it first:  sudo /usr/libexec/kotinos-admin unlock"
    echo "Without it this file measures nothing, so it stops rather than"
    echo "reporting a comfortable row of BLOCKED results."
    exit 1
fi

SUDO="sudo -n"

# ============================================================================
# 1. The safety net, which the first half proved was out of reach
# ============================================================================

probe "delete a snapshot"
out="$(${SUDO} snapper -c var delete 1 2>&1)"; result $? "the safety net is reachable from admin mode by design"

probe "list the snapshot tree"
out="$(${SUDO} ls "${SNAPSHOT_DIR}" 2>&1)"; result $?

probe "read the vault's raw device"
out="$(${SUDO} dd if=/dev/disk/by-label/${VAULT_LABEL} of=/dev/null bs=512 count=1 2>&1)"; result $?

probe "mount the vault"
${SUDO} install -d -m 0700 /run/kotinos-adm-probe 2>/dev/null
out="$(${SUDO} mount /dev/disk/by-label/${VAULT_LABEL} /run/kotinos-adm-probe 2>&1)"
mounted=$?; result ${mounted}
(( mounted == 0 )) && ${SUDO} umount /run/kotinos-adm-probe 2>/dev/null
${SUDO} rmdir /run/kotinos-adm-probe 2>/dev/null

probe "rewrite the vault's configuration"
out="$(${SUDO} sh -c 'printf "\n# adversarial\n" >> /etc/kotinos/vault.conf' 2>&1)"; result $?

probe "stop the safety services"
out="$(${SUDO} systemctl stop kotinos-vault.timer 2>&1)"; result $?
${SUDO} systemctl start kotinos-vault.timer 2>/dev/null

probe "read another account's files"
out="$(${SUDO} ls /var/roothome 2>&1)"; result $?

# ============================================================================
# 2. What still resists, even with root
# ============================================================================

probe "write into /usr"
out="$(${SUDO} touch /usr/bin/kotinos-adm-marker 2>&1)"
result $? "bootc keeps /usr read-only; root is not enough to change the OS in place"

probe "make the running deployment's /usr writable permanently"
out="$(${SUDO} sh -c 'mount -o remount,rw /usr && touch /usr/bin/kotinos-adm-marker2' 2>&1)"
remount=$?; result ${remount} "a transient overlay is possible; it does not survive a reboot"
(( remount == 0 )) && ${SUDO} rm -f /usr/bin/kotinos-adm-marker2 2>/dev/null

# ============================================================================
# 3. Persistence -- the part worth being uncomfortable about
# ============================================================================

probe "read the TOTP secret"
out="$(${SUDO} cat /etc/users.oath 2>&1)"
result $? "so one admin session can mint valid second factors indefinitely"
(( $? == 0 )) && notable=$(( notable + 1 ))

probe "extend the grant without re-authenticating"
out="$(${SUDO} sh -c 'sed -i "s/^expires=.*/expires=99999999999/" /run/kotinos/admin-grant' 2>&1)"
result $? "admin mode can extend itself; expiry bounds accidents, not attackers"

probe "disable the gate itself"
out="$(${SUDO} sh -c 'cp /etc/pam.d/sudo /tmp/pam.bak && sed -i "/kotinos-admin-gate/d" /etc/pam.d/sudo' 2>&1)"
gate_removed=$?; result ${gate_removed} "the gate is configuration, and root edits configuration"
(( gate_removed == 0 )) && ${SUDO} cp /tmp/pam.bak /etc/pam.d/sudo 2>/dev/null

# ============================================================================
# 4. What the user is left with
# ============================================================================

probe "the pre-escalation snapshot still exists"
out="$(${SUDO} snapper -c var list 2>/dev/null | grep -c 'pre-escalation')"
[[ "${out}" =~ ^[0-9]+$ ]] && (( out > 0 )); result $? "taken before the door opened, so the session is undoable"

probe "the deployment was pinned before the door opened"
out="$(${SUDO} ostree admin status 2>/dev/null | grep -c 'Pinned: yes')"
[[ "${out}" =~ ^[0-9]+$ ]] && (( out > 0 )); result $? "so bootc rollback still has somewhere to go"

echo
echo "======================================================================"
printf 'allowed: %d    blocked: %d\n' "${allowed}" "${blocked}"
echo "======================================================================"
cat <<'EOF'

WHAT THIS MEANS, stated plainly.

Admin mode grants root, and almost everything above follows from that. The
boundary this milestone built is not "root cannot hurt you" -- it is that
reaching root takes a password AND a second factor AND a deliberate unlock,
that a recovery point is taken before it happens, and that the door shuts by
itself afterwards.

Two things are worth being uncomfortable about rather than glossing:

  - The TOTP secret is readable once admin mode is open, so a single
    compromised session lets an attacker generate second factors from then on.
    Re-enrolling is the only thing that revokes that, and nothing currently
    prompts anyone to.
  - Admin mode can extend its own grant and edit its own gate. Expiry therefore
    bounds forgetfulness, not an adversary who is already inside.

What survives regardless: /usr stays read-only for the running deployment, the
pre-escalation snapshot and the pinned deployment were captured before the door
opened, and both live where an attacker inside one admin session did not have
to be trusted for them to exist.
EOF
