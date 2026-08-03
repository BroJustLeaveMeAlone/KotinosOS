#!/usr/bin/env bash
#
# Admin mode: enrolment and second-factor verification.
#
# This is the piece that sets up the factor and can check one. Granting admin
# mode -- the escalation snapshot, the timestamped grant, the expiry -- is the
# next part of M5 and lives elsewhere; this deliberately does not open any door.
#
# WHY A RECOVERY PATH IS NOT OPTIONAL HERE
#
# An offline second factor with no way around it turns a lost phone into a
# machine nobody can administer, including the person who owns it. TOTP adds a
# second route to the same place: the codes are time-based, so a desktop whose
# RTC battery has died and which has no network to correct itself will reject
# every code its owner types, correctly and uselessly. Recovery codes are the
# answer to both, which is why they are generated during enrolment rather than
# offered as a later nicety.
#
# WHAT PROTECTS THE SECRET
#
# /etc/users.oath is a shared secret for the machine it defends: anything that
# can read it can generate valid codes forever, and the user has no way to
# notice. The image creates it 0600 root:root and labelled shadow_t rather than
# etc_t. This script preserves both on every write, because a tool that quietly
# widened them would undo the protection with nobody looking.

set -uo pipefail

OATH_FILE=/etc/users.oath
RECOVERY_FILE=/etc/kotinos/recovery-codes
STATE_DIR=/var/lib/kotinos
LOG_TAG="kotinos-admin"

# The grant lives in /run, which is tmpfs, so admin mode cannot survive a
# reboot no matter what else goes wrong. That is a property of the location
# rather than of any code remembering to clean up, which is the only kind of
# guarantee worth having here.
GRANT_DIR=/run/kotinos
GRANT_FILE="${GRANT_DIR}/admin-grant"

# How long an unlock lasts. Long enough to finish a real administrative task,
# short enough that walking away from the machine is not the same as leaving it
# rooted. Expiry is checked on every attempt rather than scheduled, so there is
# no timer to miss and nothing to push out to processes already running.
GRANT_SECONDS=900

# 4 groups of 4 base32 characters: ~80 bits, enough that guessing is not a
# strategy, short enough that a person can copy it onto paper without errors.
RECOVERY_COUNT=10
TOTP_WINDOW=2          # accept codes this many 30s steps either side

log() { echo "${LOG_TAG}: $*" >&2; }

usage() {
    cat <<'EOF'
Usage: kotinos-admin <command>

  enroll [user]     set up the second factor, and print recovery codes once
  verify <code>     check a code (a 6-digit one from the app, or a recovery code)
  unlock [user]     open admin mode: asks for a code, takes a safety snapshot
  lock              close admin mode now, without waiting for it to expire
  check [user]      exit 0 if admin mode is open for that user; silent
  status [user]     enrolment, recovery codes remaining, and time left

Admin mode ends by itself. `check` is what sudo and polkit consult, so it is
quiet and fast, and refuses whenever it cannot prove the grant is good.
EOF
}

need_root() {
    [[ ${EUID} -eq 0 ]] || { log "must run as root"; exit 1; }
}

# Every write goes through this. The mode and label on these files are part of
# the security model, not housekeeping, so they are re-applied rather than
# assumed to have survived whatever wrote the file.
secure_file() {
    local f="$1"
    chown root:root "${f}" 2>/dev/null
    chmod 0600 "${f}" 2>/dev/null
    command -v restorecon >/dev/null 2>&1 && restorecon -F "${f}" 2>/dev/null
    return 0
}

target_user() {
    local u="${1:-}"
    if [[ -z "${u}" ]]; then
        u="${SUDO_USER:-$(logname 2>/dev/null || echo "")}"
    fi
    [[ -n "${u}" ]] || { log "cannot tell which user to act on; pass one"; return 1; }
    getent passwd "${u}" >/dev/null 2>&1 || { log "no such user: ${u}"; return 1; }
    printf '%s' "${u}"
}

# --- enrolment --------------------------------------------------------------

random_hex() { head -c 20 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

random_recovery_code() {
    # Base32 alphabet without the characters people mistype between.
    local chars=ABCDEFGHJKLMNPQRSTUVWXYZ23456789 out="" i c
    for (( i = 0; i < 16; i++ )); do
        c=$(( RANDOM % ${#chars} ))
        out+="${chars:${c}:1}"
        (( (i + 1) % 4 == 0 && i < 15 )) && out+="-"
    done
    printf '%s' "${out}"
}

hash_code() {
    # Salted, so that reading the file does not hand over working codes. The
    # salt is per-file and stored beside them; it defeats precomputation, not a
    # reader who already has root -- and a reader with root does not need these.
    local code="$1" salt="$2"
    printf '%s%s' "${salt}" "${code}" | sha256sum | cut -d' ' -f1
}

do_enroll() {
    need_root
    local user; user="$(target_user "${1:-}")" || exit 1

    if grep -qE "^[A-Z0-9/]+[[:space:]]+${user}[[:space:]]" "${OATH_FILE}" 2>/dev/null; then
        log "${user} is already enrolled; re-enrolling replaces the old factor"
    fi

    local secret; secret="$(random_hex)"

    # users.oath format: <type> <user> <pin> <hex secret>
    # HOTP/T30/6 selects time-based, 30-second steps, 6 digits -- what every
    # authenticator app expects by default.
    local tmp; tmp="$(mktemp)"
    if [[ -r "${OATH_FILE}" ]]; then
        grep -vE "^[A-Z0-9/]+[[:space:]]+${user}[[:space:]]" "${OATH_FILE}" > "${tmp}" 2>/dev/null
    fi
    printf 'HOTP/T30/6 %s - %s\n' "${user}" "${secret}" >> "${tmp}"
    cat "${tmp}" > "${OATH_FILE}"
    rm -f "${tmp}"
    secure_file "${OATH_FILE}"

    # Recovery codes.
    install -d -m 0700 "$(dirname "${RECOVERY_FILE}")"
    local salt; salt="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    local codes=() code
    local rtmp; rtmp="$(mktemp)"
    if [[ -r "${RECOVERY_FILE}" ]]; then
        grep -v "^${user}:" "${RECOVERY_FILE}" > "${rtmp}" 2>/dev/null
    fi
    for (( i = 0; i < RECOVERY_COUNT; i++ )); do
        code="$(random_recovery_code)"
        codes+=("${code}")
        printf '%s:%s:%s\n' "${user}" "${salt}" "$(hash_code "${code}" "${salt}")" >> "${rtmp}"
    done
    cat "${rtmp}" > "${RECOVERY_FILE}"
    rm -f "${rtmp}"
    secure_file "${RECOVERY_FILE}"

    # The secret, in the form a phone app can take.
    local b32=""
    if command -v oathtool >/dev/null 2>&1; then
        b32="$(oathtool --verbose --totp "${secret}" 2>/dev/null | awk '/^Base32 secret/ {print $NF}')"
    fi

    cat <<EOF

Admin mode second factor set up for ${user}.

  1. Add this to an authenticator app on your phone:

     Secret:  ${b32:-${secret}}
     Type:    time-based, 6 digits, 30 seconds
     Label:   KotinosOS (${user})

  2. Write these recovery codes down and keep them away from this machine.
     They are shown once and cannot be shown again.

EOF
    printf '     %s\n' "${codes[@]}"
    cat <<'EOF'

     Each works once. They exist for the day the phone is lost -- and for the
     day this machine's clock is wrong, when every code the app produces will
     be rejected and these will still work.

EOF
    install -d -m 0755 "${STATE_DIR}"
    printf 'enrolled=%s\nuser=%s\n' "$(date -u +%FT%TZ)" "${user}" \
        > "${STATE_DIR}/.admin-enrolled"
}

# --- verification -----------------------------------------------------------

verify_totp() {
    local user="$1" code="$2" secret
    secret="$(awk -v u="${user}" '$2 == u {print $4; exit}' "${OATH_FILE}" 2>/dev/null)"
    [[ -n "${secret}" ]] || return 1
    command -v oathtool >/dev/null 2>&1 || return 1
    # --window accepts a few steps either side, which covers ordinary clock
    # drift without opening the door to replay across minutes.
    oathtool --totp --window="${TOTP_WINDOW}" "${secret}" 2>/dev/null \
        | grep -qxF "${code}"
}

verify_recovery() {
    local user="$1" code="$2"
    [[ -r "${RECOVERY_FILE}" ]] || return 1
    local norm; norm="$(printf '%s' "${code}" | tr '[:lower:]' '[:upper:]')"
    local salt line hash
    while IFS=: read -r luser lsalt lhash; do
        [[ "${luser}" == "${user}" ]] || continue
        salt="${lsalt}"
        if [[ "$(hash_code "${norm}" "${salt}")" == "${lhash}" ]]; then
            # Consumed: a recovery code that still works after being used is a
            # password written on the wall.
            local tmp; tmp="$(mktemp)"
            grep -v "^${luser}:${lsalt}:${lhash}$" "${RECOVERY_FILE}" > "${tmp}" 2>/dev/null
            cat "${tmp}" > "${RECOVERY_FILE}"
            rm -f "${tmp}"
            secure_file "${RECOVERY_FILE}"
            return 0
        fi
    done < "${RECOVERY_FILE}"
    return 1
}

do_verify() {
    need_root
    local code="${1:-}"
    [[ -n "${code}" ]] || { log "no code given"; exit 2; }
    local user; user="$(target_user "${2:-}")" || exit 1

    if verify_totp "${user}" "${code}"; then
        echo "ok: valid code"
        exit 0
    fi
    if verify_recovery "${user}" "${code}"; then
        echo "ok: valid recovery code (now used up)"
        exit 0
    fi
    # One message for both failures on purpose: saying which kind of code was
    # wrong tells an attacker which kind to keep trying.
    log "not a valid code"
    exit 1
}

# --- the grant ---------------------------------------------------------------
#
# Admin mode is a timestamped grant consulted on every escalation attempt, not
# a credential handed to a process. That distinction is the whole design, and it
# exists because group membership cannot express a mode: supplementary groups
# are fixed when a process's credentials are established, so adding the user to
# wheel at unlock never reaches shells already running, and -- the part that
# matters -- removing them at relock never revokes shells already running. A
# terminal open at unlock time would keep root indefinitely while the machine
# reported itself locked. Verified on a booted machine, both directions.
#
# Checking a timestamp instead means expiry needs nothing pushed anywhere.

write_grant() {
    local user="$1" now expiry
    now="$(date +%s)"
    expiry=$(( now + GRANT_SECONDS ))
    install -d -m 0700 "${GRANT_DIR}"
    printf 'user=%s\ngranted=%s\nexpires=%s\n' "${user}" "${now}" "${expiry}" \
        > "${GRANT_FILE}"
    chown root:root "${GRANT_FILE}"
    chmod 0600 "${GRANT_FILE}"
    command -v restorecon >/dev/null 2>&1 && restorecon -F "${GRANT_FILE}" 2>/dev/null
    printf '%s' "${expiry}"
}

# Exit 0 only for a grant that exists, names this user, and has not expired.
# Every other case -- missing file, wrong user, unreadable, malformed, past its
# expiry -- is a refusal. A gate that cannot read its own state must not treat
# that as permission.
grant_valid() {
    local user="$1"
    [[ -r "${GRANT_FILE}" ]] || return 1
    local guser gexp now
    guser="$(sed -n 's/^user=//p' "${GRANT_FILE}" 2>/dev/null)"
    gexp="$(sed -n 's/^expires=//p' "${GRANT_FILE}" 2>/dev/null)"
    [[ -n "${guser}" && -n "${gexp}" ]] || return 1
    [[ "${gexp}" =~ ^[0-9]+$ ]] || return 1
    [[ "${guser}" == "${user}" ]] || return 1
    now="$(date +%s)"
    (( now < gexp )) || return 1
    return 0
}

grant_remaining() {
    local gexp now
    gexp="$(sed -n 's/^expires=//p' "${GRANT_FILE}" 2>/dev/null)"
    [[ "${gexp}" =~ ^[0-9]+$ ]] || { printf '0'; return; }
    now="$(date +%s)"
    (( now < gexp )) && printf '%s' $(( gexp - now )) || printf '0'
}

# The call PAM and polkit make. Silent, fast, and exits non-zero unless admin
# mode is genuinely open for this user.
do_check() {
    local user; user="$(target_user "${1:-}")" || exit 1
    grant_valid "${user}" && exit 0
    exit 1
}

do_unlock() {
    need_root
    local user; user="$(target_user "${1:-}")" || exit 1

    grep -qE "^[A-Z0-9/]+[[:space:]]+${user}[[:space:]]" "${OATH_FILE}" 2>/dev/null || {
        log "${user} has no second factor enrolled; run: kotinos-admin enroll"
        exit 1
    }

    local code="${2:-}"
    if [[ -z "${code}" ]]; then
        read -r -p "Code from your authenticator (or a recovery code): " code
    fi
    [[ -n "${code}" ]] || { log "no code given"; exit 1; }

    if ! verify_totp "${user}" "${code}" && ! verify_recovery "${user}" "${code}"; then
        log "not a valid code"
        exit 1
    fi

    # The safety capture, and the reason it blocks. kotinos-escalate pins the
    # current deployment and snapshots /var, and exits non-zero if either fails.
    # M2 wrote it and nothing has ever called it; this is the caller its header
    # has been asking for. A failure here means the door does not open: the
    # entire justification for admin mode being survivable is that there is a
    # known-good point to return to, and granting it without one would be
    # granting the risk without the mitigation.
    if [[ -x /usr/libexec/kotinos-escalate ]]; then
        if ! /usr/libexec/kotinos-escalate "admin mode unlock by ${user}"; then
            log "safety capture failed -- refusing to open admin mode"
            log "nothing was granted; the machine is unchanged"
            exit 1
        fi
    else
        log "kotinos-escalate is missing -- refusing to open admin mode"
        exit 1
    fi

    local expiry; expiry="$(write_grant "${user}")"
    logger -t kotinos-admin "admin mode granted to ${user} until $(date -d "@${expiry}" '+%H:%M:%S')" 2>/dev/null
    echo "Admin mode is open for ${user} until $(date -d "@${expiry}" '+%H:%M')."
    echo "It ends by itself. To end it now: kotinos-admin lock"
}

do_lock() {
    need_root
    rm -f "${GRANT_FILE}"
    logger -t kotinos-admin "admin mode closed" 2>/dev/null
    echo "Admin mode is closed."
}

do_status() {
    local user; user="$(target_user "${1:-}")" || exit 1
    local enrolled=no remaining=0
    grep -qE "^[A-Z0-9/]+[[:space:]]+${user}[[:space:]]" "${OATH_FILE}" 2>/dev/null && enrolled=yes
    [[ -r "${RECOVERY_FILE}" ]] && remaining="$(grep -c "^${user}:" "${RECOVERY_FILE}" 2>/dev/null)"

    echo "Admin mode for ${user}"
    echo "  Enrolled        ${enrolled}"
    echo "  Recovery codes  ${remaining} unused"
    if grant_valid "${user}"; then
        local left; left="$(grant_remaining)"
        printf '  Admin mode      OPEN, %d minutes %d seconds left\n' \
            $(( left / 60 )) $(( left % 60 ))
    else
        echo "  Admin mode      closed"
    fi
    if [[ "${enrolled}" == yes ]] && (( remaining == 0 )); then
        echo
        echo "  No recovery codes left. If the phone is lost or this machine's"
        echo "  clock drifts, there is no way back in. Re-enrol to get more."
    fi
}

case "${1:-}" in
    enroll)  shift; do_enroll "${1:-}" ;;
    verify)  shift; do_verify "${1:-}" "${2:-}" ;;
    unlock)  shift; do_unlock "${1:-}" "${2:-}" ;;
    lock)    shift; do_lock ;;
    check)   shift; do_check "${1:-}" ;;
    status)  shift; do_status "${1:-}" ;;
    -h|--help|"") usage ;;
    *)       log "unrecognised: $1"; usage; exit 2 ;;
esac
