# KotinosOS — Task Tracker

## How this works

Before starting a milestone, break it into concrete steps in this file. Check
them off as they complete. Steps discovered mid-flight get added rather than
quietly absorbed, so the record shows what the work actually took.

The **vision and the milestone list do not change** — those live in
[`PLAN.md`](./PLAN.md). Only the steps inside a milestone change as reality
teaches us things.

Legend: `[x]` done · `[ ]` open · `[~]` in progress

---

## Roadmap status

| | Milestone | Status |
|---|---|---|
| **M1** | Foundation — bootable image, subvolumes, rollback proven | ✅ **Complete** (21 Jul 2026) |
| **M1.5** | First-boot provisioning — create accounts in the live `/var` | ✅ **Complete** (21 Jul 2026) |
| **M2** | Safety net — snapper, escalation hook, recovery environment | ✅ **Complete** (21 Jul 2026) |
| M3 | Desktop & appliance UX — shell, settings, first-run, hardware | ✅ **Core complete** (22 Jul 2026) — wizard outstanding |
| M3.5 | Identity & comfort — look, motion, personalization, friction removal | 🚧 **In progress** — splash, windows, comfort features done |
| M4 | Sandboxing & hardening | ✅ **Complete** (27 Jul 2026) — all four exit criteria met on a clean image; 22/22 adversarial boundaries hold. Eight defects found and fixed, two of which let an unprivileged user attack the safety net |
| M5 | Admin mode & offline 2FA | 🚧 **Core complete** (4 Aug 2026) — both paths to root gated behind password + TOTP + a deliberate unlock, verified on a clean image; a correct password alone gets nothing. UI and the during-session audit trail outstanding |
| M6 | AI assistant (+ M6b semantic file layer) | ⬜ Not started |
| M7 | Distribution infrastructure | ⬜ Not started |
| M8 | Hardware QA & v1.0 | ⬜ Not started |

---

## Project setup ✅

- [x] Name chosen: **KotinosOS** (olive wreath of the ancient Olympic Games)
- [x] Logo added (`branding/kotinos-logo.png`) and shown in README
- [x] Repository live at `BroJustLeaveMeAlone/KotinosOS`
- [x] README written (vision, architecture, build steps, roadmap)
- [x] LF line endings enforced (`.gitattributes`) — CRLF would break shebangs and unit files inside the image
- [x] **BOM guard in `Containerfile`** — a UTF-8 BOM before a shebang stops the kernel finding the interpreter, and the script still works under `bash script.sh`, so the breakage hides. Editing on Windows introduces BOMs easily; the build now fails on one
- [x] **Secure Boot verified working** (22 Jul 2026) — booted a Gen2 VM with Secure Boot **on** and the `MicrosoftUEFICertificateAuthority` template. Confirmed from inside the guest: `mokutil --sb-state` → *SecureBoot enabled*, EFI variable set, `dmesg` → *"Kernel is locked down from EFI Secure Boot mode"*, Fedora's signed `shimx64.efi` in place, our image healthy. **We inherit Fedora's Microsoft-signed boot chain and sign nothing ourselves.** Users will never be told to disable Secure Boot
- [x] **Directories renamed to say what they hold.** `files/` → `system-scripts/` + `systemd-units/`, `assets/` → `branding/`, `output/` → `build-output/`, `config.toml` → `disk-layout.toml`, `config.dev.toml` → `dev-credentials.toml`. Same rule for anything added later: no `src/`, `lib/`, `utils/`
- [x] **Logo: transparent-background PNG** (`branding/kotinos-logo-transparent.png`) — white background removed with a luminance ramp so leaf edges stay smooth, then cropped to the artwork. No more white box on dark themes
- [ ] Logo: **SVG version** — needed for the boot splash, favicon, and installer, where the mark must scale to any size. The PNG cannot do that job

---

## Milestone 1 — Foundation ✅ COMPLETE

**Goal:** a custom Fedora bootc image boots in Hyper-V with Btrfs subvolumes,
and the full `v1 → upgrade → v2 → rollback → v1` cycle works with user data
surviving every transition.

### Planned steps

- [x] **Step 0 — Toolchain.** WSL2 Ubuntu 26.04, podman 5.7.0 rootful, Hyper-V enabled, repo + GitHub remote
- [x] **Step 1 — Risk spike.** Proved Btrfs subvolumes are creatable at build time. Key discovery: only `customizations.disk` supports subvolumes; `customizations.filesystem` silently limits you to `/` and `/boot`. Validated cheaply with the builder's `manifest` subcommand (parses config without building)
- [x] **Step 2 — Repo skeleton.** `Containerfile`, `config.toml`, `build.sh`, `.gitignore`, `.gitattributes`
- [x] **Step 3 — Minimal image.** Pinned `fedora-bootc:44`. Digest comparison showed tag `45` is byte-identical to `rawhide` — picking the highest number would have silently shipped on a development branch
- [x] **Step 4 — Disk image.** `vhd` output, converted to dynamic VHDX (21 GB sparse → 2.1 GB actual)
- [x] **Step 5 — Boot.** Gen2 UEFI VM, Secure Boot off, boots and reaches sshd
- [x] **Step 6 — Prove rollback.** Full cycle verified with a sentinel file (see results below)

### Unplanned steps that emerged

- [x] **Dev access strategy.** Gitignored `dev-credentials.toml` overlay merged at build time, so no password hash ever lands in git history
- [x] **Credentials persisted** to `.dev-secrets/` (gitignored) — they were only in a session-scoped temp dir
- [x] **Local OCI registry.** `registry:2` in WSL, bridged to the guest via `netsh portproxy` on the NAT gateway. Required because `bootc upgrade` can't resolve a `localhost/` ref inside the VM. *(This is early M7 groundwork.)*
- [x] **Fix: dropped `@home`** after finding it mounted nowhere and its mount unit failing
- [x] **Fix: dev SSH key moved under `/usr`** (`DEV_SSH_KEY` build arg) after `/var`-based keys proved unreachable
- [x] **Fix: `/boot` early-mount drop-in** after discovering rollback silently did nothing

### Result

| Stage | Booted | Digest | Sentinel in `/var` |
|---|---|---|---|
| v1 initial | `BUILD_ID=v1` | `c44709f0…` | written |
| after `bootc upgrade` | `BUILD_ID=v2` | `a79e87c5…` | survived |
| after `bootc rollback` | `BUILD_ID=v1` | `c44709f0…` | survived |

`/var` stayed on `subvol=@var` throughout. The two-layer safety net is real:
**the OS rolled back while user data persisted.**

### What this changed for later milestones

1. **There is no `/home`.** `/home` → `/var/home`, `/root` → `/var/roothome`. All user data lives under `/var`, so `@var` is the volume snapper must cover in M2.
2. **A separate `/var` subvolume does not inherit the image's `/var`.** systemd-tmpfiles creates a bare skeleton; image-baked homes and keys are silently discarded. **Users must be provisioned at first boot** — this is a new prerequisite for M2.
3. **`/boot` must mount early or rollback silently fails.** `bootc rollback` reports success, changes nothing, and the next boot returns to the same deployment. Also: ostree does *not* rewrite `/boot/loader/entries` on rollback (it swaps the `/ostree/boot.N` symlinks), so unchanged timestamps are not evidence of failure — check `ostree admin status`.

---

## Milestone 1.5 — First-boot provisioning ✅ COMPLETE

**In plain words:** make the machine create your user account the first time it
boots.

**Why this exists.** M1 finding #2: when `/var` is its own subvolume, bootc does
not copy the image's `/var` into it — systemd-tmpfiles lays down a bare
skeleton instead. Every account's home lives under `/var` (`/home` →
`/var/home`, `/root` → `/var/roothome`), so **any user baked into the image is
silently discarded at first boot.** This locked us out of our own VM twice.
Provisioning therefore has to happen on the running machine, not at build time.

**Why it blocks M2.** Snapper, the escalation hook, and admin mode all assume a
real user account exists and that its data lives somewhere snapshottable.
Building those on a system that can't reliably create a user means testing the
safety net against nothing.

**Exit criteria:** boot a fresh image and land with a working account whose home
is on `@var`, created at first boot, that survives an upgrade and a rollback.

### Steps

- [x] **Mechanism chosen: systemd oneshot unit.** Preferred over cloud-init (heavy, cloud-oriented) and `systemd-firstboot` (handles locale/hostname, not real user accounts). Gated by a stamp file in `/var` rather than `ConditionFirstBoot`, because the stamp lives on the same volume as the thing it guards — if `/var` is ever reset, provisioning correctly runs again
- [x] Provisioning unit + script shipped under `/usr` (`system-scripts/` + `systemd-units/`), image-managed so it cannot be shadowed
- [x] Account created at first boot: user, `wheel`, home at `/var/home/<user>`, shell
- [x] SSH keys installed into the real runtime home as the primary path; `/usr` debug path kept as recovery
- [x] Idempotent — `RequiresMountsFor=/var`, stamp at `/var/lib/kotinos/.provisioned`, never clobbers an existing home
- [x] SELinux contexts correct — `restorecon` yields `ssh_home_t` on `.ssh` and `authorized_keys`
- [x] Verified on a clean VM: account exists, home populated, key login works
- [x] Verified across `bootc upgrade` **and** `bootc rollback`
- [ ] *(deferred to M3)* How the real product asks for username/password — belongs with the first-run experience

### Result

| Stage | `BUILD_ID` | Account | User data | Provisioning re-ran? |
|---|---|---|---|---|
| first boot | v3 | created (uid 1001, `wheel`) | — | ran once |
| after reboot | v3 | intact | intact | no (`ConditionResult=no`) |
| after `bootc upgrade` | v4 | intact | intact | no |
| after `bootc rollback` | v3 | intact | intact | no |

Login as the provisioned user via SSH key confirmed working after rollback.

**Design notes.** The password is *locked*, not empty — an empty password would
permit passwordless console login; locked denies password auth entirely until
M3 collects a real one. The dev key is installed in two places on purpose: the
normal path (copied into the user's home at first boot) and a recovery path read
straight from `/usr` by sshd, so a bug in provisioning is debuggable instead of
locking us out of the machine — which happened twice during M1.

---

## Installing on real machines — notes for M7

**Vault sizing lives here — it cannot live in the image.** A disk image is a
fixed-size artifact with no knowledge of the target drive, so "10% of the disk"
is meaningless at build time; the image ships a fixed 8 GiB vault floor. The
installer, which sees the real disk, computes the actual size:
`min(cap, max(8 GiB, 10% of disk))`. This is also the only correct place to
*change* vault size later, since repartitioning needs everything unmounted,
which install media already provides — and the installer implements partitioning
regardless, so both sizing and resizing are marginal work rather than a separate
tool. Until then, direct-image/VM installs use the 8 GiB floor, and the vault
warns at 75% and 90% with the reversible fixes listed.

Collected early because one item needs testing long before M7 starts.

**Trust is enforced by UEFI firmware, not the kernel.** Firmware verifies a
signature chain — `shim` → GRUB → kernel — and refuses to boot anything unsigned
while Secure Boot is on. The kernel is the *subject* of that check, not the
enforcer of it.

**Deriving from Fedora is a major advantage here — and it is now proven.**
Fedora's `shim` is signed by Microsoft's UEFI CA, and Secure Boot verifies the
boot chain rather than the whole filesystem, so our derived image inherits the
signing. Getting a *new* shim signed by Microsoft is a months-long process;
inheriting avoids it entirely.

**Verified 22 Jul 2026:** a Gen2 VM with Secure Boot **on** and the
`MicrosoftUEFICertificateAuthority` template booted our image normally.
Confirmed inside the guest — `mokutil --sb-state` reported *SecureBoot enabled*,
the EFI variable was set, `dmesg` logged *"Kernel is locked down from EFI Secure
Boot mode"*, `shimx64.efi` was Fedora's, and the health check passed.

**Consequence discovered by the test: Secure Boot puts the kernel in `integrity`
lockdown mode.** That is a security gain, but it restricts things — hibernation
is disabled, and unsigned kernel modules will not load. Power management (M3.5)
must plan for suspend rather than hibernate, and any out-of-tree driver needs
MOK enrolment. Better to design around now than to discover when a laptop
refuses to hibernate.

Consequences to respect:
- Do not replace `shim`, GRUB or the kernel without accepting the signing burden
- Out-of-tree kernel modules (NVIDIA being the obvious one) are *not* covered and
  need MOK enrolment or their own signing
- Never ship "just disable Secure Boot" as the install instruction. For a distro
  whose entire pitch is comfort and safety, telling users to switch off a
  security feature is the wrong first impression

**"Will a PC think it is a virus?"** The ISO itself is not scanned by the target
machine — it is booted, not executed under Windows. The real exposure is a
*Windows-side helper*: any `.exe` we ship to write USB sticks would trip
SmartScreen without an EV code-signing certificate. Cheapest correct answer is to
ship no Windows binary at all and point users at Rufus or balenaEtcher, which are
already trusted and solve the problem for free.

**Update signing is separate.** bootc can verify container signatures
(sigstore/cosign) so a machine only accepts updates genuinely from us. Distinct
from Secure Boot, and required before anyone else installs this.

---

## Milestone 3.5 — Identity & comfort 🟢 CORE COMPLETE, polish deferred

Core is built and verified. What remains is gated on real hardware (frame-timed
motion), artwork (themes), or a later milestone (M5) — not on more code that can
be checked in a VM. See the sourcing plan below for how each remaining piece
gets made.

**In plain words:** make KotinosOS look and feel like *itself*, and take work
away from the user.

**Why it is separate from M3.** M3 is plumbing — a shell exists, settings open,
hardware works. None of that stops the result being a Fedora respin with a
different wallpaper. Identity is a distinct body of work, and if it shares a
milestone with plumbing it is the first thing cut when the milestone runs long.
The distro that "looks and feels different" is the whole point, so it gets its
own phase.

### Started early (alongside M3, since both touch the same image)

- [x] **Boot splash** — wreath on a calm dark-teal field, no text at all. Breathes on a slow sine cycle rather than showing a spinner: a spinner says *waiting*, breathing says *running*. `rhgb quiet` added so the kernel is not fighting it for the console
- [x] **Windows coexist** — `ClickRaise=false` and `AutoRaise=false`, so clicking a window focuses it without burying its neighbours. This is the actual mechanism behind "nothing disappears when you click another window"
- [x] Tearing disabled, latency policy medium — on a desktop selling calm, tearing is the most jarring artifact available
- [x] Effects split by purpose: motion that *explains* (slide, scale, fades) kept; novelty that costs frames (wobbly windows, cube) removed
- [x] Accent colour and scheduled light/dark applied at first run
- [x] **One motion language** (`desktop-config/kwin-motion`, a KWin script) — a shared set of durations and curves everything reuses, rather than per-effect settings. Windows arrive over 220 ms on `OutQuint` (fast departure, long settle) and leave in 140 ms, since waiting for something already dismissed is the most irritating animation there is. Menus, tooltips and docks are excluded outright: animating those makes an interface feel laggy even when every individual animation is smooth. Replaces the stock scale effect rather than stacking with it, because two animations on one window read as jitter
- [ ] **True spring physics — still open, and deliberately not claimed.** What ships is spring-*like easing*: the perceptual signature of spring motion (fast out, long settle, never linear), which is most of the felt difference. Real spring behaviour — a window grabbed mid-flight continuing from its current velocity rather than snapping — cannot be expressed through KWin's scripting API, which animates on fixed duration plus curve. That needs a **C++ KWin effect**
- [x] **"Go back to yesterday"** (`kotinos-go-back`) — M2 built a working restore engine and gave it no way in. This presents restore points as *"yesterday, 14:30"* and *"before I unlocked admin mode"* rather than numbered subvolumes. A thin wrapper over `kotinos-recover`, so there is still exactly one restore path and it is the tested one. Snapshots the current state first, because undoing the undo has to be possible or nobody risks using it
- [x] **Silent updates** — bootc stages, applies at next reboot, greenboot health-checks it, a failure rolls back automatically. All three pieces already existed; enabling the timer made them a feature. An update that breaks the machine un-breaks itself before the user notices
- [x] **"What changed?"** (`kotinos-whats-changed`) — silent must not mean secret. Diffs the running deployment against the previous one and leads with what a person cares about (kernel, graphics, browser, desktop) rather than 400 library names. Ends by naming both undo paths, since "what changed?" is usually asked when something feels wrong
- [x] **Auto-cleanup with a budget** (`kotinos-cleanup`) — acts only above 80% and stops at 70%. Reclaims in order of least regret: rebuildable caches, then unreferenced images, then oldest routine snapshots. Never touches pre-escalation snapshots or user files. Runs at idle CPU/IO priority, because housekeeping the user can feel defeats the purpose
- [x] **Time-of-day wallpapers** — four generated from the brand palette (dawn/day/dusk/night), so they match exactly and can be rebuilt at any resolution. The switcher steps aside permanently once the user picks their own: an appliance that overwrites a personal choice every few hours is broken, not helpful. *(First attempt banded visibly — the horizontal term was rounded on its own, and 8 bits per channel cannot hold a smooth ramp over 2160 rows. Fixed with float accumulation plus an ordered dither.)*
- [x] **Focus mode** (`kotinos-focus`) — silences the whole machine, not one app's notifications. Half-measures are why do-not-disturb is usually distrusted: if one thing still pings, the user keeps half an ear out. Mutes rather than lowers, disables screen dimming, and restores the exact previous values rather than guessing at defaults
- [x] **Theme presets** (`kotinos-theme`) — five complete looks, each setting accent, scheme and wallpaper *together*, because those three fight when chosen independently. Includes a high-contrast option kept deliberately plain: an accessibility choice that looks like a compromise does not get picked by the people who need it
- [x] **SVG logo** — generated procedurally, so leaf count, arc sweep and taper stay adjustable. The splash PNG is now rendered from it at build time, keeping the vector authoritative
- [ ] Own icon, cursor and sound themes
- [ ] Offline-first help

---

## Signature motion — approved, not yet built

Chosen because each one makes something *true about the product* visible.
Decoration ages badly and costs frames; motion that communicates state is what
people remember. **None can be judged in Hyper-V** (no 3D acceleration), so
these get written and then tuned on real hardware.

- [ ] **Admin-mode ambience** — entering elevated mode subtly cools the palette and draws a thin accent frame; leaving restores it. Not decoration: **people forget they are root**, and that causes destroyed systems. Ambient privilege state is a security feature in an animation's clothes
- [ ] **Snapshot pulse** — a brief soft ripple at the screen edge when a snapshot is taken. The best feature in the product is currently *invisible*; the machine protects you constantly and you would never know
- [ ] **Boot-to-login continuity** — the splash wreath transitions into the login avatar rather than cutting. Requires Plymouth and the display manager to agree on a handoff, which is why almost no distro does it. It is the first ten seconds of every session
- [ ] **Wreath as universal progress indicator** — replaces generic spinners everywhere, drawing itself leaf by leaf. One motif at every size, now that the SVG exists
- [ ] **Focus-mode vignette** — edges gently darken and notifications visibly fold away, so the state is legible at a glance
- [ ] **Shake instead of dialogs** — a refused or dangerous action shakes the element rather than opening a modal. Faster, less interrupting, and does not train people to click through warnings
- [ ] **Tiling flow** — windows travel to new positions on the shared spring curve instead of jumping, so "windows coexist" reads as intentional

---

## M3.5 remaining — where each piece comes from

The question this answers: for the parts we cannot finish now, do we *make* them
or *get* them? Almost all are ours to write. Nothing needs to be bought. The
only external dependencies are the two asset themes, and those are forked from
existing open-source work, which is how every distro does it — nobody hand-draws
three thousand icons.

### 1. We write it — code, no external source

These are the same kind of work as the motion language and wallpaper switcher
already shipped. They need real hardware to *tune*, not to *build*.

| Piece | What it is | Notes |
|---|---|---|
| Spring-physics effect | C++ against KWin's animation API | Start from KWin's own GPL example effects as a skeleton, not from zero |
| The 7 signature animations | KWin scripts / small effects | Same category as `kwin-motion`; snapshot pulse and admin ambience also need a trigger signal from our services |
| Wreath progress spinner | Animate the SVG we already have | QML busy-indicator or animated SVG; the vector exists |
| Animated wallpaper transition | Crossfade between time-of-day wallpapers | Fork Plasma's image-wallpaper QML plugin to add a fade; currently it hard-swaps |
| Offline-first help | Content we write + a simple viewer | Pure authoring; no dependency at all |

### 2. We fork and rebrand — existing open-source assets

Drawing these from scratch is a multi-month art project no distro undertakes.
The standard, license-clean path is to fork a permissively-licensed theme and
recolor it to the wreath teal. **Licenses to confirm at integration**, but the
usual candidates are GPL-3 / CC-BY-SA, compatible with our GPL-3.

| Piece | Fork candidate | Why | License to verify |
|---|---|---|---|
| Icon theme | Papirus, or a `vinceliuice` theme (Tela/Colloid) | Thousands of icons, actively maintained, built to be recolored | GPL-3 |
| Cursor theme | Bibata | Built from a config by a script, so recoloring to teal is a value change, not a redraw | GPL-3 / OFL |

Rebranding is real work (recolor pipeline, keep attribution and license files),
but it is *our* build tooling over someone else's shapes — legitimate and normal.

### 3. Could go either way — sound theme

A dozen short sounds: login, notify, error, device plug/unplug.

- **Make:** synthesize them programmatically, the way the wallpapers were
  generated. Gives an exactly-on-brand set for free, at the cost of them
  sounding synthesized.
- **Source:** pull CC0 sounds (public domain, no attribution needed) and curate.
- **Commission:** a sound designer, if we want a signature audio identity. This
  is the one place paying money would buy something we cannot make ourselves at
  the same quality.

Default plan: synthesize a serviceable set now, leave commissioning as optional
polish.

### What this means

- **Nothing is blocked on a purchase.** Every remaining item can ship for free.
- **The two theme forks are the only true external dependencies**, and they are
  forks of open code, not licences we buy.
- **Optional spending** buys polish, not capability: a commissioned icon set or
  sound identity would look and sound better than our fork-and-recolor, but the
  product is complete without it.
- **Decision to make when we reach it (not now):** which icon theme to fork.
  Deferred until the artwork phase, since it does not affect M4.

---

## Milestone 4 — Sandboxing & hardening ✅ COMPLETE (pillar 5)

**In plain words:** make it so a bad app can only hurt itself, and so malware
can never reach the safety net. Today every app the user runs has the user's
full reach — one compromised program can read everything they own. M4 puts each
app in its own box, and puts a wall around the snapshots and the vault.

**Why now:** the safety net exists (M2) and the vault exists (M3.5), so for the
first time the central promise — *"nothing can delete your safety net"* — is
something we can actually attack and prove, rather than assert.

**The honest framing this milestone must keep.** Sandboxing is only as strong as
what each app is allowed to request, SELinux enforcing is not the same as a
bespoke policy, and no machine is "unhackable". So M4 does not claim security —
it tests *specific* claims adversarially, the way M1 tested rollback and M2 ran
`rm -rf /*`. Anything not tested is not counted.

**Exit criteria:**
- ✅ Apps run sandboxed, and a sandboxed app is *demonstrably* confined — one
  without filesystem permission cannot read `~/.ssh` or Documents.
  *(`tests/sandbox-confinement.sh`, 4/4 on a booted VM.)*
- ✅ SELinux is enforcing, and a denial is shown actually being blocked.
  *(`Enforcing` confirmed on the VM and asserted at both build and boot. Real
  enforced denials observed with `permissive=0` — `plymouthd_t` refused `search`
  and `init_t` refused `add_name`, both on `unlabeled_t`. See the caveat below:
  "enforcing" is true globally and is not true of every domain.)*
- ✅ A hostile process running *as the ordinary user* cannot delete snapshots or
  reach the vault — proven by running one. *(22/22 boundaries held. It did not
  hold on the first run: see the snapper finding below, which is the single most
  valuable thing this milestone produced.)*
- ✅ The firewall is default-deny inbound, and release images expose no
  unexpected ports. *(One expected inbound service, `mdns`, kept deliberately
  and written down. LLMNR was found and removed.)*

### Steps

- [x] **Flatpak app model** — installed, with `xdg-desktop-portal` as the broker. The Flathub remote ships as `/etc/flatpak/remotes.d/flathub.flatpakrepo`, not `flatpak remote-add`. Verified on a booted VM, where the timestamps tell the whole story: the remote file is dated image-build time and survived, while `/var/lib/flatpak/repo/config` is dated boot time because the image's `/var` was discarded exactly as `disk-layout.toml` says. Per-user installs now work — a real runtime was installed by an unprivileged user with no polkit prompt
- [x] **Prove the sandbox confines** — `tests/sandbox-confinement.sh`, 4/4 on the VM. A canary in `~/.ssh` and in `Documents` is invisible to a sandbox without filesystem permission and readable with `--filesystem=home`, the two runs otherwise identical. The denial shows as *"No such file or directory"* rather than *"Permission denied"*, which is the sandbox not merely refusing the read but never mapping the path
- [x] **Make "Flatpak-only" real, not just default** — confirmed on the VM: `/usr` is read-only (`touch` fails with *Read-only file system*), a system-wide `flatpak install` is refused for an ordinary user by polkit (*"operation Deploy not allowed for user"*), and per-user installs land in the user's own home where they cannot affect anyone else
- [x] **SELinux** — `Enforcing` confirmed on the booted VM, with a build-time assertion and a boot health-check assertion so a permissive image can neither ship nor boot unnoticed. A denial is now shown actually being enforced: with `sshd_session_t` and `sshd_auth_t` no longer permissive, a mislabelled `authorized_keys` gets the login **refused** and the AVC reads `permissive=0`, where M4's identical experiment succeeded at `permissive=1`
- [x] **Protect the safety net from the user's own processes** — this is where the milestone earned itself. See the snapper finding below: it was **not** protected, and the test proved it by destroying every snapshot on the machine. Now fixed and re-proved against the identical attack
- [x] **Firewall** — default-deny inbound, SSH genuinely absent from the default zone (it never was before — see findings), both the removal and the dev re-add asserted at build time. A release image's reachable inbound surface is now exactly one service, `mdns`, kept deliberately and documented in the Containerfile. LLMNR was found listening on `0.0.0.0:5355` and removed
- [x] **Kernel / sysctl hardening** — `90-kotinos-sysctl.conf` covers pointer and log exposure, ptrace scope, unprivileged BPF and runtime kernel loading. Unprivileged user namespaces are deliberately left enabled and documented: Flatpak and bubblewrap build their sandboxes out of exactly that feature. The audit confirmed the payoff from the other side — `bwrap` is **not** setuid on this image, so keeping user namespaces removes a setuid binary rather than adding risk
- [x] **systemd service hardening sweep** — confinement applied across the KotinosOS services, with every omission carrying its reason. Two are load-bearing: `kotinos-vault-seal.service` gets **no** sandboxing at all, because any sandbox option puts it in a private mount namespace with slave propagation, so its system-wide `umount /vault` would succeed only inside its own view and the journal would print "vault sealed" over a vault that was still mounted and writable. `kotinos-hardware-tune.service` leaves `ProtectKernelTunables` unset, because it would pass today and silently swallow the first setting the service is ever taught to apply live
- [x] **Attack-surface audit** — `tests/attack-surface.sh`, clean on the VM. 18 setuid binaries, each justified in writing; every listener either loopback, deliberately-open `mdns`, or dev-only `sshd`. Written as a regression guard rather than a one-off: anything new fails the run until someone writes down why it is there. It found two real defects of its own (LLMNR, and world-writable unit files)
- [x] **The adversarial test (the centrepiece)** — `tests/adversarial-user.sh`, run on a booted VM as the real primary account: **22 boundaries held, 2 allowed by design, 0 wrong.** Deliberately not baked into the image. Its first run was not clean, and that is the point — it found the snapper hole below

### Findings (27 Jul 2026)

Eight defects, every one of them a protection that was written down, looked
present, and was not there. Two were caught by adding assertions to the build,
five by running the tests against a real booted machine, and one by systemd
complaining about a file nobody had looked at.

Two of them — the snapper permissions and the world-writable `vault.conf` — let
an ordinary user with no password attack the safety net directly. Both are fixed
and both are now probed by `tests/adversarial-user.sh`, so they fail loudly
rather than silently if they ever return.

**Final state, verified on `m4c`, an image nobody had touched:** 22 fresh-boot
checks pass, the adversarial test holds 22 of 22 boundaries with 2 allowed by
design, the attack-surface audit is clean, and sandbox confinement is 4/4.

#### The one that mattered: an ordinary user could delete every snapshot

`kotinos-snapshots.sh` configured snapper with `ALLOW_GROUPS=wheel` and
`SYNC_ACL=yes` — presumably so a user could see their own restore points without
a password. What it actually granted was **full control**, because snapper's
`ALLOW_GROUPS` is not a read-only permission: it authorises create *and delete*
over snapperd's D-Bus interface with no polkit prompt at all.

The primary user is in `wheel` so that they can `sudo`. So the primary user —
and anything running as them — could destroy the entire safety net with one
command and no authentication. Ransomware's first move, available for free.

This is not a theoretical finding. The adversarial test's first run did it:

```
dev deleting snapshot 1:   exit=0
dev deleting snapshot 2:   exit=0
dev deleting snapshot 3:   exit=0
=== snapshots AFTER dev's attempt ===
0 | single | | | root | | | current |          <- nothing left
```

Every restore point on the machine, gone, by an unprivileged process. The
central promise of this project — *nothing can delete your safety net* — was
false, and it was false because of a line we wrote, not because of anything
btrfs or the kernel did.

With `ALLOW_GROUPS=""` and `SYNC_ACL=no`, the identical attack returns
`No permissions.` on delete, on create, and on list, and all three snapshots
survive. Snapshot management now requires root, which means password sudo or
admin mode (M5) — the boundary M4 said should be there all along.

The uncomfortable part is how long this sat there looking fine. It was written
during M2, survived the `rm -rf /*` test (which ran as root, where it proves
nothing about this), and was only ever going to be found by something running as
the user and actually trying.

#### Home directories were world-readable, undone one line after being set

`useradd` correctly applied `HOME_MODE=0700` from `login.defs`. Then
`kotinos-firstboot.sh` ran, for `.cache`:

```sh
install -d -o "$USERNAME" -g "$USERNAME" "$(dirname "$dir")"
```

For `.cache` the parent *is the home directory*, and `install -d` without `-m`
does not merely default to 0755 for directories it creates — it **resets the
mode of one that already exists**. So every account's home was widened back to
0755 immediately after being correctly locked down, and any local user could
read any other user's files. Reproduced and fixed:

| step | result |
|---|---|
| `useradd` | `drwx------` |
| old `install -d` (no `-m`) | `drwxr-xr-x` ← the bug |
| fixed `install -d -m 0700` | `drwx------` |

#### The app model was installed but unreachable

Flatpak was present, the remote was configured, and a user still could not
install anything. Per-user installs had no source (`flatpak remotes --user` was
empty, so `install --user` gave *"No remote refs found for 'flathub'"*), and
system-wide installs are refused for an unprivileged user by polkit
(*"operation Deploy not allowed for user"*). Both doors shut.

Fixed with `kotinos-flatpak-remote.service`, a **user** unit that registers the
remote in the user's own installation from the same `.flatpakrepo` file the
system uses, so there is one source of truth for the URL and GPG key. Verified
by installing a real runtime as an unprivileged user. Per-user is the right
default anyway: such an app cannot alter what any other account runs, which is
the same boundary the rest of M4 rests on.

#### LLMNR was listening on every interface

`systemd-resolved` held `0.0.0.0:5355` on TCP and UDP. LLMNR resolves names DNS
failed to by shouting them onto the local network and trusting the first reply —
the mechanism behind a whole family of credential-theft tools, and worth
nothing to this system. Disabled in `90-kotinos-resolved.conf`; the listener is
gone. `mdns` (Avahi, 5353) was *kept*, because it is what makes printers and
network shares appear by themselves, and that is most of what an appliance is
for. It is now the single reachable inbound service on a release image, recorded
as a decision rather than an inherited default.

#### Every file the image copies in shipped world-writable — including the vault's config

This started as a cosmetic-looking warning and turned into the second-worst
finding of the milestone.

`COPY` preserves the source file's mode, and this repo lives on a Windows drvfs
mount that reports **0777 for every file**. So everything the Containerfile
copied in shipped as `-rwxrwxrwx`, root-owned: all ten systemd units, the sysctl
drop-in, the Plymouth theme, the KWin script, and the desktop and vault
configuration. Eighteen files in total.

For the ones under `/usr` this was invisible, because bootc keeps `/usr`
read-only — the safety came from the filesystem, not from the files being right.
But three of them land in **`/etc`, which is writable**. Confirmed on a booted
machine:

```
$ su - kotinos -c 'echo COMPROMISED >> /etc/kotinos/vault.conf'
YES-WROTE-VAULT-CONF
$ tail -1 /etc/kotinos/vault.conf
COMPROMISED
```

`vault.conf` decides what the vault backs up. An ordinary user — or ransomware
running as them, needing no privilege whatsoever — could append an exclusion for
their own documents, and the vault would carry on reporting successful backups
of everything that no longer mattered. A silent attack on the safety net,
arriving through a filesystem quirk of the *development* machine rather than any
decision anyone made.

Fixed with one permission sweep and a global assertion — `! find /usr /etc -type
f -perm /o+w` — so this cannot come back through a file added later, and so a
world-writable file appearing in the base image also fails the build. Verified
on a fresh boot: writes are now refused, and the world-writable count across all
of `/usr` and `/etc` is zero.

Found because `systemd-analyze verify` complains about it on every single run
and nobody had read the output; the full scope only surfaced once the
attack-surface audit was taught to look for it. Three probes were added to the
adversarial test so it is now attacked directly rather than merely audited.

#### The vault result, checked against the trivial-pass trap

Four of the adversarial probes concern the vault, and all four would pass on a
machine where the vault simply did not exist — the same shape of false comfort
as the rest of this list. So the vault was exercised directly rather than
inferred from the probes.

The partition is real (`sda4`, 8 GiB, ext4, `LABEL=kotinos-vault`),
`vault.mount` is a symlink to `/dev/null`, and nothing is mounted at `/vault`.
A backup was then run for real while watching from outside the service:

- the service completed (`backup complete`, `status=0/SUCCESS`)
- the host **never** saw `/run/kotinos-vault` mounted, across 25 checks spanning
  the whole run
- afterwards, nothing is mounted and the vault is absent from the host mount
  table

That confirms the reasoning written into `kotinos-vault.service`: `PrivateTmp`
gives the service its own mount namespace with slave propagation, so the vault
is mounted *only inside that service*. The guarantee is not merely "the window
is a few seconds a day" — during that window the vault is not in any other
process's view of the filesystem at all.

#### "SELinux is enforcing" is true, and means less than it sounds

The milestone brief warned that enforcing is not the same as a bespoke policy.
Testing showed exactly how that bites, and it is worth writing down because the
one-word answer `getenforce` gives is genuinely misleading.

The intended demonstration was to mislabel a user's `authorized_keys` and watch
sshd refuse it — the failure `kotinos-firstboot.sh`'s `restorecon` exists to
prevent. It did not refuse. Every label tried, including `unlabeled_t`, still
logged in. SELinux had in fact detected all of it:

```
avc: denied { read } comm="sshd-session" name="authorized_keys"
  scontext=...:sshd_session_t tcontext=...:unlabeled_t permissive=1
```

`permissive=1` is the whole story. `sshd_session_t` and `sshd_auth_t` are
**builtin permissive domains** in Fedora's policy — one of roughly thirty,
alongside `systemd_oomd_t`, `virtqemud_t` and others. The policy knows the
access is wrong, logs it, and permits it anyway. So on a machine reporting
`Enforcing`, the domains handling SSH authentication are not confined at all.

Enforced denials do happen and were observed (`plymouthd_t` refused `search`,
`init_t` refused `add_name`, both `permissive=0`), so the mechanism works and
the exit criterion is met. But the honest statement of what SELinux buys this
project today is: *Fedora's targeted policy, enforcing, with a set of upstream
permissive domains we have not reviewed* — not *every service is confined*.
Reviewing that list, and deciding which permissive domains matter for an
appliance, is M5-or-later work. Forcing `sshd_session_t` enforcing without doing
the policy work would break SSH, which is not a trade worth making blind.

Related, and left as-is deliberately: **`auditd` is not installed.** Denials
still reach the journal, which is how all of the above was found, so nothing is
invisible. But there is no persistent audit trail across boots and no
`ausearch`/`aureport`. That is a reasonable default for an appliance and a poor
one for a security investigation; noted so the choice is a choice.

#### The two found earlier, at build time

**The firewall was not removing SSH, and said it was.**
`firewall-offline-cmd` carries a legacy lokkit compatibility layer in which
`--remove-service` is a lokkit option, so combining it with `--zone=` fails
outright with *"Can't use lokkit options with other options."* That call was
wrapped in `|| true`, so it failed on every single build while the build stayed
green. The default zone kept SSH the whole time — the milestone's headline
firewall claim was false. Now the zone definition is written directly to
`/etc/firewalld/zones/public.xml` by filtering the stock file, and the build
asserts both that the default zone is `public` and that SSH is absent from it.
The dev-build re-add is asserted too, because the mirror-image failure — a test
machine nobody can log into — costs an afternoon to diagnose.

**The Flathub remote would not have survived first boot.**
`flatpak remote-add` writes to `/var/lib/flatpak/repo/config`, and `@var` is its
own subvolume, which bootc does not seed from the image (the same trap that
swallowed the image-seeded SSH keys — see `disk-layout.toml`). The build-time
`flatpak remote-list | grep -q flathub` passed inside the container and would
have booted to a machine with no app source at all. The remote now ships as
`/etc/flatpak/remotes.d/flathub.flatpakrepo`, on `@` and image-managed.
Confirmed in the built image: `flatpak remotes` lists flathub as a system remote
while `/var/lib/flatpak/repo/config` does not exist at all. Corroborating
detail — flatpak's own `%post` enables a *boot-time* `flatpak-add-fedora-repos`
service, because upstream hit this same problem.

**Two things the attack-surface audit found that are worth keeping in view.**
`bwrap` is *not* setuid on this image: Flatpak builds its sandboxes out of
unprivileged user namespaces instead. That is the same kernel feature
`90-kotinos-sysctl.conf` deliberately leaves enabled, so the sandbox costs no
setuid binary — the reason "disable unprivileged userns" would have been the
wrong hard line. Separately, the audit found `chfn` and `chsh` setuid root so a
user can edit their own `/etc/passwd` fields, which an appliance with one account
and a fixed shell has no real use for. They were recorded as removal candidates
rather than removed on a hunch; both have since had the setuid bit cleared —
see "Finishing touches" below.

### Finishing touches — done (3 Aug 2026)

The three items M4 left open have been closed. Two of them turned out to rest on
a premise that was wrong, which is the main reason they were worth doing rather
than carrying forward indefinitely.

#### SSH authentication is now actually confined

`getenforce` returns a single global answer to a per-domain question. Fedora
ships **41 builtin permissive types**, and inside a permissive domain the policy
evaluates the access, logs the denial, and allows it anyway. Two of them —
`sshd_session_t` and `sshd_auth_t` — are the domains handling SSH authentication.

M4 assumed forcing them enforcing would break login and left them alone. That
assumption was never tested, and it was wrong.

Getting there needed a mechanism M4 had not found. `semanage permissive -d` only
removes types added with `semanage permissive -a`; builtin ones come from
`(typepermissive x)` compiled into the service's own policy module and the
removal fails outright. The fix is to install a corrected copy of the `ssh`
module at a higher priority, which the Containerfile now derives at build time.
Overriding a policy module would normally be a bad trade — it shadows every
future upstream fix — but this is an image-based OS, so the override is
re-derived from that build's own `selinux-policy` on every build and the freeze
lasts exactly one image.

Verified on a booted VM. The M4 experiment that failed then now passes:

| | M4 (permissive) | now (enforcing) |
|---|---|---|
| mislabelled `authorized_keys` | login **succeeded** | login **REFUSED** |
| the AVC | `permissive=1` | `permissive=0` |

Key login as root and as the user, command execution, `scp` in both directions,
`sftp`, and repeated sessions all work, with **no new enforced denials**. SSH
password auth could not be confirmed either way: it fails on this image for an
unrelated reason — the dev account has no home directory, a `/var`-shadowing
artefact — and it fails **identically with the domains permissive**, so SELinux
is not involved. Release images have no dev account.

**The other 39 were reviewed and deliberately left.** 22 of them label software
this image does not install, so they are not attack surface at all — including
`gnome_remote_desktop_t` and `samba_bgqd_t`, the two that sounded worst. Most of
the remainder are systemd generators that run for milliseconds during early
boot, where the breakage risk is a machine that will not start and the security
value is close to nil. Only four permissive domains have a live process at all:
the two SSH ones now fixed, plus `switcheroo_control_t` and `systemd_oomd_t`,
both local and unprivileged.

**A caveat was raised here and then disproved, which is worth recording because
the reasoning was sound.** `semodule` installs the priority-400 override into the
policy *store*, and if that store lived in `/var` it would be discarded on first
boot — the same property that forces account creation into `kotinos-firstboot`.
The booted machine would still be enforcing, because the *compiled* policy under
`/etc` survives, but it would have lost the ability to **rebuild** that policy:
the first `setsebool -P` or `semanage fcontext` would regenerate it from Fedora's
priority-100 module with the permissive statements back in, silently. M5 is full
of exactly those commands, so this would have mattered.

It does not happen. `/var/lib/selinux` is a **symlink to `/etc/selinux`**, so the
store sits on the root subvolume and is carried by the image. Measured on a
freshly booted `m4d`, where `/var` had just been created from scratch:

```
/var/lib/selinux -> ../../etc/selinux
400 ssh                  cil          <- override present in the store
sshd types permissive: 0 of 2
```

Then both commands that would have exposed the problem were run directly —
`setsebool -P selinuxuser_execmod on` and `semanage fcontext -a` — and after each
one the override was still registered and both domains still enforcing, with a
mislabelled `authorized_keys` still refused at `permissive=0`.

The check stays in `tests/attack-surface.sh` regardless, and the build still
asserts the module landed at priority 400. The conclusion is verified rather than
assumed, but it rests on a symlink that a future Fedora could move, and the cost
of noticing that early is one line of output.

#### `auditd`: not installed, and the reason M4 gave was wrong

M4 recorded the gap as "no cross-boot trail". There is one — `/var/log/journal`
exists, the journal is persistent, and AVCs land in it. What is actually absent
is the audit *tooling* (`ausearch`, `aureport`) and rule-based auditing.

So the decision is to leave `auditd` out for now, on narrower grounds than the
original note implied: the denial record already survives reboots, and what
`auditd` adds is watches and syscall rules, which are worth having only once
there is a privileged path worth watching. That path is admin mode, and
designing the rules alongside it in M5 is better than installing a daemon
speculatively now. Worth stating plainly: neither option is tamper-evident
against a root-level compromise, so this is a convenience-and-forensics
trade-off, not a security boundary.

#### `chfn` and `chsh` are no longer setuid

Both were setuid root so a user could edit their own `/etc/passwd` fields. On a
single-account appliance with a fixed shell, the display name belongs to the
settings app and the login shell is an admin-mode decision. The setuid bit is
cleared rather than the package removed, because `rpm -qf` puts both in
**util-linux** — the package that also supplies `mount`, `umount`, `lsblk` and
`findmnt`, so removing it to be rid of two setuid binaries is not a trade
anybody would take. Worth recording that this was guessed wrong twice before it
was checked: neither shadow-utils (which owns `passwd`, `chage`, `gpasswd` and
`newgrp`) nor util-linux-user (where these live on some other Fedora variants)
is the answer here. The value is not that these two have a known flaw — it is
that they stop mattering if one is found. The setuid count drops from 18 to 16.

`tests/attack-surface.sh` now **fails** if either SSH domain becomes permissive
again, if the priority-400 override goes missing from the policy store, or if
`chfn`/`chsh` reappear as setuid, so none of the three can silently regress. It
also fails if it could not *run* the SSH check at all — an audit that skips its
own regression guard in silence and then prints "No unexpected attack surface"
is the failure mode worth guarding hardest, since it reports a clean result for
a check that never happened.

### Dependency to keep in view

The AI (M6) will be given system access, which is a deliberate hole punched
straight through this sandbox model. Whatever boundaries M4 establishes, M6's
policy engine has to respect them — the AI must not become the way every
sandbox is bypassed. Worth building M4's boundaries as things the AI is *also*
subject to, not just the user.

---

## Milestone 5 — Admin mode & offline 2FA 🚧 IN PROGRESS (pillar 4)

**In plain words:** the everyday account cannot break the machine, and when the
user genuinely needs full control they unlock it on purpose — with something
they physically have, not just something they know — and the machine takes a
safety copy before the door opens.

**Why now:** M4 proved the ordinary user's boundary holds, 22 probes out of 22.
M5 builds the one deliberate door through that boundary. Doing it in this order
matters: a door is only meaningful in a wall that has been tested, and the wall
was tested last milestone.

**The honest framing this milestone must keep.** `PLAN.md` states the trap
plainly and it is worth repeating here, because it is the thing most likely to
go wrong:

> gating a settings *GUI* behind 2FA protects nothing if the user already has a
> shell. Enforcement has to live at the policy layer — a `polkit` agent or LSM —
> or it's theater. Decide this before writing UI.

A padlock drawn on a settings window, with `sudo` still working in a terminal
underneath it, is not a security feature. It is a worse outcome than having no
admin mode at all, because it invites trust it has not earned. **The enforcement
point is decided and tested before a single pixel of interface is designed.**

Second piece of honesty, about what a second factor here actually buys. The
person unlocking admin mode is usually the same person who knows the password,
so this is not "two people must agree". What it buys is narrower and worth
stating precisely:

- **malware running as the user cannot escalate silently**, even having captured
  the password, because it cannot touch the key in someone's pocket;
- **a borrowed or stolen machine** does not hand over root with a shoulder-surfed
  password;
- **the AI in M6 has to pass the same gate as a human**, which is the only reason
  its "constrained root access" is a boundary rather than a promise.

What it does **not** buy: protection from a user who is talked into approving
something. Social engineering is outside what this milestone can fix, and
pretending otherwise would be the same overclaiming M4 spent its time deleting.

**Exit criteria:**
- A user who **knows the sudo password** but does not have the second factor
  cannot get root — proven by trying it, in a terminal, not just in the GUI.
- Unlocking admin mode is preceded by a successful escalation capture, and the
  door **refuses to open** if that capture fails.
- Admin mode ends by itself. A session left unlocked relocks without being asked.
- Losing the token does not brick the machine — there is a tested recovery path.
- The whole flow works with **no network** and is tested that way.

### Groundwork already surveyed (3 Aug 2026)

Checked on a booted machine while closing the M4 items, so the first decisions
start from facts rather than assumptions:

- **PAM really is the common chokepoint.** `sudo`, `su`, `sshd`, `sddm` and
  `login` all have stacks, and so does **polkit** — `polkit-agent-helper-1` links
  `libpam` and its service file is `/usr/lib/pam.d/polkit-1`. Fedora keeps PAM
  defaults under `/usr/lib/pam.d` with `/etc/pam.d` reserved for overrides, so
  looking only in `/etc/pam.d` makes polkit appear not to use PAM at all. It
  does. One stack edit can therefore cover the terminal and the desktop's
  authorisation prompts together, which is exactly what the GUI-theatre warning
  demands.
- **No second-factor module ships in the image.** `pam_faillock` is present;
  `pam_u2f`, `pam_oath`, `pam_pkcs11` and `pam_fprintd` are all absent. Both
  candidates are layerable from Fedora: `pam-u2f` 1.4.0 and `libfido2` 1.16.0 for
  FIDO2, `pam_oath` 2.6.14 plus `oathtool` for TOTP.
- **`/etc/polkit-1/rules.d` exists** and is where a KotinosOS rule would live.
- **The test VM cannot exercise FIDO2.** No `hidraw` device and no TPM: Hyper-V
  Generation 2 offers no straightforward USB passthrough. TOTP can be tested end
  to end in the VM today; FIDO2 cannot, and would need either a physical machine
  or a software authenticator. This is a real constraint on the "proven by
  trying it" exit criterion and should shape which factor is built first, rather
  than being discovered halfway through.

### Decision: the enforcement point (3 Aug 2026)

**PAM is the gate. `sudoers` and a polkit rule are how the gate is applied to the
two paths to root. SELinux is the backstop that protects the gate, and is
deliberately not the gate itself. Admin mode is an explicit state with its own
entry point, not a property of individual `sudo` calls.**

The starting position is worth stating plainly, because it is the thing being
fixed: the primary account is in `wheel` (`firstboot.conf` puts it there) and
there is no `sudoers` drop-in and no polkit rule anywhere in the image, so
`%wheel ALL=(ALL) ALL` is the whole privilege model — one password away from
root. (With one caveat that turns out to matter; see the correction at the end of
this section.) Every claim below is about closing that.

#### Why not the GUI

Settled already by `PLAN.md` and repeated at the top of this milestone: `sudo` in
a terminal walks around it. Recorded here only because it also fails the M6 test
in one step — an in-process AI agent never touches the GUI at all, so a gate
drawn there is invisible to precisely the caller that matters most.

#### Why not polkit alone

polkit is a real authorisation layer and it is where the desktop's privileged
operations funnel — `systemctl`, PackageKit, udisks, system Flatpak installs. But
**`sudo` does not consult polkit.** A polkit-only gate is the mirror image of the
GUI trap: it would lock the desktop and leave the terminal open, rather than the
other way round. It is a necessary half, not a whole.

#### Why not SELinux alone

M4's closeout proved the image can ship modified policy that sticks, so this was
a live option rather than a hypothetical. It is still the wrong choice for the
*gate*, for a reason that is structural rather than a matter of effort:
**SELinux has no notion of interactive authentication.** It can decide whether a
domain may do a thing; it can never ask a human for a token. It can enforce the
consequence of a decision made elsewhere, which means it cannot be the place the
decision is made.

Modelling "admin mode is open" as an SELinux boolean is wrong for a second,
simpler reason: a boolean is **global machine state**, and admin mode is a
property of one authenticated session. Two users, or one user and a background
service, would share the same switch, and a mode that cannot distinguish who
opened it is not a privilege boundary.

(An earlier version of this section argued against `setsebool -P` on the grounds
that rebuilding the policy store might silently undo the SSH confinement. That
concern was tested on a freshly booted machine and did not reproduce — the
override survives both `setsebool -P` and `semanage fcontext -a`, because
`/var/lib/selinux` is a symlink to `/etc/selinux`. The argument above stands on
its own without it. The persistent form is still the wrong shape for state that
must not outlive a reboot.)

#### Why PAM

It is the one place both paths meet. `sudo`, `su`, `login`, `sddm` and `sshd`
have stacks, and so does polkit — `polkit-agent-helper-1` links `libpam` with its
service file at `/usr/lib/pam.d/polkit-1`. One stack decision therefore reaches
the terminal and the desktop's authorisation prompts together, which is what the
GUI-theatre warning demands.

It is also **factor-agnostic**, and that matters more than it looks given the
constraint recorded above. The VM cannot exercise FIDO2, so the factor choice is
partly hostage to test hardware. Putting the gate in PAM means `pam_oath` and
`pam_u2f` are interchangeable at the gate, and the factor decision cannot force
an architecture change later.

#### The trap that shaped the rest of the design

The obvious way to express "admin mode is on" is group membership — drop the user
from `wheel`, add them back on unlock. **This does not work, and it fails
silently in the dangerous direction.** Supplementary groups are fixed on a
process when its credentials are established, so adding the user to `wheel` at
unlock does not reach shells that are already running, and — the part that
matters — removing them at relock does not revoke shells that are already
running. A terminal that was open when admin mode was granted would keep root
indefinitely, while the machine reported itself locked. That is a direct failure
of the "admin mode ends by itself" exit criterion, and it would not show up in
any test that unlocks, relocks, and then opens a *new* terminal to check.

So the state is a **timestamped grant consulted on every escalation attempt**,
never a cached credential. Expiry is then a property of the check rather than
something that has to be pushed out to existing processes.

#### Admin mode is entered explicitly

If the gate were "any `sudo` call", then `kotinos-escalate` would pin a
deployment and snapshot `/var` on every single `sudo`. The safety capture would
become noise, and noise gets switched off. One unlock, one capture, one window:
a dedicated entry point prompts for password plus factor, runs the escalation
hook, and only then writes the grant.

This is also where `kotinos-escalate` finally gets the caller its header has been
asking for since M2. It already exits non-zero when either capture fails, and the
unlock path treats that as *do not write the grant* — the door does not open, and
the failure is the reason.

#### How each path fails closed

- **`sudo`** — a check in `/etc/pam.d/sudo` that runs before the normal auth and
  refuses unless a valid, unexpired grant exists. The wheel user with the correct
  password and no grant gets nothing, which is exit criterion 1 stated as a
  mechanism.
- **polkit** — a rule in `/etc/polkit-1/rules.d` consulting the *same* check, so
  the two paths cannot drift apart into two different answers about whether admin
  mode is open.

#### What SELinux is still for

Protecting the grant. If the AI in M6, or a flaw in some setuid binary, can write
the grant file, then every layer above is decorative. Confining who may write it
is a question about domains rather than about people, which is what SELinux is
actually good at — and it is the concrete form of the M6 dependency recorded at
the bottom of this milestone.

#### Mechanism checks — run on the VM (3 Aug 2026)

The architecture above was decided before any of it was tested. Four mechanism
details were listed as believed-but-unverified; three are now settled and one
turned up a bypass that changes the design.

**`sudo` will skip the gate entirely unless `timestamp_timeout=0`.** This is the
important one. A gate in `/etc/pam.d/sudo` lives in the auth stack, and sudo
caches a successful authentication for five minutes by default — during which it
does not run that stack at all. Measured by logging every time the stack
executes, with both `sudo` calls in one session so the ticket actually applies:

| sudoers | second `sudo` | auth stack ran |
|---|---|---|
| default (5 min) | **succeeded, no authentication** | 1× (the first only) |
| `timestamp_timeout=0` | refused | 1× |

So on a default image the second `sudo` gets root without the gate being
consulted. Unlock, relock, and a `sudo` within five minutes still works, with the
machine reporting itself locked — exactly the "reports itself closed while still
working" failure the design set out to avoid, arriving through an upstream
default rather than through anything we wrote. **A `timestamp_timeout=0` drop-in
is therefore part of the gate, not an optimisation**, and `tests/` needs a probe
that fails if it is ever removed. Polkit's `auth_admin_keep` retention is the
same shape and still to be checked.

**Group membership genuinely cannot express a mode — confirmed.** With a test
group added and a process started while the user held it, removing the user left
`id` showing the group gone while `/proc/<pid>/status` still listed the gid:

```
id now says:                    kotinos wheel
the SAME running pid still has: 10 1001 1002      <- 1002 is the removed group
```

Adding the group back also failed to reach the already-running process. Both
directions behave as the design assumed, which is why the state is a timestamped
grant rather than a credential.

**`polkit.spawn()` works.** Tested by making the authorization *result* depend on
it — a rule that spawns and returns YES authorised, and a control without the
spawn also authorised, so rule loading was not the variable. This polkit is the
duktape build (`libduktape.so.207`), where spawn support was the open question.

**`pam_exec.so` is present** at `/usr/lib64/security/pam_exec.so`. Whether it
fails closed in the `auth` phase still needs testing against a check that
actually returns failure.

**Still unmeasured:** whether the grant check is fast enough to front every
polkit query. That one needs a grant check to exist first.

### Decision: the factor (4 Aug 2026)

**TOTP (`pam_oath`) is the factor we build. FIDO2 (`pam_u2f`) is supported for
people who own a key, and is the stronger of the two.** Both are offline. The
gate was deliberately designed factor-agnostic, so this decides what gets built
first rather than locking the architecture.

Everything needed is packaged in Fedora and layerable: `pam_oath` and `oathtool`
2.6.14, `pam-u2f` 1.4.0, `libfido2` and `fido2-tools` 1.16.0.

**Why not FIDO2 first, despite being stronger.** It asks a person to buy
hardware before they can administer the computer they already own. For a product
whose premise is that strangers install it and rely on it, a mandatory
twenty-five-pound purchase between the user and their own admin mode is not a
security decision, it is an adoption cliff. TOTP uses the phone they already
have.

**Where TOTP is genuinely weaker, stated plainly.** With FIDO2 the private key
never leaves the token, and no filesystem bug can leak it. With TOTP the
"something you have" is a *shared secret stored on the machine being protected*
— `pam_oath` keeps it in `/etc/users.oath`. Anyone who can read that file can
generate valid codes forever, silently, and the user has no way to notice.

That is not hypothetical for this codebase. M4 found every file the image copied
into `/etc` shipping world-writable, including the vault's config, and an
ordinary user demonstrably editing one. Had `/etc/users.oath` existed then, the
second factor would have been readable by any local account. So TOTP is chosen
with a specific obligation attached: **the secret's protection is part of the
gate**, gets an assertion at build time and a probe in `tests/`, and is a
concrete job for the SELinux backstop that the enforcement decision already
assigned to protecting the grant.

**The clock dependency is real but bounded.** TOTP needs the machine's time to be
roughly right. This image runs `chronyd`, reports `NTPSynchronized=yes`, and has
a working RTC (`/dev/rtc0`), so the normal case is fine. The failure case is a
desktop with a dead RTC battery and no network, which boots with a meaningless
clock — and the symptom is a user locked out of admin mode on their own machine.
That is exactly what the recovery codes in the next step are for, which makes
them a required part of the TOTP design rather than a nicety.

**Testability decided the ordering as much as adoption.** TOTP can be tested end
to end in the VM today. FIDO2 cannot be tested there at all: no `hidraw` devices,
no TPM, zero USB devices, and Hyper-V Generation 2 offers no USB passthrough.
Building the untestable factor first would mean the entire gate — PAM stack,
grant, expiry, escalation hook — going in unverified behind it, which is how this
project has repeatedly ended up with green checks over absent protections.

Worth recording so FIDO2 does not get written off as untestable forever:
`python3-fido2` 2.2.1 ships a software authenticator and `umockdev` 0.19.8 can
emulate USB HID devices, so a virtual token is plausible with effort. Neither is
needed to build TOTP, and both are the right thing to reach for when FIDO2 comes.

#### One correction to the starting position

The section above says that today the password alone is root. That is true of the
*configuration* — `%wheel ALL=(ALL) ALL` is in `/etc/sudoers`, the primary account
is in `wheel`, and there is no drop-in or polkit rule of ours anywhere. But on a
freshly provisioned machine it is not yet true in practice, because
`kotinos-firstboot` runs `passwd --lock`, so the account has **no usable
password** at all:

```
passwd -S kotinos  ->  kotinos L 2026-08-03 ...
sudo               ->  sudo: a password is required
```

The user cannot escalate by any means until a password is set, and the thing that
sets it is M3's first-run experience — which is the piece of M3 still unbuilt. So
the honest description of the starting position is "one password away from root,
and that password does not exist yet". This matters for M5 in a way worth
planning around: the moment a password is first set is inside the privilege
story, not before it, and admin-mode enrolment probably wants to happen in the
same flow rather than being bolted on afterwards.

### Steps

- [x] **Decide the enforcement point, and write down why** — done, above. PAM is
  the gate, `sudoers` and a polkit rule apply it to the two paths to root, and
  SELinux protects the grant rather than being the gate. Admin mode is an
  explicit state carrying a timestamped grant, because group membership cannot
  express a mode that has to end
- [x] **Disable sudo's authentication cache** — done. `timestamp_timeout=0`
  drop-in at `/etc/sudoers.d/10-kotinos-no-timestamp`, validated with `visudo -c`
  at build time, with a `tests/attack-surface.sh` section that fails if it is
  removed, set to a non-zero value, or undercut by a polkit rule returning
  `auth_admin_keep`. Each of those three guards was tested by breaking the thing
  it guards
- [x] **Choose the factor** — decided below: **TOTP first, FIDO2 supported.**
- [x] **Protect the TOTP secret at rest** — `/etc/users.oath` is created by the
  image at `0600 root:root` and labelled `shadow_t` rather than `etc_t`, both
  asserted at build time and probed on the running machine. Created in the image
  rather than at enrolment so the protection exists from first boot instead of
  depending on a tool getting it right unattended. Verified: an ordinary user is
  refused on both the secret and the recovery codes
- [x] **Enrolment, and the recovery path that has to exist** — `kotinos-admin
  enroll` writes the secret and prints ten recovery codes once. Codes are salted
  and hashed so reading the file yields nothing usable, consumed on use, and
  accepted case-insensitively because people type what they read. **The
  dead-clock case is tested, not assumed**: with the clock wound back to 2020 a
  stale TOTP is correctly rejected while a recovery code still opens the door
- [x] **Wire the existing escalation hook in as blocking** — done, and confirmed
  on the VM: unlocking produced a snapshot described *"pre-escalation: admin mode
  unlock by kotinos"* and a pinned deployment. A non-zero exit from
  `kotinos-escalate` means the grant is not written and the door does not open
- [x] **Time-box the unlocked state** — a fifteen-minute grant, checked on every
  attempt rather than scheduled, so expiry needs nothing pushed out to processes
  already running. `kotinos-admin status` shows the time left. Verified by
  winding a grant's expiry into the past and watching the next `sudo` refuse
- [~] **Record what admin mode did** — unlock and lock are logged to the journal
  via `logger`, which is enough to answer *when* admin mode was open and for
  whom. What happened *during* it is not recorded, and that is the part the
  `auditd` decision was deferred to. Still open
- [ ] **The restricted surface stays restricted** — M3 already limits the settings
  app via Plasma's Kiosk framework. Verify that the full control panel is
  genuinely unreachable while locked, rather than merely unlisted
- [x] **The adversarial test grows a second half** — `tests/adversarial-admin.sh`,
  run on `m5b`: **12 allowed, 2 blocked.** Mostly a list of things that succeed,
  because admin mode grants root and that is what it is for. The two that resist
  are writing into `/usr` and making it permanently writable — bootc keeps the
  running deployment read-only, and root is not enough to change the OS in place.
  The uncomfortable ones are recorded rather than glossed: the TOTP secret is
  readable once admin mode is open, so one compromised session can mint second
  factors indefinitely and nothing prompts a re-enrol; and admin mode can extend
  its own grant and edit its own gate, so expiry bounds forgetfulness rather than
  an adversary already inside
- [x] **Put the gate in front of both paths to root** — `sudo` via a `pam_exec`
  helper in its auth stack, and polkit via a rule consulting the same check, so
  the two cannot drift into different answers. Both verified on a booted machine

### Building it: what the machine said (4 Aug 2026)

The design above survived contact largely intact. What follows is the part worth
keeping — the things that were wrong, the things that were invisible, and the
two places where the obvious implementation was the broken one.

#### The gate is in sudo's PAM stack, and `seteuid` is load-bearing

`pam_exec` runs the helper as the **invoking user** unless told otherwise. The
grant was `0600 root:root`, so the helper could not read it, so the gate refused
every attempt — including ones with a perfectly valid grant. It presented as a
PAM malfunction rather than a permissions problem, which cost the most time of
anything in this milestone.

Compounding it: **sudo renders any failed auth module as `PAM authentication
error: Unknown error -1`**, which reads like something broken rather than like a
refusal. It is not. `pam_exec /bin/false` produces exactly the same message.
Isolated by running the same stack against `/bin/true` and `/bin/false` until the
message stopped being mysterious.

#### The bootstrap: opening admin mode needs root, and root needs admin mode

Resolved with a sudoers rule rather than an exception inside the gate, because
**NOPASSWD makes sudo skip its PAM auth stack entirely** — measured at zero stack
executions, not assumed. So the unlock helper is reachable without a grant and
nothing else is.

NOPASSWD is not unauthenticated: the helper demands the password *and* the
factor itself. Passwords go through `unix_chkpwd`, the helper PAM itself uses, so
this asks the same question the rest of the system asks rather than
re-implementing shadow parsing. It also refuses everything for a locked account,
which is a freshly provisioned machine's state — so admin mode cannot be opened
before the user has a password at all.

#### polkit failed with no error anywhere, because a `dontaudit` rule hid it

The desktop half returned nothing useful and logged nothing — not in the journal,
not in `ausearch`. `polkit.spawn` of `/bin/true` worked, so spawning was fine;
spawning the grant checker did not. The denial only appeared after `semodule -DB`
turned dontaudit off:

```
avc: denied { read } comm="bash" name="admin-grant"
  scontext=...:policykit_t  tcontext=...:var_run_t  permissive=0
```

`polkitd` runs unprivileged in `policykit_t` and simply could not read the grant.
This is the failure mode to remember: a policy problem that presents as *"the
code does not work and there is no error"*.

Fixed with `kotinos-adminmode.cil` — the grant gets a type of its own and exactly
`policykit_t` is allowed to read it, rather than opening up `var_run_t` and
handing polkit every runtime state file on the system. This is the concrete form
of "SELinux protects the grant" that the enforcement decision promised.

#### The grant is `0644`, and that is deliberate

It looks like the wrong direction and is not. `polkitd` cannot read a root-only
file whatever SELinux permits, so `0600` would leave the desktop half failing
closed forever against a grant it had legitimately been given.

The property that matters here is **integrity, not secrecy**. Knowing admin mode
is open tells an attacker nothing they could not learn by trying `sudo`. Being
able to *write* the file would hand them root outright. So: readable,
root-writable only, and SELinux narrows the read side to one domain.

#### What the polkit rule returns, and why not `NOT_HANDLED`

When admin mode is closed the rule returns `NO`, not `NOT_HANDLED`. Falling
through would reach a default of `auth_admin` — a password prompt that would then
succeed, when the entire point is that the password alone is not enough.
Observed directly, since `pkcheck` prints the result it cannot satisfy:

| state | result |
|---|---|
| closed | `polkit\56result=no` |
| open | `polkit\56result=auth_self` |
| expired | `polkit\56result=no` |
| an ungated action | `polkit\56result=auth_admin` (untouched) |

That last row is the one that keeps the appliance usable: joining a wifi network,
changing brightness and mounting a USB stick are deliberately not gated, because
an appliance demanding admin mode to mount a memory card is broken rather than
secure.

#### Verified on a clean image (`m5b`, 4 Aug 2026)

Everything above was built through `bootc usr-overlay`, which is transient by
design, so none of it counted until an image booted with the gate baked in. 28
checks on `m5b`, 0 failures:

- the gate helper, the PAM line (first among `auth` rules, with `seteuid`), the
  unlock sudoers rule, the polkit rule, the SELinux module at priority 400 and
  the grant's file context all come from the build
- **a correct password alone returns nothing**, and polkit answers
  `result=no` — the milestone's headline criterion, from a machine nobody touched
- both factors open it; the escalation snapshot is taken and the deployment
  pinned before the grant is written; `sudo` then returns root and polkit answers
  `result=auth_self`

- either factor alone writes no grant
- `lock` and expiry each close it again
- a recovery code works as the second factor
- no failed units, SSH domains still enforcing, setuid still 16, no
  world-writable files, `users.oath` still `shadow_t`

#### An unrelated find: every build was rebuilding everything

`ARG BUILD_ID` was consumed at step 3, and an `ARG` invalidates the layer cache
from where it is used — so changing the tag discarded all seventy-odd steps
including the several-hundred-package desktop install. Measured at **one cached
step out of seventy-three**. Nothing during the build reads that file; every
consumer is at runtime.

Moved to the end. The next build cached **66 steps and reached step 77 of 80 in
forty seconds**, against roughly forty minutes before.

### The connection worth keeping in view

M4 proved the safety net survives an unprivileged attacker. M5 is where the
*privileged* path gets built — admin mode is, by design, the thing that can
delete snapshots and reach the vault. Everything M4 locked down is reachable
again through it, so the 2FA gate and the policy layer are what stand between
"the user can recover their machine" and "malware that got one password owns the
safety net too".

### Dependency to keep in view

M6 gives the AI system access, and `PLAN.md` is blunt that because the ordinary
user is near-powerless by design, **the AI becomes the main escalation path** —
which makes its policy engine the security boundary of the whole product.

That lands squarely on this milestone. If admin mode is a gate a human passes
and the AI has some quieter way around, then the gate protects nothing that
matters and the AI is simply the new way to reach root. So M5 should be built on
the assumption that M6's policy engine is another *caller* of the same gate, not
a peer of it — and the enforcement point chosen in the first step above has to
be one an in-process AI agent cannot bypass. Choosing a GUI-level gate would
fail this test immediately, which is a second reason the first step is first.

---

## The vault — built and verified (22 Jul 2026)

A protected copy of irreplaceable files on a partition that stays disconnected
from the running system except while being written. See `kotinos-vault`,
`kotinos-apps`, and the storage-model scripts.

**First verification: 25/28 passed, and the 3 failures each taught something.**

- **The vault was unmounted for the wrong reason.** `systemctl mask` silently
  failed because the image builder had already written a real `vault.mount`
  file and mask will not overwrite one. The partition stayed unmounted only
  because the mount *attempt* had failed — right outcome, wrong mechanism, which
  would have broken the moment the mount ever succeeded. Fixed by symlinking the
  unit to `/dev/null` directly in the seal service, which then checks its own
  work and logs an error if the vault is still mounted. **Fifth instance of this
  project's signature bug (something reporting success while doing nothing), and
  the most dangerous, since the thing failing open was the security boundary.**
- **The Trash exclusion failed** because `btrfs subvolume create` does not make
  intermediate directories, and `.local/share` did not exist yet on a fresh
  home. `.cache` worked only because it sits directly in the home. Fixed by
  creating the parent first.
- Cosmetic: `lost+found` was listed as though it were a user.

**Re-verified after the fixes: 27/28 → 27/27, 0 failures.** The vault is now
sealed for the right reason — `vault.mount` is a symlink to `/dev/null`, an
explicit `systemctl start vault.mount` is refused (*"Unit vault.mount is
masked"*), and `/vault` stays unmounted through the attempt. The seal service
logs *"vault sealed"* after checking its own work. Trash is now its own
subvolume (`home/kotinos/.local/share/Trash`) alongside `.cache`.

Everything else confirmed on both runs: the 8 GB labelled ext4 partition, a real
backup that unmounts afterward, the app record as both a plain list and a
runnable reinstall script, btrfs quotas, `kotinos-space` explaining usage, all
five theme presets, and the splash rendered from the SVG.

**Infrastructure fix this cost:** builds kept hanging and getting killed from WSL
starving the Windows host of memory. Capped WSL at 12 GB in `~/.wslconfig`, which
removed the contention between builds (WSL) and VM tests (Hyper-V) on the same
32 GB machine. One hung build burned ~2 hours before the cause was found —
lesson recorded: check log *freshness*, not just whether processes exist.

## Signature features — what only KotinosOS can offer

The point is not more settings. These fall out of infrastructure already built
(continuous snapshots, an immutable OS, a planned AI with system access), which
is exactly why they are hard for others to copy.

**From the snapshot engine — already built, only unexposed**

- [ ] **Time-travel any file** — right-click → "earlier versions", for every file, always. Time Machine needs an external disk and setup; we already snapshot `/var` continuously, so **every file on the machine already has history and we simply are not showing it**. Highest value-per-effort item in the project
- [ ] **"Try it safely"** — flip a switch before installing something sketchy; everything it touches is tracked and one click restores. The nearest existing thing is a VM, which is heavyweight enough that nobody bothers
- [ ] **Ephemeral guest mode** — hand someone your laptop, everything they do evaporates on logout. Trivial given snapshots; no desktop OS does it cleanly
- [ ] **Settings undo** — snapshot before each settings change, then offer "undo what I did yesterday" at system level rather than per-app

**Needs the AI (M6)**

- [ ] **"Why is my computer slow?"** — one honest answer from real telemetry, in plain English, with a fix offered. Every OS currently makes you open three tools and interpret graphs
- [ ] **"What is using my disk / battery / network?"** — one answer, not five utilities
- [ ] **Ask your files** — the semantic layer *answering* rather than listing: "what did I agree to about the March deadline?" returns the answer with the document cited

**Only possible because the OS is an image**

- [ ] **Portable session** — user state lives in `/var` and the OS is a swappable image, so an environment can move to another KotinosOS machine or be restored onto new hardware in minutes. Nobody offers this because nobody else's OS is separable from its state. Ours already is
- [ ] **Permission ledger** — plain English: "this app read your Documents 40 times today". A record of what happened, not a toggle

### M3.5 verification (22 Jul 2026)

**23 checks, 0 failures** against `BUILD_ID=m35` booted with Secure Boot on:
motion script installed and enabled with the stock effect disabled, all four
wallpapers present with the switcher correctly resolving *hour 11 → day*, focus
mode reachable and reporting state, boot splash active, every comfort tool on
`PATH`, and nothing regressed — desktop, hardware tuner, snapshots, health check
and Secure Boot all still pass.

### Remaining candidates

**Visual identity & motion**
- SVG logo, needed for the splash at arbitrary resolutions (the PNG is fixed-size)
- **Spring-based motion system, macOS-grade smoothness.** macOS feels fluid because motion is *physics*, not fixed-duration easing: things decelerate naturally and an interrupted animation blends into the new one instead of snapping. One spring configuration (stiffness/damping) shared by windows, workspaces and the AI sidebar, so everything moves like one system.
  - *Legal note:* the technique is public and widely reimplemented; Apple's protected material is their assets and code. Same physics and restraint, our own artwork — no exposure.
  - Practical requirement: this only looks right if the compositor never drops frames, so vsync and frame pacing come first. Smooth-at-60fps beats elaborate-and-stuttering.
- Own icon, cursor and sound themes; stock ones give away the base distro
- Login and lock screens continuous with the boot splash
- Honour reduced-motion preferences throughout

**Window management — everything stays visible**
- **Clicking one window must never hide another.** Windows arrange so they coexist rather than stack: position them freely and keep using all of them at once. This is the opposite of macOS Stage Manager, which hides what you are not focused on.
- Implementation direction: a tiling/mosaic layout on Wayland (KWin tiling, or a scrollable-tiling compositor) where windows do not overlap by default, with focus changing *without* raise-over-others.
- Fits the comfort principle exactly: the user should never be doing window management as a chore — no hunting for a window that vanished behind another.
- Open question for the build phase: whether overlapping floating windows are allowed at all, or only as a deliberate opt-in.

**Personalization — many tasteful choices, zero dangerous ones**
- System-wide accent colour (highlights, cursor, app chrome)
- Light/dark on a sunrise/sunset schedule, with manual override
- A single comfort slider for text and UI size, not per-app scaling
- Curated theme presets rather than infinite knobs — the restriction principle applied to aesthetics
- Time-of-day wallpapers

**Comfort — actual friction removal**
- **"Go back to yesterday"** — a friendly face on the snapshot restore built in M2. The engine exists and currently has no UI
- **Silent updates** — applied in the background, effective at next reboot, never interrupting. bootc makes this natural and it beats every mainstream OS
- **"What changed?"** — a plain-English summary after an update
- **Auto-cleanup with a visible budget** — snapshots, caches, downloads. The user should never meet "disk full"
- Automatic power and thermal profiles; no manual power management
- Focus mode that genuinely silences the whole system
- Offline-first help that works with no internet
- ~~Errors explained in plain English instead of a log~~ — *dropped by decision*

---

## Milestone 3 — Desktop & appliance UX 🚧 IN PROGRESS

**In plain words:** KotinosOS gets a face. It boots to a desktop, configures the
hardware without asking, and offers a settings app that cannot break anything.

**Exit criteria:** a fresh image boots to a graphical login, the provisioned user
reaches a working desktop, hardware is auto-tuned with the decisions logged, and
the settings surface exposes only what is safe to change.

### Decision: KDE Plasma 6 on Wayland

Chosen for reasons specific to this product, not preference:

- The **AI sidebar must dock over arbitrary windows** (M6). KWin scripting makes
  that tractable; GNOME's extension API is restrictive and breaks between releases
- **Windows that coexist rather than stack** — KWin has real tiling built in
- **Wayland gives proper frame pacing**, which the spring-physics motion depends on
- Plasma is genuinely themeable, which M3.5 requires

*Testing constraint:* Hyper-V provides a basic framebuffer with no 3D
acceleration, so we can verify the desktop **works** but cannot judge **animation
smoothness** in a VM. M3.5's motion work needs real hardware to evaluate.

### Steps

- [x] Plasma added as a curated package list, not the `kde-desktop` group (which drags in the whole KDE app suite)
- [x] **SDDM enabled and a graphical login verified running** — `loginctl` shows a greeter session on `seat0`/`tty1`, and a console capture shows the Plasma login screen. Build-time assertions guard that `sddm` is enabled and the default target is `graphical.target`, so a black screen cannot ship silently
- [x] Image size measured: **2.02 GB → 4.73 GB**. bootc ships only changed layers, so updates stay small; the initial download is what grows
- [x] Verified the desktop image still boots **with Secure Boot on**, takes its baseline snapshot, and reports HEALTHY
- [x] **Hardware auto-tuning profiler** written (detailed below)
- [x] First-run defaults written — accent, light/dark on the clock, browser, search engine
- [x] Settings surface restricted via Plasma's Kiosk framework
- [x] **All of the above verified on a running system** — 28 checks, 0 failures, against `BUILD_ID=m3-final` booted with Secure Boot on
- [ ] Graphical first-run *wizard* (asking the questions rather than applying defaults) — still to build

### Verification (22 Jul 2026)

Ran against a live VM. The hardware tuner's own decision log, on a 2-vCPU
Hyper-V guest:

```
cpu       Intel Core i7-10700 @ 2.90GHz   detected, 2 threads
memory    2 GiB                           detected
chassis   desktop                         battery absent
memory    swappiness=100                  <=8 GiB, favour compressed swap
memory    zram=0.5 of RAM                 sized to installed RAM
storage   scheduler rules installed       rotational=yes solid-state=no
cpu       left alone                      no cpufreq driver (likely virtualised)
```

That last line is the "conservative when unsure" rule working: the VM exposes
no cpufreq driver, so it set no governor rather than guessing.

**Two process failures worth remembering, both mine:**

1. **A failed build reported success.** The wrapper was
   `./build.sh … > log 2>&1; echo "EXIT=$?"` — the trailing `echo` always
   succeeds, so the shell returned 0 while the build had died. A *stale* disk
   image was then converted, booted, and verified, producing 15 false failures
   before the `BUILD_ID` in the output revealed the wrong system was under test.
   Always branch on the build's own exit status.
2. **The boot splash never worked.** `ModuleName=script` needs
   `plymouth-plugin-script`, which was not installed. **The assertion caught
   it** — without `plymouth-set-default-theme | grep -qx kotinos`, the image
   would have built clean and quietly used Fedora's default splash.

Second is the fourth instance of this project's signature failure: something
reporting success while doing nothing. It is also the second time an assertion
added specifically to catch that class of bug did its job.

---

## Hardware auto-tuning — part of M3

**In plain words:** the machine reads its own hardware at first boot and picks
the best settings for every component, with no questions asked. Pillar 1, and
currently the least specified part of the roadmap — "zero-config" was stated as
a goal but never as a mechanism.

A profiler runs at first boot, detects what it is running on, and writes tuned
configuration. Every value it chooses stays overridable in admin mode.

| Detected | Tuned |
|---|---|
| CPU vendor/model | scaling governor, energy-performance preference |
| GPU | correct driver enabled, power profile |
| Storage type (NVMe / SSD / HDD) | I/O scheduler, TRIM |
| RAM size | swappiness, zram size |
| Battery present | laptop vs. desktop power profile |
| Display | resolution, refresh rate, fractional scaling / HiDPI |
| Network adapter | power-save behaviour |
| Thermals | fan curve where the platform allows |

Design constraints:
- Runs at first boot like the other `/var`-dependent setup, and re-runs when
  hardware changes (different machine, new GPU) rather than only once
- Writes decisions to a readable log — "why is my governor set to X" must be
  answerable
- Every choice overridable in admin mode; auto-tuning is a *default*, not a lock
- Conservative when unsure: a wrong aggressive setting is worse than a safe one

---

## Milestone 2 — Safety net ✅ COMPLETE

> All four exit criteria met. One gap found along the way (no spare deployment
> on a fresh install) is deferred to M7, where the installer can fix it properly.

**In plain words:** the OS can already undo a bad *update*. This milestone lets
it undo a bad *day* — accidental deletion, a botched config, a destructive
command. You notice it exactly once: when something goes wrong and the machine
offers to put it back.

**Exit criteria:** scheduled snapshots of user data exist with a bounded disk
budget; a snapshot is taken automatically before admin escalation; a broken
system can be recovered from the bootloader; and `rm -rf /*` has been run with
the survival story written down.

**The hard part** is restoring, not snapshotting. bootc owns `/`, so rolling
back user data on `@var` is a *different* mechanism from OS rollback — and it
has to work when the machine is too broken to boot normally.

### Steps

- [x] Install `snapper` in the image
- [x] Register a snapper config against **`@var`** at first boot — `.snapshots` cannot be created at build time, same `/var` reason as M1.5
- [x] Set retention + disk budget (`SPACE_LIMIT=0.3`, `FREE_LIMIT=0.2`, plus timeline counts) so snapshots can never fill the disk
- [x] Enable timeline + cleanup timers
- [x] **Escalation hook** (`/usr/libexec/kotinos-escalate`): pins the current ostree deployment *and* snapshots `@var`. Fails closed — non-zero exit means the M5 gate must refuse escalation
- [x] **Restore mechanism decided: file-level via `snapper undochange`.** Subvolume swap was rejected — `/var` holds live system state (logs, container storage, the running `.snapshots` tree), so swapping it wholesale under a running system is far more disruptive than reverting file changes. Verified: destroyed a user's `Documents` and restored it with ownership and contents intact
- [x] **Adversarial test:** `rm -rf --no-preserve-root /*` run on a live system (results below)
- [x] **Recovery is automatic, via greenboot** — health checks run at boot; a failing boot triggers `bootc` rollback and a reboot with no human involved. Stronger than the original spec, which only asked the bootloader to *offer* recovery
- [x] **Health check written against the real failure mode** (`/usr/lib/greenboot/check/required.d/50-kotinos-health.sh`)
- [x] `kotinos-recover` restores user data from a snapshot without depending on `/etc`
- [x] Verify recovery against a deliberately broken system
- [ ] Guarantee a spare deployment always exists — a fresh install has only one, so greenboot has nothing to roll back to on day one. **Still open**; belongs with the installer (M7)

### Recovery verification

Full cycle observed on a live VM:

| Step | Result |
|---|---|
| Healthy system, upgrade v7 → v8 | applied and stuck |
| Broken system (user home destroyed), boot v8 | health check failed |
| greenboot response | `Deployment manager 'bootc' detected, attempting rollback` → `Rollback successful` → automatic reboot |
| Landed on | previous working deployment, **unattended** |
| `kotinos-recover` | restored the home from the baseline snapshot, ownership and SELinux labels intact |
| Re-upgrade after restore | applied and stuck; all 8 checks pass |

### Two bugs found and fixed here

**1. `|| true` shipped a disabled safety feature.** The `systemctl enable` line used
guessed greenboot unit names that don't exist in 0.16.3, with errors silenced.
The build passed and the image shipped with health checking off. Fixed with the
right unit (`greenboot-healthcheck.service`, whose `Also=` pulls in the rest)
plus an explicit `systemctl is-enabled` assertion that **fails the build** if any
safety unit is not enabled.

**2. The health check was too weak to detect the disaster it existed for.** It
tested `test -d /var/home`, but `systemd-tmpfiles` recreates that directory empty
on every boot — so a machine that had lost every user file reported *healthy*.
It now verifies the provisioned account's home exists **and is non-empty**.

Both are the same failure: *a safety feature reporting success while doing
nothing*. Same species as M1's silent rollback. This is why the destructive tests
matter more than reading the code.

### Adversarial test result — `rm -rf /*`

| Path | Outcome | Why |
|---|---|---|
| `/usr` | **survived intact** | read-only, image-managed by bootc |
| `/var/.snapshots` | **survived** | `rm` failed with *"Read-only file system"* — btrfs read-only snapshots resist deletion |
| `/var/home` | destroyed | writable user data |
| `/etc` | destroyed | writable, per-deployment |

**After reboot: the machine did not come back.** Heartbeat reported *No Contact*
and SSH never returned. The kernel loads, but userspace cannot start without
`/etc`.

**The honest recovery story today:** *your data survives, the running system
does not.* The snapshots holding every file are intact on disk — but nothing
currently running can reach them, because the OS that would perform the restore
is the thing that got destroyed.

**What this proves the recovery environment must do**, and it is now specified by
evidence rather than guesswork:

1. Boot **without depending on `/etc` or `/var`**, since both can be gone.
2. Run from `/usr`, which is the one thing that reliably survives.
3. Restore `/var` from a surviving snapshot.
4. Restore `/etc` — which is per-deployment, so it needs a redeploy or a second deployment.

**Related finding:** a freshly installed system has exactly **one** deployment, so
`bootc rollback` has no target. Rollback is not a recovery path on day one. The
install must leave a spare deployment pinned, or the bootloader must offer a
rescue entry that does not depend on one.
