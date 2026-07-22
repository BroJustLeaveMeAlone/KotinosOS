#!/usr/bin/env bash
#
# "What changed?" -- explains the last update in plain language.
#
# Updates apply silently in the background, which is the right default: nothing
# should interrupt someone mid-task. But silent must not mean secret. A machine
# that changes itself without ever being able to say what it changed is one the
# user cannot reason about, and that quietly erodes trust in the whole
# auto-update arrangement.
#
# Compares the running deployment against the previous one, so it answers the
# question actually being asked -- "what is different since the last reboot" --
# rather than reciting a changelog.

set -uo pipefail

DEPLOY_ROOT=/ostree/deploy/default/deploy
RPM_DBPATH=usr/lib/sysimage/rpm

usage() {
    cat <<'EOF'
Usage: kotinos-whats-changed [--packages]

  (no arguments)   summary of the last update
  --packages       full list of package changes

Compares the system you are running now against the one you were running
before it.
EOF
}

show_packages=0
case "${1:-}" in
    "")            ;;
    --packages)    show_packages=1 ;;
    -h|--help)     usage; exit 0 ;;
    *)             echo "Unrecognised: $1"; usage; exit 2 ;;
esac

command -v ostree >/dev/null 2>&1 || { echo "ostree unavailable"; exit 1; }

# Resolve deployment trees by modification time: newest is what we are running,
# the one before it is what it replaced.
mapfile -t trees < <(find "${DEPLOY_ROOT}" -maxdepth 1 -mindepth 1 -type d -printf '%T@ %p\n' 2>/dev/null \
                     | sort -rn | awk '{print $2}')

if [[ ${#trees[@]} -lt 2 ]]; then
    echo "Nothing to compare — this machine has only ever run one version."
    echo "That is normal on a new install."
    exit 0
fi

new_tree="${trees[0]}"
old_tree="${trees[1]}"

read_build_id() {
    local rel="$1/usr/lib/kotinos-release"
    [[ -r "${rel}" ]] && sed -n 's/^BUILD_ID="\(.*\)"/\1/p' "${rel}"
}

new_build="$(read_build_id "${new_tree}")"
old_build="$(read_build_id "${old_tree}")"

echo "You are now running build ${new_build:-unknown}."
echo "Before this, you were running ${old_build:-unknown}."
echo

if [[ ! -d "${new_tree}/${RPM_DBPATH}" || ! -d "${old_tree}/${RPM_DBPATH}" ]]; then
    echo "Package details are unavailable for these deployments."
    exit 0
fi

new_pkgs="$(mktemp)"; old_pkgs="$(mktemp)"
trap 'rm -f "${new_pkgs}" "${old_pkgs}"' EXIT

rpm -qa --dbpath="${new_tree}/${RPM_DBPATH}" --qf '%{NAME} %{VERSION}-%{RELEASE}\n' 2>/dev/null | sort > "${new_pkgs}"
rpm -qa --dbpath="${old_tree}/${RPM_DBPATH}" --qf '%{NAME} %{VERSION}-%{RELEASE}\n' 2>/dev/null | sort > "${old_pkgs}"

added="$(comm -13 <(cut -d' ' -f1 "${old_pkgs}") <(cut -d' ' -f1 "${new_pkgs}"))"
removed="$(comm -23 <(cut -d' ' -f1 "${old_pkgs}") <(cut -d' ' -f1 "${new_pkgs}"))"
upgraded="$(comm -13 "${old_pkgs}" "${new_pkgs}" | cut -d' ' -f1 | grep -Fxv -f <(echo "${added}") 2>/dev/null || true)"

count() { [[ -z "$1" ]] && echo 0 || echo "$1" | grep -c .; }

n_added="$(count "${added}")"
n_removed="$(count "${removed}")"
n_upgraded="$(count "${upgraded}")"

if (( n_added + n_removed + n_upgraded == 0 )); then
    echo "No software changed. The update was to the system image itself."
    exit 0
fi

echo "${n_upgraded} programs updated, ${n_added} added, ${n_removed} removed."

# Call out the things a person would actually care about, rather than making
# them read a list of 400 libraries.
notable="kernel|mesa|firefox|plasma|kwin|systemd|bootc|snapper|greenboot"
notable_changes="$(echo "${upgraded}" | grep -iE "^(${notable})" || true)"
if [[ -n "${notable_changes}" ]]; then
    echo
    echo "Worth knowing about:"
    while read -r pkg; do
        [[ -z "${pkg}" ]] && continue
        old_v="$(awk -v p="${pkg}" '$1==p {print $2}' "${old_pkgs}")"
        new_v="$(awk -v p="${pkg}" '$1==p {print $2}' "${new_pkgs}")"
        case "${pkg}" in
            kernel*)    echo "  • The Linux kernel was updated (${old_v} → ${new_v})" ;;
            mesa*)      echo "  • Graphics drivers were updated" ;;
            firefox*)   echo "  • Firefox was updated (${old_v} → ${new_v})" ;;
            plasma*|kwin*) echo "  • The desktop was updated" ;;
            systemd*)   echo "  • Core system services were updated" ;;
            *)          echo "  • ${pkg} (${old_v} → ${new_v})" ;;
        esac
    done <<< "${notable_changes}" | sort -u
fi

echo
echo "If something is wrong since this update, you can undo it:"
echo "    bootc rollback        — go back to the previous system"
echo "    kotinos-go-back       — restore your files to an earlier point"

if (( show_packages )); then
    echo
    echo "--- everything that changed ---"
    [[ -n "${added}" ]]    && { echo "Added:";    echo "${added}"    | sed 's/^/  + /'; }
    [[ -n "${removed}" ]]  && { echo "Removed:";  echo "${removed}"  | sed 's/^/  - /'; }
    [[ -n "${upgraded}" ]] && { echo "Updated:";  echo "${upgraded}" | sed 's/^/  ~ /'; }
fi
