#!/usr/bin/env bash
#
# greenboot health check.
#
# greenboot runs this after boot. A non-zero exit marks the boot unhealthy;
# after the configured number of failures the bootloader rolls back to the
# previous deployment automatically.
#
# The checks below are the things an `rm -rf /*` actually destroyed, so they
# detect the real failure mode rather than a hypothetical one. They are
# deliberately cheap and conservative: a false "unhealthy" triggers a rollback,
# which is far more disruptive than a false "healthy".

set -uo pipefail

fail=0
check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "OK   ${desc}"
    else
        echo "FAIL ${desc}"
        fail=1
    fi
}

echo "KotinosOS health check"

# Account database. Destroyed by rm -rf /*, and without it nothing can log in.
check "/etc/passwd present and non-empty" test -s /etc/passwd
check "/etc/shadow present"               test -e /etc/shadow

# The user-data volume must be the real subvolume, not the directory underneath.
check "/var is a mount point"             mountpoint -q /var

# The safety net itself. If snapshots are gone there is nothing to recover from,
# which is worth failing a boot over.
check "snapshot tree present"             test -d /var/.snapshots

# Provisioning completed. Its absence means first boot never finished.
check "provisioning stamp present"        test -e /var/lib/kotinos/.provisioned

# The provisioned user must still have a home with content in it.
#
# Checking `test -d /var/home` is NOT sufficient and was a real bug here:
# systemd-tmpfiles recreates /var/home as an empty directory on every boot, so
# that check passed on a system whose every user file had just been deleted.
# Verify the actual account's home instead, which is what "usable" means.
provisioned_user=""
if [[ -r /var/lib/kotinos/.provisioned ]]; then
    provisioned_user="$(sed -n 's/^user=//p' /var/lib/kotinos/.provisioned)"
fi

if [[ -n "${provisioned_user}" ]]; then
    check "account ${provisioned_user} exists"      getent passwd "${provisioned_user}"
    check "home for ${provisioned_user} present"    test -d "/var/home/${provisioned_user}"
    check "home for ${provisioned_user} not empty"  bash -c "[[ -n \$(ls -A '/var/home/${provisioned_user}' 2>/dev/null) ]]"
else
    echo "FAIL could not determine provisioned user"
    fail=1
fi

if [[ ${fail} -ne 0 ]]; then
    echo "UNHEALTHY: one or more checks failed"
    exit 1
fi

echo "HEALTHY"
exit 0
