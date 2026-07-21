# Base pinned to Fedora 44, the current stable release.
#
# Do not use :latest, and do not assume the highest tag number is stable --
# tag 45 is byte-identical to rawhide. Re-verify manifest digests before
# bumping to a new release.
FROM quay.io/fedora/fedora-bootc:44

# Identifies which build a running system came from. Milestone 1 proves
# rollback by booting v1, upgrading to v2, rolling back, and reading this
# file at each step to confirm which deployment is active.
ARG BUILD_ID=dev

RUN printf 'NAME="KotinosOS"\nID=kotinos\nBUILD_ID="%s"\nBASE="fedora-bootc:44"\n' "${BUILD_ID}" \
      > /usr/lib/kotinos-release

# The image builder generates /boot's mount unit with WantedBy=multi-user.target,
# so /boot mounts roughly two minutes into boot. bootc needs /boot to write
# bootloader state: run `bootc rollback` before it mounts and the rollback is
# accepted, silently does nothing, and the next boot returns to the same
# deployment. Pull the mount into local-fs.target so it happens early.
#
# The unit itself is generated at disk-image time, not here, so this installs
# the enablement symlink and an ordering drop-in that apply once it exists.
RUN install -d /usr/lib/systemd/system/local-fs.target.wants \
                /usr/lib/systemd/system/boot.mount.d && \
    printf '[Unit]\nBefore=local-fs.target\n\n[Install]\nWantedBy=local-fs.target\n' \
      > /usr/lib/systemd/system/boot.mount.d/10-early.conf

# First-boot provisioning.
#
# Accounts cannot be baked into the image: /var is its own subvolume and does
# not inherit the image's /var, so anything created at build time is discarded
# on first boot. The service below creates the account on the running machine.
ARG DEFAULT_USER=kotinos

COPY files/kotinos-firstboot.sh /usr/libexec/kotinos-firstboot
COPY files/kotinos-firstboot.service /usr/lib/systemd/system/kotinos-firstboot.service

RUN chmod 0755 /usr/libexec/kotinos-firstboot && \
    install -d /usr/lib/kotinos && \
    printf 'KOTINOS_USER=%s\nKOTINOS_GROUPS=wheel\nKOTINOS_SHELL=/bin/bash\n' "${DEFAULT_USER}" \
      > /usr/lib/kotinos/firstboot.conf && \
    systemctl enable kotinos-firstboot.service

# Optional development access. Empty in release builds.
#
# Fedora bootc places every account's home under /var (/root -> /var/roothome,
# /home -> /var/home). When /var is a separate subvolume, image-seeded keys are
# shadowed and no account can log in. This puts the key under /usr instead --
# image-managed, so it survives regardless of how /var is mounted.
# The key is installed twice, deliberately:
#   - /usr/lib/kotinos/authorized_keys is the normal path, copied into the
#     user's real home by first-boot provisioning.
#   - /usr/share/kotinos/ssh/root is a recovery path read directly by sshd from
#     /usr, so root can still get in if provisioning itself fails. Without it,
#     a bug in the provisioning script locks us out of the machine entirely.
ARG DEV_SSH_KEY=""
RUN if [ -n "${DEV_SSH_KEY}" ]; then \
      install -d -m 0755 /usr/lib/kotinos && \
      printf '%s\n' "${DEV_SSH_KEY}" > /usr/lib/kotinos/authorized_keys && \
      chmod 0644 /usr/lib/kotinos/authorized_keys && \
      install -d -m 0755 /usr/share/kotinos/ssh && \
      printf '%s\n' "${DEV_SSH_KEY}" > /usr/share/kotinos/ssh/root && \
      chmod 0644 /usr/share/kotinos/ssh/root && \
      install -d -m 0755 /etc/ssh/sshd_config.d && \
      printf 'AuthorizedKeysFile .ssh/authorized_keys /usr/share/kotinos/ssh/%%u\nPermitRootLogin prohibit-password\n' \
        > /etc/ssh/sshd_config.d/10-kotinos-dev.conf ; \
    fi

# Fails the build if the result is not a valid bootc image.
RUN bootc container lint
