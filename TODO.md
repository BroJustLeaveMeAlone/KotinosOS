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
| M3 | Desktop & appliance UX — shell, settings, first-run, hardware | ⬜ Not started |
| M3.5 | Identity & comfort — look, motion, personalization, friction removal | ⬜ Not started |
| M4 | Sandboxing & hardening | ⬜ Not started |
| M5 | Admin mode & offline 2FA | ⬜ Not started |
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
- [ ] **Test Secure Boot early** — every VM so far has run with it *disabled*. Deriving from Fedora *should* mean we inherit their Microsoft-signed `shim`/GRUB/kernel and boot with Secure Boot on, but that is an assumption, not a result. If it turns out false, it is an architecture-level problem, and finding that at M7 would be brutal. The test is cheap: one Gen2 VM with the Microsoft UEFI CA template and Secure Boot enabled
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

Collected early because one item needs testing long before M7 starts.

**Trust is enforced by UEFI firmware, not the kernel.** Firmware verifies a
signature chain — `shim` → GRUB → kernel — and refuses to boot anything unsigned
while Secure Boot is on. The kernel is the *subject* of that check, not the
enforcer of it.

**Deriving from Fedora is a major advantage here.** Fedora's `shim` is signed by
Microsoft's UEFI CA, and Secure Boot verifies the boot chain rather than the
whole filesystem. A derived image that does not replace those components should
boot with Secure Boot enabled, inheriting the signing. Getting a *new* shim
signed by Microsoft is a months-long process; inheriting avoids it entirely.
**Unverified so far — every test VM has had Secure Boot off.**

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

## Milestone 3.5 — Identity & comfort ⬜ NOT STARTED

**In plain words:** make KotinosOS look and feel like *itself*, and take work
away from the user.

**Why it is separate from M3.** M3 is plumbing — a shell exists, settings open,
hardware works. None of that stops the result being a Fedora respin with a
different wallpaper. Identity is a distinct body of work, and if it shares a
milestone with plumbing it is the first thing cut when the milestone runs long.
The distro that "looks and feels different" is the whole point, so it gets its
own phase.

Steps get written when we begin. Candidates gathered so far:

**Visual identity & motion**
- Boot splash with the wreath; never scrolling kernel text (needs the SVG logo)
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

## Hardware auto-tuning ⬜ NOT STARTED — belongs to M3

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
