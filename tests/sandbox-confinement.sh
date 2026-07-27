#!/usr/bin/env bash
#
# Prove the Flatpak sandbox actually confines something.
#
# "Apps are sandboxed" is the single easiest claim in this project to believe
# and not check. Flatpak is installed, apps launch, and nothing visibly
# contradicts the claim -- which is exactly the condition under which a
# misconfiguration survives for months. So this does the one thing that
# distinguishes a sandbox from a word: it puts a canary file where an app has no
# business reading, tries to read it from inside the sandbox, and then grants
# permission and tries again.
#
# Both halves matter. A failed read on its own proves nothing -- the file might
# be missing, the path wrong, the command misspelled. It is the DIFFERENCE
# between the denied run and the granted run, with everything else identical,
# that shows the sandbox is what stopped it.
#
# Run as the ordinary user on a booted machine, with network access the first
# time (a runtime has to come down from Flathub).

set -uo pipefail

RUNTIME_ID="org.freedesktop.Platform"
CANARY_TEXT="kotinos-sandbox-canary-$$"

pass=0
fail=0

note()  { printf '\n-- %s\n' "$*"; }
good()  { printf '   OK    %s\n' "$*"; pass=$(( pass + 1 )); }
bad()   { printf '   FAIL  %s\n' "$*"; fail=$(( fail + 1 )); }
info()  { printf '         %s\n' "$*"; }

if [[ ${EUID} -eq 0 ]]; then
    echo "error: run as the ordinary user; the sandbox is about the user's apps." >&2
    exit 1
fi

echo "======================================================================"
echo "KotinosOS sandbox confinement test -- user $(id -un)"
echo "Date: $(date -u +%FT%TZ)"
echo "======================================================================"

command -v flatpak >/dev/null 2>&1 || { echo "flatpak not installed"; exit 1; }

# --- the canaries -----------------------------------------------------------
#
# ~/.ssh and Documents, because those are the two the milestone brief names, and
# because they are what a real attacker would actually want: credentials and
# the user's files.

mkdir -p "${HOME}/.ssh" "${HOME}/Documents"
printf '%s\n' "${CANARY_TEXT}" > "${HOME}/.ssh/kotinos-canary"
printf '%s\n' "${CANARY_TEXT}" > "${HOME}/Documents/kotinos-canary"
chmod 600 "${HOME}/.ssh/kotinos-canary"

cleanup() {
    rm -f "${HOME}/.ssh/kotinos-canary" "${HOME}/Documents/kotinos-canary"
}
trap cleanup EXIT

# --- get something to run inside the sandbox --------------------------------
#
# A runtime rather than an app: it is the smallest thing that gives a real
# Flatpak sandbox with a shell in it, and this test is about the sandbox, not
# about any particular program. The branch is discovered rather than hardcoded,
# because a pinned version silently stops existing and the test then "fails"
# for a reason that has nothing to do with confinement.

# --user on every flatpak call from here down. Once the per-user remote exists,
# `flathub` names two different installations and flatpak refuses to guess:
#
#     Remote 'flathub' found in multiple installations:
#        1) system   2) user
#
# so an unqualified query fails. Prefer a runtime already installed, and only
# ask the network if there is none -- re-querying Flathub on every run makes the
# test slow and couples it to whatever upstream published today.
note "finding a ${RUNTIME_ID} branch"
branch="$(flatpak list --user --runtime --columns=application,branch 2>/dev/null \
            | awk -v id="${RUNTIME_ID}" '$1 == id { print $2 }' \
            | sort -V | tail -1)"

if [[ -n "${branch}" ]]; then
    info "using the already-installed runtime"
else
    branch="$(flatpak remote-ls --user flathub --runtime --columns=application,branch 2>/dev/null \
                | awk -v id="${RUNTIME_ID}" '$1 == id { print $2 }' \
                | sort -V | tail -1)"
fi

if [[ -z "${branch}" ]]; then
    bad "could not determine a ${RUNTIME_ID} branch from flathub"
    info "without a runtime there is nothing to sandbox; check network and the remote"
    echo; echo "Test could not run. That is not a pass."
    exit 1
fi
info "using ${RUNTIME_ID}//${branch}"

REF="${RUNTIME_ID}//${branch}"

# --user throughout, because that is the app model: an ordinary user installs
# into their own home without privilege. A system-wide install is refused for
# them by polkit ("operation Deploy not allowed for user"), so a test that used
# one would be testing the administrator's experience, not the user's.
if ! flatpak info --user "${REF}" >/dev/null 2>&1; then
    note "installing ${REF} per-user (first run only; downloads a few hundred MB)"
    if ! flatpak install --user -y --noninteractive flathub "${REF}" 2>&1 | tail -3; then
        bad "could not install ${REF} into the user installation"
        info "if this says 'No remote refs found', the per-user remote is missing --"
        info "see kotinos-flatpak-remote.service"
        exit 1
    fi
fi

# --- the actual test --------------------------------------------------------
#
# Identical commands. The ONLY difference between them is the filesystem
# permission passed to flatpak run.

try_read() {
    # try_read <permission-flag> <path>
    flatpak run --user --devel "$1" --command=cat "${REF}" "$2" 2>&1
}

for target in "${HOME}/.ssh/kotinos-canary" "${HOME}/Documents/kotinos-canary"; do
    short="${target#"${HOME}"/}"

    note "reading ~/${short} from a sandbox WITHOUT filesystem permission"
    out="$(try_read --nofilesystem=home "${target}")"
    if printf '%s' "${out}" | grep -qF "${CANARY_TEXT}"; then
        bad "the sandbox READ ~/${short} -- it is not confining anything"
        info "got: $(printf '%s' "${out}" | head -1)"
    else
        good "denied, as it should be"
        info "got: $(printf '%s' "${out}" | head -1 | cut -c1-90)"
    fi

    note "reading ~/${short} from a sandbox WITH --filesystem=home"
    out="$(try_read --filesystem=home "${target}")"
    if printf '%s' "${out}" | grep -qF "${CANARY_TEXT}"; then
        good "permitted once granted -- the difference is the sandbox"
    else
        bad "could not read even WITH permission -- the test itself is broken"
        info "got: $(printf '%s' "${out}" | head -1 | cut -c1-90)"
        info "a denial that happens in both directions proves nothing about"
        info "confinement; fix this before trusting the denied result above"
    fi
done

echo
echo "======================================================================"
printf 'checks passed: %d    failed: %d\n' "${pass}" "${fail}"
echo "======================================================================"

if (( fail > 0 )); then
    echo
    echo "Record the failure as-is. A sandbox that does not confine is worth"
    echo "knowing about; a test quietly adjusted until it passes is not."
    exit 1
fi

echo
echo "The sandbox confined a real read and allowed the same read once granted."
echo "This proves confinement for the filesystem permission only. It says"
echo "nothing about the other portals an app can ask for, and nothing about"
echo "what a user might click 'allow' on."
