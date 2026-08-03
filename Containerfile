# Base pinned to Fedora 44, the current stable release.
#
# Do not use :latest, and do not assume the highest tag number is stable --
# tag 45 is byte-identical to rawhide. Re-verify manifest digests before
# bumping to a new release.
FROM quay.io/fedora/fedora-bootc:44

# NOTE: the BUILD_ID stamp is written at the END of this file, not here.
# It changes on every build, and an ARG invalidates the layer cache from the
# point it is used onwards -- so writing it first meant every build with a new
# tag rebuilt all seventy-odd steps from scratch, including the several-hundred
# package desktop install. Measured: one cached step out of seventy-three.
# Writing it last lets everything above cache between builds. Nothing during the
# build reads the file; its consumers are all at runtime.

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

# Confine SSH authentication, which "SELinux is enforcing" does not cover.
#
# `getenforce` returns a single global answer to a per-domain question. Fedora's
# policy ships 41 BUILTIN PERMISSIVE types, and inside a permissive domain the
# policy still evaluates each access, still logs the denial, and then allows it
# anyway. Two of those types -- sshd_session_t and sshd_auth_t -- are the domains
# that handle SSH authentication, so on a machine reporting Enforcing, the code
# authenticating remote logins was not confined at all.
#
# M4 found this by mislabelling a user's authorized_keys and watching sshd read
# it regardless: the AVC said `permissive=1`, meaning "would have been denied".
# With this step the same test is refused, and the AVC says `permissive=0`.
#
# WHY THE MODULE IS REBUILT RATHER THAN semanage permissive -d.
# That command only removes types added with `semanage permissive -a`. Builtin
# permissive types come from `(typepermissive x)` statements compiled into the
# service's own policy module, and the removal fails with "Unable to remove
# module permissive_sshd_session_t ... No such file or directory". The only way
# to drop the statement is to install a corrected copy of the module at a higher
# priority, which is what happens below.
#
# WHY THAT DOES NOT FREEZE SSH POLICY.
# Overriding a module at priority 400 shadows the distribution's version at 100
# forever, which on a package-updated system would mean silently ignoring every
# future upstream fix to ssh policy -- worse than the problem being solved. It is
# safe HERE only because this is an image-based OS: the override is re-derived
# from whatever ssh module that build's selinux-policy shipped, on every single
# build, and images are rebuilt rather than patched in place. The freeze lasts
# exactly one image.
#
# Only these two types are touched. The other 39 were reviewed and deliberately
# left alone: 22 label software this image does not install, and most of the rest
# are systemd generators that run for milliseconds during early boot, where the
# breakage risk is a machine that will not start and the security value is close
# to nil. Verified on a booted VM that key login, scp, sftp and repeated sessions
# all work with these two enforcing, and that no new enforced denial appears.
# The checks below are positive on purpose. `! semanage permissive -l | grep -q`
# reads like an assertion and is not one: in a pipeline the `!` negates grep,
# so a semanage that is missing or broken produces empty input, grep exits 1,
# and the whole thing "passes" having verified nothing. Measured, not assumed --
# with semanage stubbed out to exit 127, that form returns 0.
#
# A `command -v semanage` guard does not fix it either, since it is satisfied by
# a semanage that exists and fails. So the step proves each stage did work:
# that there were permissive statements to remove, that none remain in the file
# written, and that semanage produced real output before its result is trusted.
# The same checks cover a future Fedora renaming the types, where both greps
# would silently match nothing and the old assertion would have passed.
#
# THE POLICY STORE IS NOT IN THE DISCARDED /var. This was worth checking, since
# almost everything else this image writes to /var is thrown away on first boot,
# and a store that did not survive would leave the machine enforcing today but
# unable to reproduce why -- the next `setsebool -P` would rebuild policy from
# Fedora's priority-100 module and silently restore both permissive statements.
#
# It does not happen, because /var/lib/selinux is a SYMLINK to /etc/selinux. The
# store therefore lives on the root subvolume with the rest of /etc and is
# carried by the image, not recreated by tmpfiles. Measured on a freshly booted
# m4d, where /var had just been created from scratch:
#
#   /var/lib/selinux -> ../../etc/selinux
#   400 ssh                  cil          <- override present in the store
#   sshd types permissive: 0 of 2
#
# and after running both of the commands that would have exposed the problem --
# `setsebool -P` and `semanage fcontext -a` -- the override was still registered
# and both domains still enforcing. tests/attack-surface.sh checks for the module
# in the store anyway: the reasoning above is now verified rather than assumed,
# but it depends on a symlink that a future Fedora could move.
RUN cd /tmp && \
    semodule -c -E ssh && \
    test "$(grep -c '(typepermissive sshd_' ssh.cil)" -gt 0 && \
    grep -v '(typepermissive sshd_session_t)' ssh.cil \
      | grep -v '(typepermissive sshd_auth_t)' > ssh-enforcing.cil && \
    test "$(grep -c '(typepermissive sshd_' ssh-enforcing.cil)" -eq 0 && \
    mv ssh-enforcing.cil ssh.cil && \
    semodule -X 400 -i ssh.cil && \
    rm -f /tmp/ssh.cil && \
    semodule -lfull > /tmp/modules.txt && \
    test -s /tmp/modules.txt && \
    grep -qE '^400[[:space:]]+ssh([[:space:]]|$)' /tmp/modules.txt && \
    rm -f /tmp/modules.txt && \
    semanage permissive -l > /tmp/permissive.txt && \
    test -s /tmp/permissive.txt && \
    ! grep -qE '^sshd_(session|auth)_t$' /tmp/permissive.txt && \
    rm -f /tmp/permissive.txt

# Drop setuid from chfn and chsh.
#
# Both are setuid root so an ordinary user can edit their own /etc/passwd fields
# -- chfn the display name, chsh the login shell. On a single-account appliance
# with a fixed shell, neither is something anybody reaches for: the display name
# belongs to the settings app, and changing the login shell is an admin-mode
# decision if it is a decision at all.
#
# They are neutralised by clearing the setuid bit rather than by removing the
# package, because `rpm -qf` puts both in **util-linux** -- the package that also
# supplies mount, umount, lsblk, findmnt and most of the tools this image depends
# on to boot. Removing it to be rid of two setuid binaries is not a trade
# anybody would take. (Not shadow-utils, which owns passwd, chage, gpasswd and
# newgrp; and not util-linux-user, which is where these live on some other
# Fedora variants. Checked on the image rather than assumed, because both of
# those were guessed wrong first.)
#
# The binaries stay and simply cannot escalate; a user running them now gets a
# permission error rather than a root-owned write to the account database.
#
# This is the smallest real reduction in attack surface available here, and the
# reason it is worth taking is that setuid binaries are where privilege
# escalation bugs live -- the value is not that these two have a known flaw, it
# is that they no longer matter if one is found.
RUN chmod u-s /usr/bin/chfn /usr/bin/chsh && \
    ! find /usr/bin/chfn /usr/bin/chsh -perm /u+s | grep -q .

# Make sudo authenticate every time (M5 groundwork).
#
# sudo caches a successful authentication for five minutes by default, and
# during that window it does not run its PAM auth stack at all. That is fine on
# a developer workstation and wrong here, because the admin-mode gate M5 is
# building lives in exactly that stack. Measured on a booted machine, logging
# every execution of the stack, with both calls in one session so the ticket
# applies:
#
#   default sudoers     second sudo succeeded WITHOUT authenticating   stack ran 1x
#   timestamp_timeout=0 second sudo refused                            stack ran 1x
#
# So without this, a user could unlock admin mode, let it relock, and still take
# root for the rest of the five minutes while the machine reported itself
# locked -- an admin mode that reports itself closed while still working. The
# hole arrives through an upstream default rather than through anything we
# wrote, which is exactly the kind that survives review.
#
# This is therefore part of the gate rather than a tuning preference, and it is
# installed now, ahead of the PAM work, so that later tests of the gate cannot
# pass for the wrong reason.
#
# The cost is honest and worth stating: every sudo asks for a password, with no
# grace period. On an appliance where the intended route to privilege is a
# deliberate admin-mode unlock rather than a string of sudo calls, that is the
# behaviour we want anyway.
#
# Mode 0440 is required -- sudo refuses to read a sudoers file with looser
# permissions and disables itself rather than guessing, so `visudo -c` is run
# here to fail the build rather than the machine.
RUN printf '# Written by the KotinosOS image. See the M5 notes in TODO.md.\n# sudo must consult its PAM stack every time: the admin-mode gate lives there.\nDefaults timestamp_timeout=0\n' \
      > /etc/sudoers.d/10-kotinos-no-timestamp && \
    chmod 0440 /etc/sudoers.d/10-kotinos-no-timestamp && \
    visudo -c -q && \
    grep -q '^Defaults timestamp_timeout=0$' /etc/sudoers.d/10-kotinos-no-timestamp && \
    test "$(stat -c %a /etc/sudoers.d/10-kotinos-no-timestamp)" = 440

# The second factor: TOTP, and the protection its secret requires.
#
# pam_oath verifies a time-based code; oathtool generates and enrols them. Both
# are offline, which is the requirement -- nothing here talks to a network.
#
# THE SECRET IS THE WEAK POINT OF THIS CHOICE, so it is handled here rather than
# left to the enrolment tool. Unlike FIDO2, where the private key never leaves
# the token, TOTP keeps a shared secret on the very machine it defends: anything
# that can read /etc/users.oath can generate valid codes forever, and the user
# has no way to notice. M4 found every file this image copied into /etc shipping
# world-writable, with an ordinary user demonstrably editing one -- so "the file
# will be fine" is exactly the assumption this project has already been wrong
# about once.
#
# Two layers, because either alone has a failure mode the other covers:
#
#   - 0600 root:root stops every unprivileged user. Created HERE rather than at
#     enrolment, so the protection exists from first boot and does not depend on
#     the enrolment tool getting it right on a machine nobody is watching.
#   - The SELinux label decides which *domain* may read it, which DAC cannot
#     express. Left alone the file would be `etc_t` -- verified, and readable by
#     a wide set of confined services. `shadow_t` is the type /etc/shadow uses,
#     which is the correct comparison: this file is a credential, not config.
#     Fedora ships no file-context rule for it, also verified, so this is ours.
#
# The empty file is harmless before enrolment: pam_oath finds no entry for the
# user and denies, which is the direction a missing credential should fail.
# The recovery codes get the same treatment. They are stored salted and hashed,
# so reading the file does not hand over working codes the way reading
# users.oath hands over the secret -- but they are still the thing that opens
# admin mode when the phone is gone, and a file worth stealing offline is worth
# labelling. Left alone it would be etc_t, verified.
RUN dnf install -y pam_oath oathtool && dnf clean all && \
    test -f /usr/lib64/security/pam_oath.so && \
    command -v oathtool >/dev/null && \
    semanage fcontext -a -t shadow_t '/etc/users\.oath' && \
    semanage fcontext -a -t shadow_t '/etc/kotinos/recovery-codes' && \
    touch /etc/users.oath && \
    chown root:root /etc/users.oath && \
    chmod 0600 /etc/users.oath && \
    test "$(matchpathcon -n /etc/users.oath | tr -d ' ')" = "system_u:object_r:shadow_t:s0" && \
    test "$(matchpathcon -n /etc/kotinos/recovery-codes | tr -d ' ')" = "system_u:object_r:shadow_t:s0" && \
    test "$(stat -c '%a %U %G' /etc/users.oath)" = "600 root root"

# Admin mode: the tool, and the gate PAM consults.
COPY system-scripts/kotinos-admin.sh /usr/libexec/kotinos-admin
COPY system-scripts/kotinos-admin-gate.sh /usr/libexec/kotinos-admin-gate
RUN chmod 0755 /usr/libexec/kotinos-admin /usr/libexec/kotinos-admin-gate && \
    ln -sf /usr/libexec/kotinos-admin /usr/bin/kotinos-admin && \
    /usr/libexec/kotinos-admin --help >/dev/null

# Put the gate in front of sudo.
#
# This is the milestone's headline claim made mechanical: a user who knows the
# password but has no unlocked admin mode gets nothing. `requisite` ends the
# attempt at the gate rather than after collecting a password that could not
# have worked.
#
# The drop-in is prepended to /etc/pam.d/sudo rather than written as a separate
# file because PAM has no include-before mechanism -- order within the stack is
# the semantics, and the gate has to run first.
#
# THE BOOTSTRAP, which is the part that needs stating. Gating sudo raises an
# obvious problem: opening admin mode needs root, and root now needs admin mode.
# It is resolved by the sudoers rule below rather than by an exception inside
# the gate, because NOPASSWD makes sudo skip its PAM auth stack altogether --
# verified on a booted machine, where a NOPASSWD command ran the stack zero
# times. So the unlock helper is reachable without a grant, and nothing else is.
#
# NOPASSWD does not mean unauthenticated. The helper demands the account's
# password (through unix_chkpwd, the same helper PAM uses) and then the second
# factor, so the two factors are both still required -- they are just checked by
# the thing that opens the door rather than by sudo on the way to it.
# `seteuid` is load-bearing, not decoration. Without it pam_exec runs the helper
# as the INVOKING user, who cannot read the 0600 root-owned grant file -- so the
# gate refused every time, including with a perfectly valid grant, and the
# failure looked like a PAM bug rather than a permissions one. With it the
# helper runs as root and can actually answer the question it was asked.
#
# Worth recording for the next person reading a failure here: sudo renders any
# failed auth module as "PAM authentication error: Unknown error -1", which
# reads like something broken. It is not. `pam_exec /bin/false` produces exactly
# the same message, because that message IS the refusal.
RUN install -d /usr/share/kotinos && \
    cp /etc/pam.d/sudo /usr/share/kotinos/sudo.pam.orig && \
    printf '# KotinosOS admin-mode gate. Must stay first: see kotinos-admin-gate.\nauth       requisite    pam_exec.so seteuid quiet /usr/libexec/kotinos-admin-gate\n' \
      > /tmp/sudo.pam.new && \
    cat /etc/pam.d/sudo >> /tmp/sudo.pam.new && \
    cat /tmp/sudo.pam.new > /etc/pam.d/sudo && \
    rm -f /tmp/sudo.pam.new && \
    head -2 /etc/pam.d/sudo | grep -q 'kotinos-admin-gate' && \
    printf '# The one command that can open admin mode, and therefore the one that\n# cannot require it. NOPASSWD makes sudo skip its PAM stack, which is what\n# lets this bypass the gate; the helper itself demands password and factor.\n%%wheel ALL=(root) NOPASSWD: /usr/libexec/kotinos-admin unlock, /usr/libexec/kotinos-admin unlock *\n' \
      > /etc/sudoers.d/20-kotinos-admin-unlock && \
    chmod 0440 /etc/sudoers.d/20-kotinos-admin-unlock && \
    visudo -c -q

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

# Identifies which build a running system came from. Milestone 1 proves
# rollback by booting v1, upgrading to v2, rolling back, and reading this
# file at each step to confirm which deployment is active.
#
# Deliberately the last thing written. See the note at the top of this file:
# BUILD_ID changes every build, and an ARG invalidates the layer cache from
# where it is used, so putting it first cost a full rebuild every single time.
ARG BUILD_ID=dev
RUN printf 'NAME="KotinosOS"\nID=kotinos\nBUILD_ID="%s"\nBASE="fedora-bootc:44"\n' "${BUILD_ID}" \
      > /usr/lib/kotinos-release && \
    grep -q "^BUILD_ID=\"${BUILD_ID}\"$" /usr/lib/kotinos-release

# Fails the build if the result is not a valid bootc image.
RUN bootc container lint
