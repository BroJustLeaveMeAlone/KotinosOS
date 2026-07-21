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
| **M2** | Safety net — snapper, escalation hook, recovery environment | ⬜ Not started |
| M3 | Desktop & appliance UX | ⬜ Not started |
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
- [ ] **Choose a license** — until one exists, nobody may legally use or contribute
- [x] **Directories renamed to say what they hold.** `files/` → `system-scripts/` + `systemd-units/`, `assets/` → `branding/`, `output/` → `build-output/`, `config.toml` → `disk-layout.toml`, `config.dev.toml` → `dev-credentials.toml`. Same rule for anything added later: no `src/`, `lib/`, `utils/`
- [ ] Logo: transparent-background PNG + SVG (current asset is white-background, shows a white box on dark themes)

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

## Milestone 2 — Safety net 🚧 IN PROGRESS

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
