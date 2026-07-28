#!/usr/bin/env bash
#
# The vault: a protected copy of the things you cannot replace.
#
# WHY THIS EXISTS SEPARATELY FROM SNAPSHOTS
#
# Snapshots are excellent against deletion, bad updates and app corruption, and
# `rm -rf /*` cannot touch them. But they live in the same filesystem as the
# data they protect, so `snapper delete` or `btrfs subvolume delete` erases them
# instantly -- and ransomware running with your privileges can do exactly that.
#
# The vault is the tier underneath. It is a separate filesystem that is
# NORMALLY NOT MOUNTED. You cannot write to, encrypt, or delete a filesystem
# that is not attached to the running system. This service mounts it, writes,
# and unmounts, so the window in which it is reachable at all is measured in
# seconds per day.
#
# WHAT IT PROTECTS AGAINST
#   - deleting your own files, and then deleting the snapshots too
#   - ransomware or a compromised app running as you
#   - a botched admin-mode session that wipes /var
#
# WHAT IT DOES NOT PROTECT AGAINST -- stated plainly rather than implied
#   - the disk dying. It is the same physical device.
#   - theft or fire.
#   - a determined attacker with sustained admin access.
# Real disaster recovery needs a second location. The optional external mirror
# below is the first step toward that.
#
# WHAT GOES IN
#
# Small and irreplaceable, not large and reproducible. Documents and configs are
# megabytes; media libraries and caches are gigabytes and can be re-obtained.
# Auto-detecting "most used" was considered and rejected: a heuristic that
# guesses wrong loses something irreplaceable, and the user does not find out
# until the day they need it. Predictable beats clever for a safety net.

set -uo pipefail

VAULT_DEV_LABEL="kotinos-vault"
VAULT_MOUNT=/run/kotinos-vault
CONFIG=/etc/kotinos/vault.conf
STATE_DIR=/var/lib/kotinos
VAULT_LOG="${STATE_DIR}/vault.log"

log() {
    printf '%s  %s\n' "$(date -u +%FT%TZ)" "$*" >> "${VAULT_LOG}" 2>/dev/null
    echo "kotinos-vault: $*"
}

usage() {
    cat <<'EOF'
Usage: kotinos-vault [backup|list|restore <path>|status|config]

  backup            protect the current state of your important files
  list              show what is protected, and from when
  status            show vault size, last backup, and whether it is healthy
  restore <path>    bring a file or folder back out of the vault
  config            show the settings actually in effect, after reading
                    /etc/kotinos/vault.conf -- including anything in that file
                    that was rejected, and what was used instead

The vault is a separate protected area that stays disconnected from the running
system except for the moment it is being written to.
EOF
}

# Defaults. Overridable in /etc/kotinos/vault.conf, which admin mode can edit.
INCLUDE_DIRS=("Documents" "Pictures" "Desktop" ".config" ".var/app" ".local/share/keyrings" ".ssh" ".gnupg" ".mozilla" ".thunderbird" "Applications")
EXCLUDE_GLOBS=("*.iso" "*.qcow2" "*.vmdk" "*.img" "node_modules" ".cache" "Trash")
KEEP_VERSIONS=5
MIRROR_EXTERNAL=no
VAULT_ENABLED=yes

# --- configuration ----------------------------------------------------------
#
# The config is PARSED, not sourced. It used to be `. "${CONFIG}"`, which is
# shorter and wrong for a file like this one:
#
#   - a single typo -- an unbalanced quote, a stray bracket -- makes the whole
#     backup abort with a shell syntax error rather than back up with one
#     setting ignored. The failure mode of a config mistake should never be
#     "no backups", especially when nobody is watching this run.
#   - sourcing executes. Anything that can write this file gets to run commands
#     as root, which turns a file-permission mistake into privilege escalation.
#     M4 found exactly that: this file shipped world-writable, so every local
#     user had root through it.
#
# The parser below reads key=value only. Unknown keys are reported and skipped,
# malformed values fall back to the default, and nothing in the file is ever
# executed.
#
# Lists use a repeated key (INCLUDE=..., one per line) rather than a shell
# array. It reads better for a human editing it by hand, it is far easier for
# the settings app to rewrite, and it removes the quoting rules that made the
# old array form easy to break. The legacy array syntax is still understood so
# that a machine carrying an edited config from an older image keeps working.
config_warn() { log "WARNING: ${CONFIG}: $*"; }

# Pull the entries out of a legacy INCLUDE_DIRS=("a" "b") line without eval.
# Values are path fragments and globs, so splitting on whitespace is safe; a
# path containing spaces is the one case this cannot carry over, and it says so
# rather than silently dropping it.
parse_legacy_array() {
    local raw="$1" item
    raw="${raw#*\(}"; raw="${raw%\)*}"
    for item in ${raw}; do
        item="${item%\"}"; item="${item#\"}"
        item="${item%\'}"; item="${item#\'}"
        [[ -n "${item}" ]] && printf '%s\n' "${item}"
    done
}

read_config() {
    [[ -r "${CONFIG}" ]] || return 0

    local includes=() excludes=()
    local line key value

    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Strip comments only where a '#' starts the line or follows a space,
        # so a value that legitimately contains one survives.
        line="${line%%[[:space:]]#*}"
        [[ "${line}" == \#* ]] && continue
        # Trim surrounding whitespace.
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "${line}" ]] && continue

        if [[ "${line}" != *=* ]]; then
            config_warn "ignoring line without a setting: ${line}"
            continue
        fi

        key="${line%%=*}"
        value="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        # Strip one layer of matching quotes from scalar values.
        [[ "${value}" == \"*\" ]] && value="${value:1:-1}"
        [[ "${value}" == \'*\' ]] && value="${value:1:-1}"

        case "${key}" in
            INCLUDE)        [[ -n "${value}" ]] && includes+=("${value}") ;;
            EXCLUDE)        [[ -n "${value}" ]] && excludes+=("${value}") ;;
            INCLUDE_DIRS)   mapfile -t -O "${#includes[@]}" includes < <(parse_legacy_array "${value}") ;;
            EXCLUDE_GLOBS)  mapfile -t -O "${#excludes[@]}" excludes < <(parse_legacy_array "${value}") ;;
            KEEP_VERSIONS)
                if [[ "${value}" =~ ^[0-9]+$ ]] && (( value >= 1 )); then
                    KEEP_VERSIONS="${value}"
                else
                    config_warn "KEEP_VERSIONS must be a whole number of at least 1, not '${value}'; keeping ${KEEP_VERSIONS}"
                fi ;;
            VAULT_ENABLED|MIRROR_EXTERNAL)
                if [[ "${value}" == "yes" || "${value}" == "no" ]]; then
                    printf -v "${key}" '%s' "${value}"
                else
                    config_warn "${key} must be yes or no, not '${value}'; keeping ${!key}"
                fi ;;
            *)              config_warn "ignoring unknown setting '${key}'" ;;
        esac
    done < "${CONFIG}"

    # An empty include list would back up nothing at all while reporting
    # success, so it is treated as a broken config rather than an instruction.
    # Turning the vault off is what VAULT_ENABLED=no is for, and it says so.
    if (( ${#includes[@]} )); then
        INCLUDE_DIRS=("${includes[@]}")
    elif grep -qE '^[[:space:]]*(INCLUDE|INCLUDE_DIRS)=' "${CONFIG}" 2>/dev/null; then
        config_warn "no usable INCLUDE entries; falling back to the built-in list"
    fi
    (( ${#excludes[@]} )) && EXCLUDE_GLOBS=("${excludes[@]}")
}

read_config

# Honour the off switch everywhere except the two read-only questions, so
# someone who has turned the vault off can still ask what state it is in and
# what settings it would use. Refusing to answer those would make a disabled
# vault indistinguishable from a broken one.
case "${1:-status}" in
    status|config|-h|--help) ;;
    *)
        if [[ "${VAULT_ENABLED}" != "yes" ]]; then
            log "vault is disabled in ${CONFIG}; doing nothing"
            exit 0
        fi ;;
esac

vault_device() {
    blkid -L "${VAULT_DEV_LABEL}" 2>/dev/null
}

# --- mount / unmount --------------------------------------------------------
#
# Everything that touches the vault goes through these, and the unmount is in a
# trap, so an error or a crash mid-backup still leaves it disconnected rather
# than sitting mounted and writable until the next reboot.

vault_mount() {
    local dev
    dev="$(vault_device)" || true
    [[ -n "${dev}" ]] || { log "no vault device found (label ${VAULT_DEV_LABEL})"; return 1; }

    install -d -m 0700 "${VAULT_MOUNT}"
    if mountpoint -q "${VAULT_MOUNT}"; then
        return 0
    fi
    if mount -o noatime "${dev}" "${VAULT_MOUNT}" 2>/dev/null; then
        return 0
    fi
    log "could not mount vault"
    return 1
}

vault_unmount() {
    mountpoint -q "${VAULT_MOUNT}" && umount "${VAULT_MOUNT}" 2>/dev/null
    return 0
}

# --- backup -----------------------------------------------------------------

do_backup() {
    vault_mount || return 1
    trap vault_unmount EXIT

    local stamp
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"

    # Refresh the record of installed apps first, so the copy taken below
    # includes an up-to-date one. Restoring documents without knowing which
    # apps opened them is half a restore.
    [[ -x /usr/libexec/kotinos-apps ]] && /usr/libexec/kotinos-apps record >/dev/null 2>&1

    local rsync_excludes=()
    for glob in "${EXCLUDE_GLOBS[@]}"; do
        rsync_excludes+=(--exclude "${glob}")
    done

    local copied=0 failed=0
    for home in /var/home/*; do
        [[ -d "${home}" ]] || continue
        local user dest previous
        user="${home##*/}"
        dest="${VAULT_MOUNT}/${user}/${stamp}"
        previous="$(find "${VAULT_MOUNT}/${user}" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | tail -1)"

        install -d -m 0700 "${dest}"

        for rel in "${INCLUDE_DIRS[@]}"; do
            [[ -e "${home}/${rel}" ]] || continue
            install -d -m 0700 "$(dirname "${dest}/${rel}")"

            # --link-dest hard-links against the previous backup, so an
            # unchanged file costs one directory entry rather than a second
            # copy. That is what makes keeping several versions of everything
            # affordable in a tenth of the disk.
            local linkdest=()
            [[ -n "${previous}" && -d "${previous}/${rel}" ]] && linkdest=(--link-dest="${previous}/${rel}")

            # No --delete: every run writes a fresh timestamped directory, so
            # there has never been anything in it to delete. Keeping the flag
            # implied a mirroring behaviour this does not have.
            #
            # rsync's exit status is CHECKED, and its stderr is kept. Both used
            # to be discarded, with success recorded unconditionally afterwards
            # -- so a full disk, an unreadable file or a vanishing source all
            # ended with "backup complete" in the log. A backup that cannot say
            # whether it worked is not a backup, and this is the one service
            # where nobody is watching the output.
            local err
            if err="$(rsync -aHAX "${rsync_excludes[@]}" "${linkdest[@]}" \
                            "${home}/${rel}/" "${dest}/${rel}/" 2>&1 >/dev/null)"; then
                copied=$(( copied + 1 ))
            else
                failed=$(( failed + 1 ))
                log "ERROR: failed to protect ${user}/${rel}: $(printf '%s' "${err}" | head -1)"
            fi
        done

        # Prune oldest versions beyond the keep count.
        local versions
        mapfile -t versions < <(find "${VAULT_MOUNT}/${user}" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
        local excess=$(( ${#versions[@]} - KEEP_VERSIONS ))
        for (( i=0; i<excess; i++ )); do
            rm -rf "${versions[$i]}"
            log "pruned old vault copy $(basename "${versions[$i]}") for ${user}"
        done
    done

    # The app record belongs in the vault too, not only in /var -- if /var is
    # gone, so is any knowledge of what was installed.
    if [[ -r /var/lib/kotinos/installed-apps.txt ]]; then
        install -d -m 0700 "${VAULT_MOUNT}/_system/${stamp}"
        cp -a /var/lib/kotinos/installed-apps.txt /var/lib/kotinos/reinstall-apps.sh \
              "${VAULT_MOUNT}/_system/${stamp}/" 2>/dev/null
    fi

    # .last-backup is what `status` reports and what a user would trust, so it
    # is only stamped when something was actually protected AND nothing failed.
    # A partial backup is worth knowing about; recording it as the last good one
    # is how a half-empty vault gets mistaken for a full one.
    local result=0
    if (( failed )); then
        log "ERROR: backup INCOMPLETE (${stamp}): ${copied} copied, ${failed} failed"
        log "  the vault does NOT hold a full copy of this session; see the errors above"
        result=1
    elif (( copied )); then
        printf '%s' "${stamp}" > "${VAULT_MOUNT}/.last-backup"
        log "backup complete (${stamp}): ${copied} protected"
    else
        log "nothing to back up"
    fi

    check_vault_space

    # Mirror to an external disk if one is present. Optional by design: it adds
    # the protection the same-disk vault cannot offer, for users who plug
    # something in, without making everyone else buy hardware.
    #
    # Skipped when the local backup failed: copying a known-incomplete vault
    # over the external one would spread the damage to the only copy that
    # survives the disk dying.
    if (( result == 0 )); then
        mirror_external
    else
        [[ "${MIRROR_EXTERNAL}" == "yes" ]] && \
            log "skipping external mirror because this backup was incomplete"
    fi

    vault_unmount
    trap - EXIT
    return "${result}"
}

# Warn before the vault is full, and say what to do about it.
#
# The vault is sized at roughly a tenth of the disk, which for documents and
# configs is generous -- on a 512 GB machine that is 50 GB of text files and
# settings. So running out almost never means "the vault is too small"; it
# nearly always means a large folder ended up in INCLUDE_DIRS, or too many
# versions are being kept.
#
# Both of those are reversible in seconds. Resizing the partition is not, and
# needs install media with everything unmounted. Suggesting the reversible fixes
# first is not a cop-out -- it is the correct order of operations.
check_vault_space() {
    local pcent
    pcent="$(df --output=pcent "${VAULT_MOUNT}" 2>/dev/null | tail -1 | tr -dc '0-9')"
    [[ -n "${pcent}" ]] || return 0

    if (( pcent >= 90 )); then
        log "WARNING: vault is ${pcent}% full"
        log "  The usual cause is a large folder in INCLUDE_DIRS, or too many versions kept."
        log "  Both are in /etc/kotinos/vault.conf and take effect on the next backup:"
        log "    - lower KEEP_VERSIONS (currently ${KEEP_VERSIONS})"
        log "    - remove large or reproducible folders from INCLUDE_DIRS"
        log "  Largest items currently protected:"
        du -sh "${VAULT_MOUNT}"/*/*/* 2>/dev/null | sort -rh | head -5 | sed 's/^/    /' >> "${VAULT_LOG}" 2>/dev/null
    elif (( pcent >= 75 )); then
        log "vault is ${pcent}% full"
    fi
}

mirror_external() {
    # Off unless the user asked for it at first boot or in admin mode. The
    # same-disk vault cannot survive the drive failing; this is the only part
    # that can, which is why it is worth asking about rather than assuming.
    [[ "${MIRROR_EXTERNAL}" == "yes" ]] || return 0

    local target
    target="$(blkid -L kotinos-vault-external 2>/dev/null)" || return 0
    [[ -n "${target}" ]] || { log "external mirroring is on, but no external vault disk is connected"; return 0; }

    local mnt=/run/kotinos-vault-external
    install -d -m 0700 "${mnt}"
    mount -o noatime "${target}" "${mnt}" 2>/dev/null || return 0

    rsync -aHAX --delete "${VAULT_MOUNT}/" "${mnt}/" 2>/dev/null \
        && log "mirrored vault to external disk"

    umount "${mnt}" 2>/dev/null
}

# --- read-only operations ---------------------------------------------------

do_list() {
    vault_mount || return 1
    trap vault_unmount EXIT

    if [[ ! -d "${VAULT_MOUNT}" ]] || [[ -z "$(ls -A "${VAULT_MOUNT}" 2>/dev/null)" ]]; then
        echo "The vault is empty. Nothing has been protected yet."
        vault_unmount; trap - EXIT; return 0
    fi

    for userdir in "${VAULT_MOUNT}"/*; do
        [[ -d "${userdir}" ]] || continue
        local base
        base="$(basename "${userdir}")"
        # lost+found is an ext4 artefact, not a person; _system holds the app
        # record rather than anyone's files.
        [[ "${base}" == "lost+found" ]] && continue
        if [[ "${base}" == "_system" ]]; then
            echo "Record of installed apps:"
        else
            echo "Protected copies for ${base}:"
        fi
        find "${userdir}" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r | while read -r v; do
            local when size
            when="$(date -d "${v:0:8} ${v:9:2}:${v:11:2}" '+%-d %B %Y, %H:%M' 2>/dev/null || echo "${v}")"
            size="$(du -sh "${userdir}/${v}" 2>/dev/null | cut -f1)"
            printf '  %-28s %s\n' "${when}" "${size}"
        done
    done

    vault_unmount
    trap - EXIT
}

do_status() {
    local dev
    dev="$(vault_device)" || true
    if [[ -z "${dev}" ]]; then
        echo "No vault is set up on this machine."
        return 1
    fi

    vault_mount || return 1
    trap vault_unmount EXIT

    local used avail last
    read -r used avail <<< "$(df --output=used,avail -h "${VAULT_MOUNT}" 2>/dev/null | tail -1)"
    last="$(cat "${VAULT_MOUNT}/.last-backup" 2>/dev/null)"

    echo "Vault"
    echo "  Device        ${dev}"
    echo "  Used          ${used:-unknown}"
    echo "  Free          ${avail:-unknown}"
    if [[ -n "${last}" ]]; then
        echo "  Last backup   $(date -d "${last:0:8} ${last:9:2}:${last:11:2}" '+%-d %B %Y, %H:%M' 2>/dev/null || echo "${last}")"
    else
        echo "  Last backup   never"
    fi
    echo "  Mounted only while being written to; disconnected the rest of the time."

    vault_unmount
    trap - EXIT
}

do_restore() {
    local what="$1"
    [[ -n "${what}" ]] || { echo "Say what to restore."; return 2; }

    vault_mount || return 1
    trap vault_unmount EXIT

    local user latest src
    user="${SUDO_USER:-$(logname 2>/dev/null || echo "")}"
    [[ -n "${user}" ]] || { echo "Cannot tell which user to restore for."; vault_unmount; return 1; }

    latest="$(find "${VAULT_MOUNT}/${user}" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | tail -1)"
    [[ -n "${latest}" ]] || { echo "Nothing protected for ${user} yet."; vault_unmount; return 1; }

    src="${latest}/${what#/}"
    [[ -e "${src}" ]] || { echo "'${what}' is not in the vault."; vault_unmount; return 1; }

    echo "Restoring '${what}' from $(basename "${latest}")."
    rsync -aHAX "${src}" "/var/home/${user}/$(dirname "${what#/}")/" 2>/dev/null \
        && echo "Done." || echo "Restore failed."

    vault_unmount
    trap - EXIT
}

# Report the settings that are actually in force, rather than the ones the file
# appears to contain. Those differ whenever a value was rejected, and the whole
# reason the config is parsed rather than sourced is so that a bad line is
# survivable -- which is only an improvement if there is a way to see it
# happened. Any warnings are emitted by read_config above, before this prints.
do_config() {
    echo "Vault settings in effect"
    echo "  Config file     ${CONFIG}$([[ -r "${CONFIG}" ]] || echo ' (absent; using built-in defaults)')"
    echo "  Enabled         ${VAULT_ENABLED}"
    echo "  Keep versions   ${KEEP_VERSIONS}"
    echo "  External mirror ${MIRROR_EXTERNAL}"
    echo "  Protecting      ${#INCLUDE_DIRS[@]} locations:"
    printf '                    %s\n' "${INCLUDE_DIRS[@]}"
    echo "  Never copying   ${#EXCLUDE_GLOBS[@]} patterns:"
    printf '                    %s\n' "${EXCLUDE_GLOBS[@]}"
}

case "${1:-status}" in
    backup)  do_backup ;;
    list)    do_list ;;
    status)  do_status ;;
    config)  do_config ;;
    restore) shift; do_restore "${1:-}" ;;
    -h|--help) usage ;;
    *)       echo "Unrecognised: $1"; usage; exit 2 ;;
esac
