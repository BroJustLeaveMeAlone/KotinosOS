# Workflow — how KotinosOS got built, day by day

A chronological account of the work: what was done, in what order, and how each
piece was proved before moving on.

This is the *narrative*. Its companions:

- **`PLAN.md`** — the architecture and why it is shaped that way
- **`TODO.md`** — per-milestone steps, exit criteria and findings
- **`docs/engineering-log.md`** — the failures, and what they taught

**Scale as of 4 August 2026:** 79 commits over 16 calendar days, 64 tracked
files, ~4,200 lines of shell across `system-scripts/` and `tests/`, a 771-line
`Containerfile`, and ~2,500 lines of project documentation.

| Day | Commits | What happened |
|---|---|---|
| 20 Jul | 5 | Planning, base image pinned, build script |
| 21 Jul | 16 | M1 rollback proven, M1.5 provisioning, M2 safety net |
| 22 Jul | 32 | M3 desktop, M3.5 identity, the vault |
| 25 Jul | 5 | Vault verification, M4 brief |
| 27–28 Jul | 4 | M4 built, attacked, and the code-quality pass |
| 3 Aug | 7 | M5 brief, enforcement decision, sudo gate groundwork |
| 4 Aug | 9 | M5 built and verified, documentation |

---

## The loop

Every milestone ran the same cycle. It is worth stating up front because the
whole project's reliability comes from step 5 existing at all.

```
 1. Write the brief            what this milestone claims, and how it can fail
 2. Change the image           Containerfile + system-scripts/
 3. Assert at build time       the build fails rather than shipping the mistake
 4. Build                      ./build.sh <tag> vhd   (WSL, rootful podman)
 5. Convert + boot             qemu-img -> VHDX, new Hyper-V VM, find IP by MAC
 6. Verify on the running VM   a numbered check script; count passes and failures
 7. Attack it                  run as the ordinary user, not as root
 8. Record honestly            including what did not work
 9. Commit                     one coherent change, message explains the why
```

Mechanically, on this machine: build in WSL2 (Ubuntu, rootful podman), convert
the `vhd` to dynamic VHDX with `qemu-img` straight onto the Windows drive, create
a Generation 2 Hyper-V VM, and find the guest IP by matching its MAC in the
host's `Get-NetNeighbor` table — because fedora-bootc ships no Hyper-V KVP
daemon, so `Get-VMNetworkAdapter` reports nothing. SSH in from Windows; WSL
cannot route to the guest.

---

## 20 July — planning and the first image

Started with `PLAN.md` rather than code: five product pillars, a milestone
ordering, and the two research findings that shaped everything — that bootc
dissolves the base-distro and update-delivery problems, and that **bootc does not
provide the snapshot feature the concept assumed**, because it rolls back `/usr`
only and leaves `/var` alone. That gap is why M2 exists as its own milestone.

Work that day:

- Toolchain: WSL2 Ubuntu, podman 5.7.0 rootful, Hyper-V, repo and remote
- **Risk spike first.** Proved btrfs subvolumes can be created at build time
  before committing to the approach. Found that only `customizations.disk`
  supports them; `customizations.filesystem` silently limits you to `/` and
  `/boot`. Validated with the builder's `manifest` subcommand, which parses a
  config without building anything — a cheap way to test a premise
- Base pinned to `fedora-bootc:44`, after digest comparison showed **tag 45 was
  byte-identical to `rawhide`**
- `Containerfile`, `disk-layout.toml`, `build.sh`
- A gitignored credentials overlay, so no password hash ever enters git history

## 21 July — rollback, provisioning, and the safety net

The heaviest day of foundational work: 16 commits.

**Project identity.** Reframed from "a customised image" to a standalone
distribution, named KotinosOS, olive-wreath logo added.

**M1 — proving rollback.** Booted the image, ran `v1 → upgrade → v2 → rollback →
v1` against a local OCI registry, with a sentinel file in `/var` checked at every
transition. Three fixes came out of inspecting the running system rather than
reasoning about it:

- `@home` was mounted nowhere — Fedora bootc symlinks `/home` to `/var/home`, so
  the subvolume was dropped
- image-baked SSH keys were unreachable, because a separate `/var` subvolume does
  not inherit the image's `/var`; the dev key moved under `/usr`
- **rollback silently did nothing** until `/boot` was pulled into
  `local-fs.target`

Result: the OS rolled back while user data persisted. The two-layer model was
real.

**M1.5 — first-boot provisioning**, an unplanned milestone created directly by
M1's `/var` finding: any user baked into the image is discarded on first boot, so
accounts must be created on the running machine. A systemd oneshot gated by a
stamp file in `/var` — deliberately in `/var` rather than using
`ConditionFirstBoot`, so that if `/var` is ever reset, provisioning correctly
runs again.

**M2 — the safety net.** snapper on `@var`, an escalation hook that pins the
deployment and snapshots before privilege is granted, and a recovery script that
lives in `/usr` and does not depend on snapper's config in `/etc`.

Then the test that defined the milestone: `rm -rf --no-preserve-root /*` on a
live machine. `/usr` and every snapshot survived; `/etc` and `/var/home` did not;
and **the machine did not come back**, because userspace cannot start without
`/etc`. That result specified the recovery environment by evidence.

Finished with unattended recovery: greenboot health-checks a boot, and a failure
drives `bootc rollback` and a reboot with no user involvement. Verified by
destroying a machine and watching it repair itself.

## 22 July — the desktop, identity, and the vault

The single biggest day: 32 commits.

**Secure Boot verified first**, because it constrains everything after it. The
image boots with Secure Boot on under the third-party CA template, inheriting
Fedora's signed chain. Lockdown disables hibernation and unsigned modules, which
became a design input for power management and GPU drivers.

**M3 — desktop and appliance UX:**

- KDE Plasma as a curated package list, not the `kde-desktop` group
- Hardware auto-tuning at boot: reads CPU, RAM, battery, disk rotational state
  and GPU, writes a fingerprint, and re-tunes only when the hardware changes
- Settings restricted via Plasma's Kiosk framework
- First-run defaults applied per user on first graphical login
- Boot splash, window behaviour, silent background updates
- `kotinos-go-back`, giving M2's restore engine a human face
- Disk housekeeping, and a plain-English "what changed" after an update

**M3.5 — identity and comfort:** one motion language, four time-of-day
wallpapers, focus mode, theme presets, and the wreath rendered into the splash.

**The vault.** The tier beneath snapshots: a separate ext4 partition that stays
unmounted, written by a service that mounts, copies and unmounts. Snapshots live
in the same filesystem as the data they protect, so `btrfs subvolume delete` — or
ransomware running as the user — destroys both at once. A partition that is not
attached cannot be encrypted or deleted.

Also that day: build-time BOM and syntax checks on every shipped script, because
a typo in one surfaces as a machine that will not boot, long after the build that
introduced it.

## 25 July — verifying the vault, and planning M4

Verification found the vault unmounted **for the wrong reason**: `systemctl mask`
had silently failed against a unit file the image builder writes, and the
partition stayed unmounted only because the mount itself had failed. Fixed by
creating the mask symlink directly, and by having the service check its own work.
Re-verified: 27 checks, no failures.

Infrastructure fix the same afternoon — builds kept hanging because WSL was
starving the host, so WSL was capped at 12 GB.

Then the M4 brief, written before any M4 code: the honesty rule stated up front,
and the adversarial test named as the centrepiece.

## 27–28 July — M4 built, then attacked

Implementation first: Flatpak with `xdg-desktop-portal`, a default-deny firewall,
kernel sysctl hardening, and SELinux asserted enforcing at build and boot.

Then the attack, which is where the milestone earned itself. Running
`tests/adversarial-user.sh` as the real account found **eight defects**, two of
which let an unprivileged user attack the safety net:

- any `wheel` user could delete every snapshot with no password — the test did it
- every file copied into `/etc` shipped world-writable, including the vault's
  config, which an ordinary user could edit to exclude their own documents

Plus: SSH never actually removed from the firewall zone, the Flathub remote that
would not survive first boot, LLMNR listening on every interface, and home
directories world-readable because `install -d` without `-m` reset the mode one
line after `useradd` set it correctly.

Fixed, rebuilt, and re-verified on a clean image: 22 of 22 adversarial boundaries
held, attack-surface audit clean, sandbox confinement 4 of 4.

**The code-quality pass** followed immediately — a read-through of every existing
script for logic that was wrong rather than untidy. Thirteen more fixes,
including a vault that logged success no matter what rsync did, a restore path
that never asked for confirmation, and an app record that listed nothing because
it could not see per-user Flatpaks.

## 3 August — M5's brief and its enforcement decision

The brief first, carrying `PLAN.md`'s standing warning as its centrepiece:
gating a settings GUI behind 2FA protects nothing if the user still has a shell.

Then the enforcement decision — PAM as the gate, `sudoers` and a polkit rule
applying it, SELinux protecting the grant — followed by *testing the decision's
own claims*, which changed it:

- **sudo skips its PAM stack for five minutes after any successful auth**, so a
  gate there would simply be absent for that window. `timestamp_timeout=0` became
  a step of its own, sequenced before the gate
- group membership genuinely cannot express a mode: removing a group does not
  revoke processes already running
- `polkit.spawn()` works on this build; `pam_exec` is available

The same day closed M4's three carried-forward items, which included discovering
that M4's assumption — that forcing the SSH domains enforcing would break login —
was untested and wrong.

## 4 August — M5 built and verified

- TOTP chosen over FIDO2 for first implementation, with the reasoning written
  down: FIDO2 is stronger but puts a hardware purchase between a user and their
  own machine, and cannot be tested in Hyper-V at all
- `kotinos-admin`: enrolment, recovery codes, the timestamped grant,
  `unlock`/`lock`/`check`
- `kotinos-escalate` finally given the caller its header had asked for since M2
- The gate placed in front of `sudo`, then in front of polkit
- A custom SELinux policy module so polkit can read the grant and nothing else
  gains anything
- Verified on `m5b`, a clean image: 28 checks, 0 failures. **A correct password
  alone returns nothing.**
- The adversarial test's second half run for the first time: 12 allowed, 2
  blocked — the honest cost of admin mode, written down rather than implied

Also that day: the discovery that `ARG BUILD_ID` at step 3 had been invalidating
the entire layer cache on every build. Moving it to the end took a rebuild from
~40 minutes to **66 cached steps and forty seconds**.

---

## What the repository looks like now

| Path | Holds |
|---|---|
| `Containerfile` | The image: 771 lines, heavily commented, ~30 build-time assertions |
| `system-scripts/` | 18 scripts installed into `/usr/libexec`, run at boot, on timers, or by the user |
| `systemd-units/` | The units that run them, each documenting why its confinement is what it is |
| `desktop-config/` | Desktop defaults, hardening drop-ins, the polkit rule, the SELinux module |
| `tests/` | Four scripts, deliberately **not** shipped in the image |
| `disk-layout.toml` | `@` and `@var` subvolumes plus the vault partition |
| `PLAN.md` / `TODO.md` / `docs/` | Architecture, milestone records, and this history |

## Conventions the project settled into

- **Write the brief before the code.** Every milestone from M2 onward began with
  its exit criteria and its failure modes written down.
- **Assert at build time.** A mistake should fail the build, not ship. Roughly
  thirty assertions now guard things that were once assumed.
- **Verify on a booted machine, then on a clean one.** Live-patching proves a
  mechanism; only a fresh image proves the product.
- **Count the checks.** Every verification reports `passed=N failed=M`, so
  "verified" means a number rather than a feeling.
- **Record what did not work.** The milestone records and the engineering log
  keep the failures, because they are the part that does not survive in a diff.
- **Explain the why in comments and commit messages.** Several bugs were found
  because a comment described behaviour the code did not have — which only works
  if the comments are there to contradict.
