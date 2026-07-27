#!/usr/bin/env bash
#
# Attack-surface audit: what is setuid, and what is listening?
#
# Smaller surface is the cheapest hardening there is, but a one-off audit is
# worth very little -- the surface grows back the moment somebody adds a
# package, and nobody re-reads a text file from four months ago. So this is
# written as a regression guard: every setuid binary and every listening socket
# has to appear in the expected list below, with a reason, or this exits
# non-zero and says what is new.
#
# That inverts the usual failure mode. The question stops being "did anyone
# remember to audit?" and becomes "why did the surface change?", which is a
# question the build can ask on its own.
#
# Run on a booted VM. The setuid section also works against the container image
# (`podman run --rm localhost/kotinos:TAG /path/to/attack-surface.sh`), but the
# listening-socket section needs a real boot with services actually started --
# and running it in a container would report an empty, flattering result.

set -uo pipefail

findings=0

# ============================================================================
# Expected setuid/setgid binaries
# ============================================================================
#
# Each entry is "path  reason it stays". A setuid binary is a program that runs
# as someone else on the user's say-so, so each one is a place the privilege
# model can be attacked, and each needs to earn its place.

# Paths are all /usr/bin because Fedora merges /usr/sbin into /usr/bin. Writing
# /usr/sbin/unix_chkpwd here would never match and would sit in the list looking
# audited forever.
#
# Worth noting what is NOT in this list: bwrap. Flatpak's sandbox helper is not
# setuid on this image, because modern Flatpak builds its sandboxes out of
# unprivileged user namespaces instead. That is the same kernel feature
# 90-kotinos-sysctl.conf deliberately leaves enabled, and it is why: the choice
# there buys a sandbox that needs no setuid binary at all, which is the better
# trade even though "disable unprivileged userns" reads like the harder line.
#
# Also absent, and left absent: crontab, wall, write, ksu, staprun and
# ssh-keysign. Nothing on an appliance needs them.
read -r -d '' EXPECTED_SUID <<'EOF'
/usr/bin/sudo                     the privilege boundary itself; password-gated escalation
/usr/bin/su                       switch user; part of the same boundary
/usr/bin/passwd                   a user changing their own password writes /etc/shadow
/usr/bin/chage                    password ageing; ships with passwd
/usr/bin/gpasswd                  group password management; ships with passwd
/usr/bin/newgrp                   group switching; ships with passwd
/usr/bin/chfn                     changes the GECOS field; CANDIDATE FOR REMOVAL, see note below
/usr/bin/chsh                     changes the login shell; CANDIDATE FOR REMOVAL, see note below
/usr/bin/mount                    non-root mounting of removable media
/usr/bin/umount                   pairs with mount
/usr/bin/mount.nfs                NFS mount helper; ships with util-linux
/usr/bin/fusermount3              what FUSE filesystems use to mount as the user
/usr/bin/pkexec                   polkit escalation, used by the desktop settings UI
/usr/bin/unix_chkpwd              PAM's password verification helper
/usr/bin/pam_timestamp_check      PAM timestamp validation
/usr/bin/grub2-set-bootflag       lets the boot-success machinery record a good boot
/usr/lib/polkit-1/polkit-agent-helper-1   polkit's authentication helper
/usr/libexec/utempter/utempter    setgid utmp; terminal emulators record login sessions
EOF

# chfn and chsh are the two entries here that an appliance has the weakest case
# for. Both are setuid root so a user can edit their own /etc/passwd fields, and
# on a machine with one account and a fixed shell, neither is something the user
# will ever reach for -- the settings app owns the display name. They are left
# in place for now rather than removed on a hunch, because removing them means
# touching the shadow-utils package rather than deleting a file, and that is a
# deliberate change with its own verification. Recorded here so the decision is
# a decision and not an oversight.

# ============================================================================
# Expected listening sockets
# ============================================================================
#
# The appliance should accept no unsolicited connections at all. Everything
# below is either loopback-only (not reachable from the network) or is sshd,
# which exists only in dev builds and is the thing the firewall block in the
# Containerfile removes from the default zone for release.

read -r -d '' EXPECTED_LISTEN <<'EOF'
127.0.0.1     loopback-only; not reachable from any other machine
127.0.0.53    systemd-resolved stub resolver; loopback
127.0.0.54    systemd-resolved; loopback
::1           loopback-only, IPv6
EOF

# The one genuinely reachable inbound service on a release image, listed
# separately because it deserves to be looked at rather than skimmed. Avahi is
# what makes printers and network shares appear without configuration, which is
# most of what an appliance is for, so it is kept deliberately. Anything else
# arriving on a non-loopback address is a finding.
#
# LLMNR (5355) used to be here too and was removed rather than excused; see
# desktop-config/hardening/90-kotinos-resolved.conf.
read -r -d '' EXPECTED_LISTEN_PORTS <<'EOF'
5353          avahi-daemon: mDNS, deliberately open -- see the Containerfile firewall block
EOF

section() { printf '\n== %s ==\n\n' "$1"; }

# Are we in a container rather than on a booted machine?
#
# This matters more than it looks. In a container there is no PID 1 systemd, so
# firewalld reads as "not running"; SELinux reads as "Disabled" because the
# container does not carry the host's policy; and nothing is listening because
# nothing was started. All three would be reported as serious findings, and all
# three would be wrong.
#
# A test that cries wolf in its most alarming section is worse than one that
# stays quiet, because the reader learns to discount exactly the lines that
# would matter on a real machine. So these sections are skipped outright and
# say why, rather than being reported and mentally filtered.
in_container=no
if [[ -f /run/.containerenv || -f /.dockerenv ]] || \
   ! [[ -d /proc/1/root && -r /proc/1/comm ]] || \
   [[ "$(cat /proc/1/comm 2>/dev/null)" != "systemd" ]]; then
    in_container=yes
fi

skip_in_container() {
    printf '  SKIPPED -- %s\n' "$1"
    printf '  Not a finding: this section is only meaningful on a booted machine.\n'
}

echo "======================================================================"
echo "KotinosOS attack-surface audit"
echo "Host: $(hostname)   Date: $(date -u +%FT%TZ)"
[[ -r /usr/lib/kotinos-release ]] && echo "Image: $(cat /usr/lib/kotinos-release)"
echo "======================================================================"

# ============================================================================
# setuid / setgid
# ============================================================================

section "setuid and setgid binaries"

# Exclusions, each for a different reason:
#   /proc, /sys  -- not real files on disk.
#   /var         -- user-installed Flatpaks carry setuid helpers inside their
#                   own runtimes; those are the sandbox's problem, not the base
#                   system's.
#   /sysroot     -- the ostree object store. Every binary in /usr is hardlinked
#                   from an object under /sysroot/ostree/repo/objects, so
#                   including it reports each setuid binary twice, once under an
#                   unreadable checksum name. Same inode, same permissions, no
#                   additional surface -- listing it would only train the reader
#                   to skim past a wall of noise.
actual_suid="$(find / -xdev \
    \( -path /proc -o -path /sys -o -path /var -o -path /sysroot \) -prune -o \
    -type f -perm /6000 -print 2>/dev/null | sort)"

if [[ -z "${actual_suid}" ]]; then
    echo "none found -- suspicious rather than reassuring; check the find ran correctly"
    findings=$(( findings + 1 ))
fi

while IFS= read -r binary; do
    [[ -z "${binary}" ]] && continue
    reason="$(printf '%s\n' "${EXPECTED_SUID}" | awk -v b="${binary}" \
        '$1 == b { $1 = ""; sub(/^ +/, ""); print; found = 1 } END { exit !found }')"
    if [[ -n "${reason}" ]]; then
        printf '  ok        %-42s %s\n' "${binary}" "${reason}"
    else
        printf '  NEW       %-42s *** not in the expected list ***\n' "${binary}"
        findings=$(( findings + 1 ))
    fi
done <<< "${actual_suid}"

# Entries that were expected and are gone. Not a security problem -- it is the
# list going stale, which matters because a stale list stops being read.
while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    expected_path="${line%% *}"
    if ! printf '%s\n' "${actual_suid}" | grep -qxF "${expected_path}"; then
        printf '  gone      %-42s (expected but absent; prune this entry)\n' \
            "${expected_path}"
    fi
done <<< "${EXPECTED_SUID}"

# ============================================================================
# World-writable files in the system tree
# ============================================================================
#
# A world-writable root-owned service definition is a privilege escalation
# waiting for somewhere writable to live. This found every KotinosOS unit
# shipping as 0777, because COPY preserved the mode from a Windows drvfs mount
# that reports 0777 for everything (27 Jul 2026).
#
# /usr being read-only on bootc is what kept it harmless, which is the point:
# the safety came from the filesystem, not from the files being correct.

section "world-writable files in /usr and /etc"

ww="$(find /usr /etc -xdev -type f -perm /o+w 2>/dev/null | head -20)"
if [[ -z "${ww}" ]]; then
    echo "  none"
else
    while IFS= read -r f; do
        [[ -z "${f}" ]] && continue
        printf '  WORLD-WRITABLE  %s\n' "$(ls -l "${f}" 2>/dev/null)"
        findings=$(( findings + 1 ))
    done <<< "${ww}"
fi

# ============================================================================
# Listening sockets
# ============================================================================

section "listening sockets"

if [[ "${in_container}" == yes ]]; then
    skip_in_container "no services are started in a container, so nothing listens"
elif ! command -v ss >/dev/null 2>&1; then
    echo "  ss not available -- cannot audit listening sockets"
    findings=$(( findings + 1 ))
else
    # Numeric output only: resolving names here would turn an audit into a
    # series of DNS lookups, and a hostname is not what we are checking.
    # Columns from `ss -tulpnH` are:
    #   Netid  State  Recv-Q  Send-Q  Local:Port  Peer:Port  Process
    # so four fields are skipped before the local address. Getting this off by
    # one reads Send-Q as the address, which then matches nothing in the
    # expected list and reports every socket as a new finding -- noisy in a way
    # that looks like a real problem.
    while read -r proto _ _ _ local_addr _ process; do
        [[ "${proto}" == "Netid" ]] && continue
        [[ -z "${local_addr}" ]] && continue

        addr="${local_addr%:*}"
        addr="${addr#[}"; addr="${addr%]}"
        addr="${addr#\*}"
        # Strip a %interface scope suffix. systemd-resolved's stub listener
        # reports as 127.0.0.53%lo, which is loopback -- without this it failed
        # to match 127.0.0.53 and was reported as listening on a non-loopback
        # address, which is the opposite of what it does.
        addr="${addr%\%*}"

        port="${local_addr##*:}"

        reason="$(printf '%s\n' "${EXPECTED_LISTEN}" | awk -v a="${addr}" \
            '$1 == a { $1 = ""; sub(/^ +/, ""); print; found = 1 } END { exit !found }')"

        # A port may be justified even on a non-loopback address, but only by
        # being named explicitly in the list above.
        if [[ -z "${reason}" ]]; then
            reason="$(printf '%s\n' "${EXPECTED_LISTEN_PORTS}" | awk -v p="${port}" \
                '$1 == p { $1 = ""; sub(/^ +/, ""); print; found = 1 } END { exit !found }')"
        fi

        if [[ -n "${reason}" ]]; then
            printf '  ok        %-28s %-28s %s\n' "${local_addr}" "${process}" "${reason}"
        elif [[ "${process}" == *sshd* ]]; then
            printf '  DEV-ONLY  %-28s %-28s sshd: must not be in a release image\n' \
                "${local_addr}" "${process}"
        else
            printf '  NEW       %-28s %-28s *** listening on a non-loopback address ***\n' \
                "${local_addr}" "${process}"
            findings=$(( findings + 1 ))
        fi
    done < <(ss -tulpnH 2>/dev/null)
fi

# ============================================================================
# Firewall state
# ============================================================================

section "firewall"

if [[ "${in_container}" == yes ]]; then
    skip_in_container "firewalld needs PID 1 systemd; the zone files were already checked at build time"
elif command -v firewall-cmd >/dev/null 2>&1; then
    zone="$(firewall-cmd --get-default-zone 2>/dev/null)"
    printf '  default zone: %s\n' "${zone:-unknown}"
    printf '  services in zone: %s\n' \
        "$(firewall-cmd --zone="${zone}" --list-services 2>/dev/null)"

    if firewall-cmd --zone="${zone}" --query-service=ssh >/dev/null 2>&1; then
        printf '  note: ssh IS in the default zone -- correct for a dev image, wrong for release\n'
    else
        printf '  ok: ssh is not in the default zone\n'
    fi

    if ! systemctl is-active --quiet firewalld; then
        printf '  *** firewalld is not running -- the zone config above is inert ***\n'
        findings=$(( findings + 1 ))
    fi
else
    echo "  firewall-cmd not available"
    findings=$(( findings + 1 ))
fi

# ============================================================================
# SELinux
# ============================================================================

section "SELinux"

report_permissive_domains() {
    # "Enforcing" is a global answer to a per-domain question, and the gap is
    # wide enough to matter: Fedora ships around thirty BUILTIN PERMISSIVE
    # domains, and two of them -- sshd_session_t and sshd_auth_t -- are what
    # handle SSH authentication. Inside a permissive domain the policy still
    # evaluates the access, still logs the denial, and then allows it anyway.
    #
    # This is reported on every run rather than written down once, because a
    # caveat recorded in a document is a caveat nobody re-reads, and "SELinux is
    # enforcing" then quietly becomes a claim the system does not support.
    # Informational, not a finding: these are upstream defaults, not something
    # this image did, and failing the audit over them would train the reader to
    # ignore it.
    command -v semanage >/dev/null 2>&1 || return 0

    local perms
    perms="$(semanage permissive -l 2>/dev/null | grep -E '^[a-z_]+_t$' | sort)"
    [[ -z "${perms}" ]] && return 0

    printf '\n  permissive domains: %s total (upstream defaults)\n' \
        "$(printf '%s\n' "${perms}" | grep -c .)"

    # The ones worth a second look: anything that authenticates, faces the
    # network, or guards a privilege boundary.
    local notable
    notable="$(printf '%s\n' "${perms}" | grep -E 'ssh|polkit|logind|firewall|snapper|flatpak|passwd|sudo' || true)"
    if [[ -n "${notable}" ]]; then
        printf '  NOT CONFINED despite Enforcing, and security-relevant:\n'
        while IFS= read -r d; do
            [[ -n "${d}" ]] && printf '      %s\n' "${d}"
        done <<< "${notable}"
        printf '  Reviewing these is carried forward to M5; see TODO.md.\n'
    fi
}

if [[ "${in_container}" == yes ]]; then
    skip_in_container "a container does not carry the host's SELinux policy, so this always reads Disabled"
    printf '  The build asserts SELINUX=enforcing in /etc/selinux/config, and the\n'
    printf '  boot health check asserts it again on the running system.\n'
elif command -v getenforce >/dev/null 2>&1; then
    mode="$(getenforce)"
    printf '  mode: %s\n' "${mode}"
    if [[ "${mode}" != "Enforcing" ]]; then
        printf '  *** not enforcing -- a whole layer of the model is absent ***\n'
        findings=$(( findings + 1 ))
    fi
    report_permissive_domains
else
    echo "  getenforce not available"
    findings=$(( findings + 1 ))
fi

# ============================================================================

echo
echo "======================================================================"
if (( findings == 0 )); then
    echo "No unexpected attack surface."
    echo
    echo "This means the surface matches the expected lists in this file -- not"
    echo "that the surface is small enough. The lists are a record of decisions,"
    echo "and they are only worth what the reasoning in them is worth."
    exit 0
fi

printf '%d finding(s) above need a decision: remove the surface, or add it to\n' "${findings}"
echo "the expected list in this file WITH a reason. Adding it without a reason"
echo "turns this audit back into a rubber stamp."
exit 1
