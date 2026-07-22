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

COPY system-scripts/kotinos-firstboot.sh /usr/libexec/kotinos-firstboot
COPY systemd-units/kotinos-firstboot.service /usr/lib/systemd/system/kotinos-firstboot.service

RUN chmod 0755 /usr/libexec/kotinos-firstboot && \
    install -d /usr/lib/kotinos && \
    printf 'KOTINOS_USER=%s\nKOTINOS_GROUPS=wheel\nKOTINOS_SHELL=/bin/bash\n' "${DEFAULT_USER}" \
      > /usr/lib/kotinos/firstboot.conf && \
    systemctl enable kotinos-firstboot.service

# Safety net (M2).
#
# snapper snapshots /var, which is where all user data lives. This is the layer
# bootc deliberately does not cover: bootc rollback restores the OS and leaves
# /var untouched, so without this a destructive command is unrecoverable.
# rsync is what the recovery script uses to restore files; greenboot detects an
# unhealthy boot and drives automatic rollback at the bootloader.
RUN dnf install -y snapper rsync greenboot greenboot-default-health-checks && \
    dnf clean all

COPY system-scripts/kotinos-snapshots.sh /usr/libexec/kotinos-snapshots
COPY systemd-units/kotinos-snapshots.service /usr/lib/systemd/system/kotinos-snapshots.service
COPY system-scripts/kotinos-escalate.sh /usr/libexec/kotinos-escalate
COPY system-scripts/kotinos-recover.sh /usr/libexec/kotinos-recover
COPY system-scripts/kotinos-go-back.sh /usr/libexec/kotinos-go-back
COPY system-scripts/kotinos-cleanup.sh /usr/libexec/kotinos-cleanup
COPY system-scripts/kotinos-whats-changed.sh /usr/libexec/kotinos-whats-changed
COPY system-scripts/kotinos-space.sh /usr/libexec/kotinos-space
COPY system-scripts/kotinos-vault.sh /usr/libexec/kotinos-vault
COPY systemd-units/kotinos-vault.service /usr/lib/systemd/system/kotinos-vault.service
COPY systemd-units/kotinos-vault.timer /usr/lib/systemd/system/kotinos-vault.timer
COPY desktop-config/vault.conf /etc/kotinos/vault.conf
COPY systemd-units/kotinos-cleanup.service /usr/lib/systemd/system/kotinos-cleanup.service
COPY systemd-units/kotinos-cleanup.timer /usr/lib/systemd/system/kotinos-cleanup.timer
COPY system-scripts/kotinos-health-check.sh /usr/lib/greenboot/check/required.d/50-kotinos-health.sh

RUN chmod 0755 /usr/libexec/kotinos-snapshots \
                /usr/libexec/kotinos-escalate \
                /usr/libexec/kotinos-recover \
                /usr/libexec/kotinos-go-back \
                /usr/libexec/kotinos-cleanup \
                /usr/libexec/kotinos-whats-changed \
                /usr/libexec/kotinos-space \
                /usr/libexec/kotinos-vault \
                /usr/lib/greenboot/check/required.d/50-kotinos-health.sh && \
    ln -sf /usr/libexec/kotinos-vault /usr/bin/kotinos-vault && \
    systemctl enable kotinos-vault.timer && \
    ln -sf /usr/libexec/kotinos-whats-changed /usr/bin/kotinos-whats-changed && \
    ln -sf /usr/libexec/kotinos-space /usr/bin/kotinos-space && \
    ln -sf /usr/libexec/kotinos-cleanup /usr/bin/kotinos-cleanup && \
    systemctl enable kotinos-cleanup.timer && \
    ln -sf /usr/libexec/kotinos-recover /usr/bin/kotinos-recover && \
    ln -sf /usr/libexec/kotinos-go-back /usr/bin/kotinos-go-back && \
    systemctl enable kotinos-snapshots.service && \
    systemctl enable snapper-timeline.timer snapper-cleanup.timer && \
    systemctl enable greenboot-healthcheck.service && \
    systemctl enable bootc-fetch-apply-updates.timer

# Enablement must not be silenced. An earlier version of this file enabled a
# guessed list of greenboot units with `2>/dev/null || true`; the names were
# wrong for this greenboot release, the errors were swallowed, and the image
# shipped with health checking silently disabled. greenboot-healthcheck.service
# carries Also=greenboot-success.target greenboot-set-rollback-trigger.service,
# so enabling it pulls in the rest.
# Silent updates.
#
# The three pieces that make unattended updating safe rather than reckless
# already exist; enabling the timer is what turns them into a feature:
#   - bootc stages the update and applies it at the next reboot, so nothing is
#     ever interrupted mid-session
#   - greenboot health-checks the new deployment on that boot
#   - a failed check rolls back automatically, verified in M2
#
# So an update that breaks the machine un-breaks itself before the user notices.
# Worth knowing during development: this timer will re-apply :latest and
# therefore fights *manual* rollback testing, which is why test images disable
# it by hand.
RUN systemctl is-enabled greenboot-healthcheck.service && \
    systemctl is-enabled kotinos-snapshots.service && \
    systemctl is-enabled kotinos-firstboot.service && \
    systemctl is-enabled bootc-fetch-apply-updates.timer

# Reject UTF-8 BOMs in anything executable. Editing on Windows introduces them
# easily (PowerShell's Set-Content -Encoding utf8 writes one), and a BOM before
# the shebang makes the kernel fail to find the interpreter -- the script then
# only works when invoked as `bash script.sh`, so the breakage hides until
# something calls it directly.
#
# Syntax-check them in the same pass. These scripts run at boot, on a timer, or
# during recovery -- places where a typo surfaces as a machine that will not
# come up, long after the build that introduced it.
RUN for f in /usr/libexec/kotinos-* /usr/lib/greenboot/check/required.d/50-kotinos-health.sh; do \
      if head -c3 "$f" | od -An -tx1 | grep -q 'ef bb bf'; then \
        echo "ERROR: UTF-8 BOM in $f" >&2; exit 1; \
      fi; \
      if ! bash -n "$f"; then \
        echo "ERROR: syntax error in $f" >&2; exit 1; \
      fi; \
    done

# Hardware auto-tuning (M3): read the machine, pick settings for each component.
# pciutils provides lspci, which the profiler uses for GPU detection.
RUN dnf install -y pciutils && dnf clean all

COPY system-scripts/kotinos-hardware-tune.sh /usr/libexec/kotinos-hardware-tune
COPY systemd-units/kotinos-hardware-tune.service /usr/lib/systemd/system/kotinos-hardware-tune.service

RUN chmod 0755 /usr/libexec/kotinos-hardware-tune && \
    systemctl enable kotinos-hardware-tune.service && \
    systemctl is-enabled kotinos-hardware-tune.service

# Desktop (M3): KDE Plasma 6 on Wayland.
#
# Chosen because the AI sidebar (M6) has to dock over arbitrary windows, which
# KWin scripting supports and GNOME's extension API does not do reliably; KWin
# also has the tiling needed for "windows coexist rather than stack"; and
# Wayland gives the frame pacing that spring-physics motion (M3.5) depends on.
#
# A curated package list rather than the `kde-desktop` group, which drags in the
# whole KDE application suite. This is an appliance: every package here should be
# something the product actually uses.
RUN dnf install -y \
        plasma-desktop \
        plasma-workspace-wayland \
        sddm \
        plasma-nm \
        plasma-pa \
        kscreen \
        xdg-desktop-portal-kde \
        dolphin \
        konsole \
        pipewire \
        wireplumber \
        firefox \
    && dnf clean all

# Restricted settings surface.
#
# Enforced by Plasma's Kiosk framework rather than by hiding menu entries, so a
# blocked action stays blocked whether it is reached through System Settings, a
# shortcut, D-Bus, or a hand-edited config file. Networks, Bluetooth, display,
# personalization and privacy stay available -- that is the promised comfort
# layer. What is blocked is the set of things that can leave a machine
# unbootable, unloggable-into, or quietly insecure.
COPY desktop-config/kotinos-kiosk-restrictions /etc/xdg/kdeglobals

# Window behaviour and compositing defaults (M3.5).
#
# The important line inside is ClickRaise=false: clicking a window focuses it
# without burying its neighbours, which is what "nothing disappears when you
# click another window" actually requires.
COPY desktop-config/kwinrc /etc/xdg/kwinrc

# One motion language for the whole desktop (M3.5).
#
# A KWin script rather than settings, because the point is a *shared* set of
# durations and curves that everything reuses. See the comments in main.js for
# why these curves, and for the honest limit: this is spring-like easing, not
# spring physics. Real spring behaviour, where an interrupted animation
# continues from its current velocity, needs a C++ effect.
COPY desktop-config/kwin-motion /usr/share/kwin/scripts/kotinosmotion

# Wallpapers, generated from the brand palette rather than sourced, so they
# match exactly and can be regenerated at any resolution.
COPY branding/wallpapers /usr/share/kotinos/wallpapers

COPY system-scripts/kotinos-wallpaper.sh /usr/libexec/kotinos-wallpaper
COPY system-scripts/kotinos-focus.sh /usr/libexec/kotinos-focus
COPY system-scripts/kotinos-theme.sh /usr/libexec/kotinos-theme
COPY desktop-config/themes.conf /usr/lib/kotinos/themes.conf
COPY systemd-units/kotinos-wallpaper.service /usr/lib/systemd/user/kotinos-wallpaper.service
COPY systemd-units/kotinos-wallpaper.timer   /usr/lib/systemd/user/kotinos-wallpaper.timer

RUN chmod 0755 /usr/libexec/kotinos-wallpaper /usr/libexec/kotinos-focus /usr/libexec/kotinos-theme && \
    ln -sf /usr/libexec/kotinos-focus /usr/bin/kotinos-focus && \
    ln -sf /usr/libexec/kotinos-theme /usr/bin/kotinos-theme && \
    test -f /usr/share/kwin/scripts/kotinosmotion/contents/code/main.js && \
    test -f /usr/share/kotinos/wallpapers/kotinos-day.png && \
    systemctl --global enable kotinos-wallpaper.timer

# First-run defaults, applied once per user on first graphical login.
#
# Runs as the user rather than root: these are per-user Plasma settings, and
# writing them as root produces files the user cannot later change -- which
# looks fine until someone tries to alter their own accent colour.
COPY system-scripts/kotinos-firstrun.sh /usr/libexec/kotinos-firstrun
RUN chmod 0755 /usr/libexec/kotinos-firstrun && \
    install -d /usr/lib/kotinos /etc/xdg/autostart && \
    printf 'KOTINOS_ACCENT=#0f766e\nKOTINOS_COLOUR_SCHEME=auto\nKOTINOS_BROWSER=firefox\nKOTINOS_SEARCH=duckduckgo\n' \
      > /usr/lib/kotinos/firstrun.conf && \
    printf '[Desktop Entry]\nType=Application\nName=KotinosOS first-run setup\nExec=/usr/libexec/kotinos-firstrun\nOnlyShowIn=KDE;\nNoDisplay=true\nX-KDE-autostart-phase=1\n' \
      > /etc/xdg/autostart/kotinos-firstrun.desktop

# Boot splash (M3.5).
#
# Stock Fedora scrolls kernel messages, which is both the clearest giveaway that
# a distro is a respin and, to anyone who is not a developer, indistinguishable
# from something going wrong. This shows the wreath on a calm field instead, with
# no text at all.
# plymouth-plugin-script is required, not optional: the theme declares
# ModuleName=script, and without that plugin plymouth does not recognise the
# theme at all -- `plymouth-set-default-theme kotinos` simply fails. The
# assertion on the next step is what caught this; without it the image would
# have built clean and booted to Fedora's default splash.
RUN dnf install -y plymouth plymouth-system-theme plymouth-plugin-script && dnf clean all

COPY desktop-config/plymouth/kotinos.plymouth /usr/share/plymouth/themes/kotinos/kotinos.plymouth
COPY desktop-config/plymouth/kotinos.script   /usr/share/plymouth/themes/kotinos/kotinos.script
COPY branding/kotinos-logo.svg                /usr/share/kotinos/kotinos-logo.svg

# The splash image is rendered from the SVG at build time rather than shipping a
# second hand-maintained PNG. One source of truth: change the vector and every
# derived size follows, instead of drifting apart.
#
# Plymouth's script module draws PNGs, not SVGs, so the conversion has to happen
# somewhere -- doing it here keeps the vector authoritative.
RUN dnf install -y librsvg2-tools && \
    rsvg-convert -w 480 -h 480 /usr/share/kotinos/kotinos-logo.svg \
      -o /usr/share/plymouth/themes/kotinos/kotinos-logo.png && \
    test -s /usr/share/plymouth/themes/kotinos/kotinos-logo.png && \
    dnf remove -y librsvg2-tools && dnf clean all

RUN plymouth-set-default-theme kotinos && \
    plymouth-set-default-theme | grep -qx kotinos

# Quiet the kernel's own output so the splash is not fighting a wall of text.
# rhgb hands the console to Plymouth; quiet suppresses non-critical messages.
# Failures still surface -- this hides routine noise, not problems.
RUN echo 'GRUB_CMDLINE_LINUX_DEFAULT="rhgb quiet"' > /usr/lib/bootc/kargs.d/10-kotinos-splash.toml 2>/dev/null || \
    install -d /usr/lib/bootc/kargs.d && \
    printf 'kargs = ["rhgb", "quiet"]\n' > /usr/lib/bootc/kargs.d/10-kotinos-splash.toml

# Boot to a graphical session rather than a text console.
RUN systemctl set-default graphical.target && \
    systemctl enable sddm.service

# Assert the desktop is actually wired up. Same reasoning as the greenboot
# assertion above: a silently disabled display manager would ship a black screen.
RUN systemctl is-enabled sddm.service && \
    test "$(systemctl get-default)" = "graphical.target"

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
