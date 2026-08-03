#!/usr/bin/env bash
#
# The gate PAM consults. Exit 0 lets an escalation proceed; anything else stops
# it before a password is even asked for.
#
# Invoked from /etc/pam.d/sudo as:
#
#     auth  requisite  pam_exec.so quiet /usr/libexec/kotinos-admin-gate
#
# `requisite` rather than `required` so a refusal ends the attempt immediately
# rather than collecting a password first and failing afterwards -- there is no
# reason to make someone type a password that cannot work, and prompting for one
# leaks that the account exists and is a sudoer.
#
# pam_exec puts the account being authenticated in PAM_USER. That, and not the
# process's own identity, is what the grant has to match: sudo runs this while
# still the invoking user, but the question is always "is admin mode open for
# the account asking".
#
# WHY THIS IS SAFE TO PUT IN FRONT OF SUDO
#
# The obvious objection is that a bug here locks everyone out of root forever.
# Two things prevent that. The unlock helper is reached through a NOPASSWD
# sudoers rule, and NOPASSWD makes sudo skip its PAM auth stack entirely --
# measured, not assumed -- so the one command that can open admin mode never
# consults this gate. And root's own shell does not go through sudo at all, so a
# recovery path exists from a console or a rescue boot.
#
# It fails closed. Every path that is not a proven-valid grant returns non-zero,
# including the case where kotinos-admin is missing or unreadable: a gate that
# cannot check must not be a gate that lets things through.

set -uo pipefail

ADMIN=/usr/libexec/kotinos-admin

user="${PAM_USER:-}"
[[ -n "${user}" ]] || exit 1

# root is not gated. It is already root; there is nothing for admin mode to
# grant it, and gating it would remove the recovery path that makes the rest of
# this safe to ship.
[[ "${user}" == "root" ]] && exit 0

[[ -x "${ADMIN}" ]] || exit 1

exec "${ADMIN}" check "${user}"
