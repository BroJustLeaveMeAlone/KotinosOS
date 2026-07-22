#!/usr/bin/env bash
#
# Record which apps are installed, so a restored machine can be rebuilt.
#
# WHY A LIST AND NOT THE APPS THEMSELVES
#
# On Windows you keep the installer, because there is no guarantee you can find
# that exact .exe again. Linux does not work that way: apps are fetched by ID
# from a repository, so `flatpak install org.mozilla.firefox` always works.
#
# Saving the binaries would therefore buy nothing and cost a great deal. A
# Flatpak is hundreds of megabytes once its runtime is counted, so a dozen apps
# would swamp a vault sized for documents. Worse, a saved installer goes stale:
# restoring a six-month-old build restores six months of known security holes
# along with it. The list is a few kilobytes and always installs something
# current.
#
# THE EXCEPTION
#
# Apps that did not come from a repository -- AppImages, manually downloaded
# binaries -- genuinely cannot be re-fetched. Those are worth keeping, under a
# size cap so one large file cannot crowd out the documents the vault exists
# for.
#
# The output is deliberately both readable and runnable. A list nobody can act
# on is a list nobody reads.

set -uo pipefail

STATE_DIR=/var/lib/kotinos
MANIFEST="${STATE_DIR}/installed-apps.txt"
RESTORE_SCRIPT="${STATE_DIR}/reinstall-apps.sh"

# Anything larger than this is not copied; it is listed with a note instead.
# Small enough that a stray disk image cannot displace the documents, large
# enough for a normal AppImage.
MAX_PORTABLE_MB=250

log() { echo "kotinos-apps: $*"; }

usage() {
    cat <<'EOF'
Usage: kotinos-apps [record|show|restore-script]

  record           update the record of what is installed
  show             show it, in plain English
  restore-script   print the commands that would reinstall everything
EOF
}

app_label() {
    # Turn an app id into something a person recognises.
    # org.mozilla.firefox -> Firefox
    local id="$1" name
    name="${id##*.}"
    printf '%s' "$(tr '[:lower:]' '[:upper:]' <<< "${name:0:1}")${name:1}"
}

do_record() {
    install -d -m 0755 "${STATE_DIR}"

    {
        echo "# Apps installed on this machine"
        echo "# Updated $(date -u +'%-d %B %Y, %H:%M UTC')"
        echo "#"
        echo "# This is a record, not a copy. Apps are re-downloaded when you"
        echo "# reinstall them, which also means you get current versions rather"
        echo "# than whatever was current when the backup was made."
        echo
    } > "${MANIFEST}"

    # --- Flatpak applications -----------------------------------------------
    if command -v flatpak >/dev/null 2>&1; then
        echo "Applications you installed:" >> "${MANIFEST}"
        local count=0
        while IFS=$'\t' read -r name appid origin; do
            [[ -z "${appid}" ]] && continue
            printf '  %-28s  %s\n' "${name:-$(app_label "${appid}")}" "(${appid})" >> "${MANIFEST}"
            count=$(( count + 1 ))
        done < <(flatpak list --app --columns=name,application,origin 2>/dev/null)
        (( count == 0 )) && echo "  (none yet)" >> "${MANIFEST}"
        echo >> "${MANIFEST}"
    fi

    # --- Portable apps that cannot be re-downloaded --------------------------
    # These are the ones worth actually copying, since nothing can fetch them
    # back. Listed separately so the distinction is visible to the user.
    local portable_found=0
    for home in /var/home/*; do
        [[ -d "${home}" ]] || continue
        while IFS= read -r f; do
            [[ -n "${f}" ]] || continue
            if (( portable_found == 0 )); then
                echo "Standalone apps (these are copied, as nothing can re-download them):" >> "${MANIFEST}"
                portable_found=1
            fi
            local size_mb
            size_mb=$(( $(stat -c %s "${f}" 2>/dev/null || echo 0) / 1024 / 1024 ))
            if (( size_mb > MAX_PORTABLE_MB )); then
                printf '  %-28s  %s MB — too large to copy, kept as a note only\n' \
                    "$(basename "${f}")" "${size_mb}" >> "${MANIFEST}"
            else
                printf '  %-28s  %s MB\n' "$(basename "${f}")" "${size_mb}" >> "${MANIFEST}"
            fi
        done < <(find "${home}/Applications" "${home}/.local/bin" -maxdepth 1 -type f \
                 \( -name '*.AppImage' -o -name '*.appimage' \) 2>/dev/null)
    done
    (( portable_found )) && echo >> "${MANIFEST}"

    # --- System packages added on top of the image ---------------------------
    # The image itself is restored by bootc, so only additions matter here.
    if command -v rpm >/dev/null 2>&1; then
        echo "The operating system and its built-in apps are restored automatically." >> "${MANIFEST}"
        echo "You do not need to reinstall those." >> "${MANIFEST}"
        echo >> "${MANIFEST}"
    fi

    # --- The runnable half ---------------------------------------------------
    {
        echo "#!/usr/bin/env bash"
        echo "# Reinstall the apps that were on this machine."
        echo "# Generated $(date -u +%FT%TZ) — safe to run on a fresh install."
        echo "set -u"
        echo
        if command -v flatpak >/dev/null 2>&1; then
            while IFS=$'\t' read -r appid origin; do
                [[ -z "${appid}" ]] && continue
                echo "flatpak install -y ${origin:-flathub} ${appid}"
            done < <(flatpak list --app --columns=application,origin 2>/dev/null)
        fi
    } > "${RESTORE_SCRIPT}"
    chmod 0755 "${RESTORE_SCRIPT}"

    log "recorded $(grep -c '^  ' "${MANIFEST}" 2>/dev/null || echo 0) apps"
}

case "${1:-record}" in
    record)         do_record ;;
    show)           [[ -r "${MANIFEST}" ]] && cat "${MANIFEST}" || echo "Nothing recorded yet. Run: kotinos-apps record" ;;
    restore-script) [[ -r "${RESTORE_SCRIPT}" ]] && cat "${RESTORE_SCRIPT}" || echo "Nothing recorded yet." ;;
    -h|--help)      usage ;;
    *)              echo "Unrecognised: $1"; usage; exit 2 ;;
esac
