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

    # Declared up front so the summary at the end can rely on them existing,
    # including on a machine with no flatpak and no standalone apps.
    local count=0 portable_found_total=0

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
    #
    # Apps are enumerated PER USER as well as system-wide, and that is the
    # difference between this file being useful and being empty.
    #
    # This service runs as root from the vault timer, and apps on KotinosOS
    # install per-user (M4 made that the model, because a per-user install needs
    # no privilege and cannot affect anyone else). Root's own `flatpak list`
    # sees only the system installation, so on a machine where the user had
    # installed everything they use, this recorded nothing at all -- and said
    # "(none yet)" while doing it. A record of what to reinstall that lists
    # nothing is worse than no record, because it is believed.
    #
    # FLATPAK_USER_DIR points flatpak at another account's installation without
    # needing to become that user, which keeps this a plain root service rather
    # than something that has to su into every home.
    list_user_apps() {
        local dir="$1"
        [[ -d "${dir}" ]] || return 0
        FLATPAK_USER_DIR="${dir}" flatpak list --user --app \
            --columns=name,application,origin 2>/dev/null
    }

    if command -v flatpak >/dev/null 2>&1; then
        echo "Applications you installed:" >> "${MANIFEST}"

        # Collected first so the same app installed by two users is listed once.
        local -A seen=()
        local name appid origin
        while IFS=$'\t' read -r name appid origin; do
            [[ -z "${appid}" ]] && continue
            [[ -n "${seen[${appid}]:-}" ]] && continue
            seen["${appid}"]="${origin:-flathub}"
            printf '  %-28s  %s\n' "${name:-$(app_label "${appid}")}" "(${appid})" >> "${MANIFEST}"
            count=$(( count + 1 ))
        done < <(
            flatpak list --system --app --columns=name,application,origin 2>/dev/null
            for home in /var/home/*; do
                [[ -d "${home}" ]] || continue
                list_user_apps "${home}/.local/share/flatpak"
            done
        )

        (( count == 0 )) && echo "  (none yet)" >> "${MANIFEST}"
        echo >> "${MANIFEST}"
    fi

    # --- Portable apps that cannot be re-downloaded --------------------------
    #
    # Nothing here copies anything, and the text below no longer claims it does.
    # This file used to announce "these are copied, as nothing can re-download
    # them", which was simply untrue: this script records, and the vault copies.
    # The two are not the same, and the gap mattered -- an AppImage in
    # ~/.local/bin is not in the vault's include list, so a user reading that
    # line would have believed a file was protected when it was not.
    #
    # So each one is reported with where it lives and whether that location is
    # actually protected, which is the thing the user needs to know and can act
    # on. The size cap is applied to the same judgement: a file too large for the
    # vault to carry sensibly is called out even when it sits in a protected
    # folder.
    local portable_found=0
    for home in /var/home/*; do
        [[ -d "${home}" ]] || continue
        while IFS= read -r f; do
            [[ -n "${f}" ]] || continue
            if (( portable_found == 0 )); then
                {
                    echo "Standalone apps (nothing can re-download these):"
                    echo "  Protected ones are copied by the vault. The rest are only listed"
                    echo "  here -- move them into Applications if you want them kept."
                } >> "${MANIFEST}"
                portable_found=1
            fi
            local size_mb where protected
            size_mb=$(( $(stat -c %s "${f}" 2>/dev/null || echo 0) / 1024 / 1024 ))
            where="${f#"${home}/"}"
            case "${where}" in
                Applications/*) protected="protected" ;;
                *)              protected="NOT protected -- outside the vault's list" ;;
            esac
            if (( size_mb > MAX_PORTABLE_MB )); then
                protected="too large for the vault at ${size_mb} MB"
            fi
            printf '  %-28s  %5s MB  %s\n' \
                "${f##*/}" "${size_mb}" "${protected}" >> "${MANIFEST}"
            portable_found_total=$(( portable_found_total + 1 ))
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
        if command -v flatpak >/dev/null 2>&1 && (( count > 0 )); then
            # --user, to match the app model. Apps install per-user on KotinosOS:
            # a system-wide install needs an authorisation an ordinary user does
            # not have, so a restore script generated without --user would stop
            # on the first line with "Deploy not allowed for user" -- on a fresh
            # machine, which is exactly when someone is least equipped to debug
            # it.
            #
            # Written from the same list gathered above, so it cannot drift from
            # what the manifest claims is installed.
            echo "flatpak remote-add --user --if-not-exists \\"
            echo "    flathub /etc/flatpak/remotes.d/flathub.flatpakrepo 2>/dev/null"
            echo
            for appid in "${!seen[@]}"; do
                echo "flatpak install --user -y ${seen[${appid}]} ${appid}"
            done | sort
        fi
    } > "${RESTORE_SCRIPT}"
    chmod 0755 "${RESTORE_SCRIPT}"

    # Counted from the tallies kept above rather than by grepping the manifest
    # for indented lines, which also matched "(none yet)" and the explanatory
    # text -- so a machine with no apps at all reported "recorded 1 apps".
    log "recorded ${count} apps and ${portable_found_total} standalone files"
}

case "${1:-record}" in
    record)         do_record ;;
    show)           [[ -r "${MANIFEST}" ]] && cat "${MANIFEST}" || echo "Nothing recorded yet. Run: kotinos-apps record" ;;
    restore-script) [[ -r "${RESTORE_SCRIPT}" ]] && cat "${RESTORE_SCRIPT}" || echo "Nothing recorded yet." ;;
    -h|--help)      usage ;;
    *)              echo "Unrecognised: $1"; usage; exit 2 ;;
esac
