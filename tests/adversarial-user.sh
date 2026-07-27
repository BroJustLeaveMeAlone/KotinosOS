#!/usr/bin/env bash
#
# The adversarial test: what can a hostile process do with the user's own hands?
#
# This is the test that turns the security story from a claim into evidence. It
# runs as the ordinary user -- no sudo, no password, nothing the user would not
# already have -- and tries to do what ransomware does: destroy the safety net,
# reach the vault, read what belongs to someone else, and switch off the
# services that would undo it.
#
# It is NOT shipped in the image. An attack script living in /usr on every
# release machine would be a convenience for the attacker and nothing else.
# Copy it to a test VM, run it there, and record what it says.
#
# HOW TO READ THE OUTPUT
#
# Every probe prints BLOCKED or ALLOWED, and ALLOWED is not automatically a
# failure -- a user is supposed to be able to encrypt their own documents, and
# an OS that prevented it would be broken rather than secure. What matters is
# that everything ALLOWED is something we decided to allow, and that the
# recovery path still exists afterwards. Each probe therefore carries its own
# expectation, and the summary counts only the ones that came out the wrong way.
#
# The honest framing from the milestone brief applies: this proves the specific
# claims below and nothing wider. Anything not probed here is not counted.

set -uo pipefail

VAULT_LABEL="kotinos-vault"
SNAPSHOT_DIR=/var/.snapshots
SCRATCH="${HOME}/.kotinos-adversarial-scratch"

pass=0        # came out as expected
fail=0        # came out the wrong way -- a boundary that is not holding
noted=0       # allowed on purpose, recorded so it stays a decision

# --- reporting --------------------------------------------------------------
#
# The reason each probe prints the error it actually got is that "BLOCKED" on
# its own is untrustworthy: a command that fails because it is not installed
# also prints nothing and returns non-zero, and would look exactly like a
# boundary holding. The message is what distinguishes "permission denied" from
# "command not found", and only the first one is a security property.

probe() {
    # probe <expectation: blocked|allowed> <description>
    PROBE_EXPECT="$1"
    PROBE_DESC="$2"
    printf '\n%s\n' "-- ${PROBE_DESC}"
}

verdict() {
    # verdict <exit-status> <captured output>
    local status="$1" output="${2:-}"
    local outcome

    if (( status == 0 )); then outcome=allowed; else outcome=blocked; fi

    if [[ "${outcome}" == "${PROBE_EXPECT}" ]]; then
        if [[ "${outcome}" == allowed ]]; then
            printf '   ALLOWED (expected)  %s\n' "${PROBE_DESC}"
            noted=$(( noted + 1 ))
        else
            printf '   BLOCKED (expected)  %s\n' "${PROBE_DESC}"
            pass=$(( pass + 1 ))
        fi
    else
        printf '   *** %s -- EXPECTED %s *** %s\n' \
            "${outcome^^}" "${PROBE_EXPECT^^}" "${PROBE_DESC}"
        fail=$(( fail + 1 ))
    fi

    [[ -n "${output}" ]] && printf '      reason: %s\n' \
        "$(printf '%s' "${output}" | head -2 | tr '\n' ' ')"
    return 0
}

# --- preconditions ----------------------------------------------------------
#
# Running this as root would prove nothing at all: root is supposed to be able
# to do every one of these things. The whole point is the boundary at the
# ordinary user's privilege level, so refuse to run as anyone else.

if [[ ${EUID} -eq 0 ]]; then
    echo "error: run this as the ordinary user, not root." >&2
    echo "As root every probe below succeeds by design and proves nothing." >&2
    exit 1
fi

echo "======================================================================"
echo "KotinosOS adversarial test -- running as $(id -un) (uid ${EUID})"
echo "Host: $(hostname)   Date: $(date -u +%FT%TZ)"
[[ -r /usr/lib/kotinos-release ]] && echo "Image: $(cat /usr/lib/kotinos-release)"
echo "======================================================================"

# ============================================================================
# 1. Destroy the safety net
# ============================================================================
# The central promise of the whole project is that nothing can delete the
# safety net. These are the ways a process at the user's privilege would try.

probe blocked "delete snapshots with snapper"
out="$(snapper -c var delete 1 2>&1)"; verdict $? "${out}"

probe blocked "delete the snapshot subvolume directly with btrfs"
out="$(btrfs subvolume delete "${SNAPSHOT_DIR}"/1/snapshot 2>&1)"; verdict $? "${out}"

# Guarded because `rm -rf` on a path that does not exist succeeds silently, and
# that would be scored as the boundary failing when in fact nothing was there to
# protect. A missing snapshot directory is its own problem and says so.
if [[ -e "${SNAPSHOT_DIR}" ]]; then
    probe blocked "remove the snapshot directory with rm -rf"
    out="$(rm -rf "${SNAPSHOT_DIR}" 2>&1)"; verdict $? "${out}"
else
    printf '\n%s\n' "-- remove the snapshot directory with rm -rf"
    printf '   *** %s does not exist -- the safety net is ABSENT, not protected ***\n' \
        "${SNAPSHOT_DIR}"
    fail=$(( fail + 1 ))
fi

probe blocked "list snapshots (reading the safety net's contents)"
out="$(ls "${SNAPSHOT_DIR}" 2>&1)"; verdict $? "${out}"

# ============================================================================
# 2. Reach the vault
# ============================================================================
# The vault is a separate partition that stays unmounted, and the backup
# service mounts it inside its own mount namespace. Both properties are
# supposed to make it unreachable from here -- so probe both.

probe blocked "mount the vault partition by label"
out="$(mount "/dev/disk/by-label/${VAULT_LABEL}" /mnt 2>&1)"; verdict $? "${out}"

probe blocked "read the vault's raw block device"
out="$(dd if="/dev/disk/by-label/${VAULT_LABEL}" of=/dev/null bs=512 count=1 2>&1)"
verdict $? "${out}"

probe blocked "write to the vault's raw block device"
out="$(dd if=/dev/zero of="/dev/disk/by-label/${VAULT_LABEL}" bs=512 count=1 2>&1)"
verdict $? "${out}"

probe blocked "see the vault mounted anywhere in this namespace"
out="$(findmnt -n -S LABEL="${VAULT_LABEL}" 2>&1)"; verdict $? "${out}"

probe blocked "reach the service's vault mountpoint"
out="$(ls /run/kotinos-vault 2>&1)"; verdict $? "${out}"

# ============================================================================
# 3. Read what belongs to someone else
# ============================================================================

probe blocked "read root's home"
out="$(ls /var/roothome 2>&1)"; verdict $? "${out}"

probe blocked "read the shadow password file"
out="$(cat /etc/shadow 2>&1)"; verdict $? "${out}"

# Another user's home, if there is one. Skipped rather than faked when the test
# machine has a single account -- a probe that did not run must not be counted
# as a boundary that held.
other_home=""
for h in /var/home/*; do
    [[ -d "${h}" && "${h}" != "${HOME}" ]] && { other_home="${h}"; break; }
done
if [[ -n "${other_home}" ]]; then
    probe blocked "read another user's home (${other_home})"
    out="$(ls "${other_home}" 2>&1)"; verdict $? "${out}"
else
    printf '\n%s\n' "-- read another user's home"
    printf '   SKIPPED  only one account on this machine; not counted either way\n'
fi

# ============================================================================
# 4. Switch off the services that would undo the damage
# ============================================================================
# Ransomware that cannot delete the snapshots will settle for stopping the
# thing that makes them.

# --no-ask-password on every one of these, and it is not optional. Without it,
# systemctl asks polkit, and in a desktop session polkit pops an authentication
# dialog and waits -- so the test would hang forever on a graphical VM instead
# of reporting anything, and would appear to pass when run over SSH where no
# agent exists. Real ransomware would not be offered a password prompt either.
sysctl_probe() {
    systemctl --no-ask-password "$@" 2>&1
}

probe blocked "stop the vault backup timer"
out="$(sysctl_probe stop kotinos-vault.timer)"; verdict $? "${out}"

probe blocked "disable the vault backup timer"
out="$(sysctl_probe disable kotinos-vault.timer)"; verdict $? "${out}"

probe blocked "mask the snapshot service"
out="$(sysctl_probe mask kotinos-snapshots.service)"; verdict $? "${out}"

probe blocked "stop snapper's own timer"
out="$(sysctl_probe stop snapper-timeline.timer)"; verdict $? "${out}"

# ============================================================================
# 5. Tamper with the system itself
# ============================================================================

probe blocked "write into /usr (immutable on bootc)"
out="$(touch /usr/bin/kotinos-adversarial-marker 2>&1)"; verdict $? "${out}"

probe blocked "write a systemd unit into /etc"
out="$(touch /etc/systemd/system/kotinos-adversarial.service 2>&1)"; verdict $? "${out}"

# Tampering with the safety net's own configuration, rather than with the
# snapshots themselves. This is the quiet version of the attack: vault.conf
# decides what gets backed up, so appending an exclusion for the user's
# documents leaves the vault running, reporting success, and protecting nothing
# that matters. Added because it was real -- these files shipped world-writable
# and the user could edit them (27 Jul 2026).
probe blocked "rewrite the vault's configuration"
out="$(printf '\n# adversarial\n' >> /etc/kotinos/vault.conf 2>&1)"; verdict $? "${out}"

probe blocked "rewrite the shared desktop configuration"
out="$(printf '\n' >> /etc/xdg/kwinrc 2>&1)"; verdict $? "${out}"

probe blocked "modify a KotinosOS systemd unit"
out="$(printf '\n' >> /usr/lib/systemd/system/kotinos-vault.service 2>&1)"; verdict $? "${out}"

probe blocked "escalate with sudo without a password"
out="$(sudo -n true 2>&1)"; verdict $? "${out}"

# kptr_restrict hides kernel symbol addresses from unprivileged readers by
# reporting them as zeros. So the probe is "can I find a single non-zero
# address?": awk exits 0 the moment it finds one (a leak, ALLOWED) and exits 1
# if every address was zeroed (the protection working, BLOCKED).
probe blocked "read real kernel symbol addresses (kptr_restrict)"
out="$(awk '$1 !~ /^0+$/ { found = 1; exit } END { exit !found }' \
        /proc/kallsyms 2>&1)"
verdict $? "${out}"

# ============================================================================
# 6. What the user IS allowed to do -- and why that is correct
# ============================================================================
# These are expected to succeed. They are in the test because a boundary model
# is only honest if it states where the boundary deliberately is not.

# Not silenced. An earlier version sent both of these to /dev/null, and when the
# scratch directory could not be created the two probes below reported "BLOCKED"
# -- which read as the OS defending the user's files when in fact the test had
# simply failed to write them. A probe that cannot set itself up must say so,
# not quietly turn into a pass.
if ! mkdir -p "${SCRATCH}" || ! echo "irreplaceable" > "${SCRATCH}/document.txt"; then
    printf '\n%s\n' "-- section 6 (what the user IS allowed to do)"
    printf '   *** CANNOT RUN: %s is not writable by %s ***\n' \
        "${HOME}" "$(id -un)"
    printf '   This is itself a finding: a user who cannot write their own home\n'
    printf '   has a broken account, not a secure one. Check the ownership of\n'
    printf '   %s.\n' "${HOME}"
    fail=$(( fail + 1 ))
    SCRATCH=""
fi

if [[ -n "${SCRATCH}" ]]; then

probe allowed "encrypt the user's own documents (the ransomware payload itself)"
out="$(openssl enc -aes-256-cbc -pbkdf2 -pass pass:hostile \
        -in "${SCRATCH}/document.txt" -out "${SCRATCH}/document.txt.enc" 2>&1 \
        && rm -f "${SCRATCH}/document.txt")"
verdict $? "${out}"

probe allowed "delete the user's own files"
out="$(rm -f "${SCRATCH}/document.txt.enc" 2>&1)"; verdict $? "${out}"

echo
echo "   Both of the above are SUPPOSED to succeed. A user owns their files and"
echo "   an OS that stopped them editing their own documents would be broken,"
echo "   not secure. The claim this project makes is not that the damage cannot"
echo "   happen -- it is that the damage is RECOVERABLE, because the snapshots"
echo "   and the vault copy survived every probe in sections 1 and 2 above."
echo "   If those sections passed and these two succeeded, the model is working"
echo "   exactly as designed."

rmdir "${SCRATCH}" 2>/dev/null

fi   # end of the writable-home guard

# ============================================================================
# Summary
# ============================================================================

echo
echo "======================================================================"
printf 'boundaries held:      %d\n' "${pass}"
printf 'allowed by design:    %d\n' "${noted}"
printf 'CAME OUT WRONG:       %d\n' "${fail}"
echo "======================================================================"

if (( fail > 0 )); then
    echo
    echo "At least one boundary did not behave as the model says it should."
    echo "Record it in TODO.md as-is. A documented hole is worth more than a"
    echo "green run that was quietly adjusted until it passed."
    exit 1
fi

echo
echo "Every probed boundary held. This proves the probes above and nothing"
echo "wider -- an untested claim is still an untested claim."
