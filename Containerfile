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
COPY system-scripts/kotinos-apps.sh /usr/libexec/kotinos-apps
COPY systemd-units/kotinos-vault.service /usr/lib/systemd/system/kotinos-vault.service
COPY systemd-units/kotinos-vault.timer /usr/lib/systemd/system/kotinos-vault.timer
COPY desktop-config/vault.conf /etc/kotinos/vault.conf

# Keep the vault partition unmounted.
#
# This cannot be done here. The image builder rejects a partition with no
# mountpoint, so disk-layout.toml declares /vault to satisfy the schema -- and
# osbuild then runs `systemctl enable vault.mount` while assembling the disk,
# which fails outright if the unit is already masked in this image.
#
# So sealing happens at runtime instead, via kotinos-vault-seal.service. That is
# the better place regardless: it re-asserts on every boot, so the vault gets
# re-sealed even if something unmasks or mounts it later.
COPY systemd-units/kotinos-vault-seal.service /usr/lib/systemd/system/kotinos-vault-seal.service
RUN systemctl enable kotinos-vault-seal.service && \
    systemctl is-enabled kotinos-vault-seal.service
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
                /usr/libexec/kotinos-apps \
                /usr/lib/greenboot/check/required.d/50-kotinos-health.sh && \
    ln -sf /usr/libexec/kotinos-vault /usr/bin/kotinos-vault && \
    ln -sf /usr/libexec/kotinos-apps /usr/bin/kotinos-apps && \
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

# ============================================================================
# Sandboxing & hardening (M4, pillar 5)
# ============================================================================

# The app model: Flatpak. Every graphical app runs in a bubblewrap sandbox that
# declares exactly what it may touch, so a compromised app cannot reach the rest
# of what the user owns.
#
# Flathub is added as the app source for now; a KotinosOS remote comes later.
# xdg-desktop-portal is what lets a sandboxed app request access (a file, a
# screenshot) through a broker the user confirms, rather than having it outright.
RUN dnf install -y flatpak xdg-desktop-portal xdg-desktop-portal-gtk && \
    dnf clean all

# The remote is shipped as a file under /etc, NOT added with `flatpak
# remote-add`, and the difference is the whole point.
#
# A system-wide `flatpak remote-add` writes to /var/lib/flatpak/repo/config.
# @var is its own subvolume, and bootc does not copy the image's /var into it --
# systemd-tmpfiles creates a bare skeleton instead (see disk-layout.toml). So
# remote-add would succeed in the build container, `flatpak remote-list` would
# happily confirm it, and the shipped system would boot with no app source at
# all: an assertion passing while the thing it asserts does not survive. This is
# the same trap that swallowed the image-seeded SSH keys.
#
# /etc/flatpak/remotes.d is flatpak's own supported drop-in location for
# preconfigured system remotes, and /etc lives on @ -- image-managed, and
# three-way merged by bootc on upgrade. The .flatpakrepo file carries the GPG
# key that signs everything installed from Flathub, so it is fetched from source
# and checked rather than transcribed; an unsigned or truncated file would mean
# unverified apps.
RUN install -d /etc/flatpak/remotes.d && \
    curl -fsSL -o /etc/flatpak/remotes.d/flathub.flatpakrepo \
      https://flathub.org/repo/flathub.flatpakrepo && \
    grep -q '^GPGKey=' /etc/flatpak/remotes.d/flathub.flatpakrepo && \
    grep -q '^Url=' /etc/flatpak/remotes.d/flathub.flatpakrepo

# Make the app source reachable for PER-USER installs, which is the model the
# milestone calls for. A system remote alone is not enough: an unprivileged user
# cannot install into it, and their own installation starts with no remotes at
# all, so `flatpak install` failed both ways on a booted machine until this
# existed. See the unit for the exact errors.
COPY systemd-units/kotinos-flatpak-remote.service \
     /usr/lib/systemd/user/kotinos-flatpak-remote.service
RUN systemctl --global enable kotinos-flatpak-remote.service && \
    test -L /etc/systemd/user/default.target.wants/kotinos-flatpak-remote.service


# Kernel hardening. See the file for why each line, and for the one line
# deliberately NOT set (unprivileged user namespaces, which Flatpak needs).
COPY desktop-config/hardening/90-kotinos-sysctl.conf /usr/lib/sysctl.d/90-kotinos-sysctl.conf

# Close systemd-resolved's LLMNR listener (0.0.0.0:5355, TCP and UDP), found by
# the attack-surface audit on a booted machine. See the file for why LLMNR in
# particular is worth removing rather than merely firewalling.
COPY desktop-config/hardening/90-kotinos-resolved.conf \
     /usr/lib/systemd/resolved.conf.d/90-kotinos-resolved.conf

# Firewall: default-deny inbound.
#
# An appliance should accept no unsolicited connections. Two things here matter:
#
#   - Set the default zone explicitly and remove SSH from it. fedora-bootc
#     inherits a server-flavoured default that leaves SSH open, which for a
#     desktop appliance is exactly wrong -- a release image should expose
#     nothing. The dev-access block below re-adds SSH only when a dev key is
#     baked in, so test images stay reachable while release images stay shut.
#   - firewall-offline-cmd edits the permanent config while firewalld is stopped,
#     which is the only thing that works inside a build container.
#
# SSH is removed by writing the zone definition rather than by calling
# `--remove-service`, and that is not a style preference. firewall-offline-cmd
# carries a legacy lokkit compatibility layer in which `--remove-service` is a
# lokkit option, so combining it with `--zone=` fails outright:
#
#     usage: see firewall-offline-cmd man page
#     Can't use lokkit options with other options.
#
# That call had been wrapped in `|| true`, so it failed on every build while the
# build stayed green, and SSH was never actually removed -- the firewall's whole
# claim was false and nothing said so. Editing the zone file is unambiguous, is
# reviewable in the image, and cannot half-succeed. /etc/firewalld overrides
# /usr/lib/firewalld, and the stock definition is filtered rather than retyped so
# the rest of the zone (dhcpv6-client, forwarding) is inherited, not lost.
#
# --set-default-zone stays tolerant because setting the zone to what it already
# is fails with ZONE_ALREADY_SET (exit 16), which is not an error for us -- we
# care about the end state, not who got there first. That tolerance is paid for
# by the assertions below, which are not tolerant: the build fails if the default
# zone is not public, or if SSH survives in it. Those assertions are the only
# reason this bug was found rather than shipped.
#
# WHAT A RELEASE IMAGE ACTUALLY EXPOSES, since "default-deny inbound" is easy to
# say and the audit measured something more specific. After this step a release
# zone holds dhcpv6-client and mdns. Both are kept on purpose:
#
#   - dhcpv6-client is how the machine gets an IPv6 address at all.
#   - mdns is Avahi, and it is what makes printers, network shares and cast
#     targets appear by themselves. Removing it would make the appliance quieter
#     on the network and noticeably worse at the thing an appliance is for. It
#     is the one genuinely reachable inbound service on a release image, and
#     that is a trade taken with open eyes rather than an oversight.
#
# LLMNR, the other multicast listener the audit found, was NOT kept -- see
# 90-kotinos-resolved.conf. The difference is that mdns buys the user something
# and LLMNR buys them a credential-theft vector.
RUN dnf install -y firewalld && dnf clean all && \
    { firewall-offline-cmd --set-default-zone=public || true; } && \
    install -d /etc/firewalld/zones && \
    grep -v '<service name="ssh"/>' /usr/lib/firewalld/zones/public.xml \
      > /etc/firewalld/zones/public.xml && \
    systemctl enable firewalld.service && \
    test "$(firewall-offline-cmd --get-default-zone)" = public && \
    ! grep -q '<service name="ssh"/>' /etc/firewalld/zones/public.xml && \
    ! firewall-offline-cmd --zone=public --query-service=ssh

# SELinux must be enforcing, and the build must fail if it is not. An image that
# silently shipped permissive would drop a whole layer of the security model
# with nothing to show for it -- the same "succeeds while doing nothing" trap
# this project keeps hitting. fedora-bootc ships enforcing; this asserts it.
RUN grep -q '^SELINUX=enforcing' /etc/selinux/config

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
        > /etc/ssh/sshd_config.d/10-kotinos-dev.conf && \
      firewall-offline-cmd --add-service=ssh && \
      firewall-offline-cmd --zone=public --query-service=ssh ; \
    fi

# Note the bare --add-service above, with no --zone. That is deliberate: in
# firewall-offline-cmd, --add-service and --remove-service are lokkit options
# and cannot be combined with --zone (see the firewall block above, where that
# collision was silently failing). Bare, lokkit applies them to the default zone,
# which the block above has already asserted is public -- so the query on the
# next line confirms the service landed where we think it did. Asserting here
# matters as much as asserting the removal: a dev image whose SSH re-add failed
# quietly is a test machine nobody can log into.

# Normalise file permissions, and refuse to build if anything is world-writable.
#
# COPY preserves the mode of the source file, and this repo is developed on a
# Windows drvfs mount that reports EVERY file as 0777. So every file this image
# copies in shipped as -rwxrwxrwx, root-owned: units, sysctl drop-ins, the
# Plymouth theme, the KWin script, and the desktop and vault configuration.
#
# For the files under /usr this was invisible because bootc keeps /usr
# read-only. For the ones that land in /etc it was not invisible at all, it was
# simply never looked at -- /etc IS writable, so an ordinary user could rewrite
# them. Confirmed on a booted machine (27 Jul 2026): the user appended to
# /etc/kotinos/vault.conf and /etc/xdg/kwinrc and both writes succeeded.
#
# vault.conf is the file that decides what the vault backs up. A user, or
# ransomware running as them, could quietly add an exclusion for their own
# documents and the vault would go on reporting successful backups of everything
# that no longer mattered. That is an attack on the safety net that needs no
# privilege at all, and it existed because of a filesystem quirk on the
# development machine rather than any decision anyone made.
#
# One sweep with a global assertion, rather than --chmod on each COPY, so a file
# added later cannot quietly miss it. The assertion covers all of /usr and /etc
# rather than just our own paths: if the base image ever grows a world-writable
# file, that is worth failing a build over too.
RUN find /usr/share/kotinos /usr/lib/kotinos /etc/kotinos \
         /usr/share/kwin/scripts/kotinosmotion \
         /usr/share/plymouth/themes/kotinos \
         -type d -exec chmod 0755 {} + 2>/dev/null; \
    find /usr/share/kotinos /usr/lib/kotinos /etc/kotinos \
         /usr/share/kwin/scripts/kotinosmotion \
         /usr/share/plymouth/themes/kotinos \
         -type f -exec chmod 0644 {} + 2>/dev/null; \
    chmod 0644 /usr/lib/systemd/system/kotinos-*.service \
               /usr/lib/systemd/system/kotinos-*.timer \
               /usr/lib/systemd/user/kotinos-*.service \
               /usr/lib/systemd/user/kotinos-*.timer \
               /usr/lib/sysctl.d/90-kotinos-sysctl.conf \
               /usr/lib/systemd/resolved.conf.d/90-kotinos-resolved.conf \
               /etc/xdg/kdeglobals /etc/xdg/kwinrc && \
    chmod 0755 /usr/libexec/kotinos-* && \
    ! find /usr /etc -xdev -type f -perm /o+w -print | grep -q .

# Fails the build if the result is not a valid bootc image.
RUN bootc container lint
