# Building an Appliance-Grade Linux Distribution

## Working mode

Division of labor:

- **Claude sets up** environment, toolchain, and infrastructure — WSL, podman, Hyper-V, CI wiring.
- **You author the project code** — `Containerfile`, disk config, build scripts — with review and technical input.

**Repository:** https://github.com/BroJustLeaveMeAlone/Distro

---

## Context

The goal is a shippable Linux distribution — one strangers install and rely on — built around five product pillars: zero-config setup, a native AI assistant with constrained root access, a 2FA-gated advanced mode, an atomic snapshot/recovery safety net, and hardened sandboxing by default.

The original concept described this as "building an OS." It isn't, in the kernel sense — every pillar lives in userspace and packaging. That reframe is what makes it achievable solo.

Two research findings shaped the architecture:

1. **bootc dissolves the base-distro question and solves update delivery.** The entire OS ships as an OCI container image built from a `Containerfile`. Updates become `podman push`. Shipping updates to machines you can't see is what kills hobby distros; this removes that problem. bootc is CNCF-incubating with a stable CLI/API, and SteamOS uses it.

2. **bootc does *not* provide the described snapshot feature.** It rolls back `/usr` only. `/var` is deliberately shared across deployments and `/home` is untouched — so `rm -rf /*` on a pure bootc system leaves a working OS with the user's data gone. The safety net therefore needs a second, independent layer.

**Constraint: solo developer.** The governing strategy is *assemble, don't author*. Bazzite and Bluefin began as one person layering opinions onto Fedora through a Containerfile. Anywhere this plan can inherit upstream behavior instead of building it, it must.

**Development environment:** Windows 10 Pro. Builds run in WSL2; VM testing runs in Hyper-V, because Windows 10 gives WSL2 no nested virtualization and KVM is unavailable.

---

## Architecture

| Layer | Choice | Rationale |
|---|---|---|
| Base | Fedora (`quay.io/fedora/fedora-bootc`) | Only base with official supported bootc images; newest kernels serve the zero-config hardware goal |
| OS delivery | bootc / OCI image | Atomic updates + bootloader rollback inherited, not built |
| OS rollback | bootc deployments | Covers `/usr`, `/opt` |
| Data rollback | Btrfs + snapper | Covers `/home`, `/var` — what bootc won't do |
| Escalation hook | Custom | Pin deployment + snapshot user data before granting god mode |
| AI model | Provider interface, unbound | Policy engine is the hard part regardless of model |

**Two-layer safety net.** These are independent mechanisms with different jobs. bootc protects against bad updates, broken drivers, and panics. Btrfs/snapper protects the user from their own destructive commands. The escalation hook fires both, and is the genuinely novel piece — nobody ships snapshot-on-privilege-escalation.

---

## Environment status

Surveyed on this machine (Windows 10 Pro, build 19045):

| Component | Status |
|---|---|
| WSL2 | Installed, default distro **Ubuntu 26.04 LTS**, kernel 6.18.33.2 |
| Hyper-V | **Enabled** — `vmms` running, PS module present |
| git (in WSL) | 2.53.0 |
| Disk free (WSL) | 952 GB |
| Docker Desktop | Installed, `docker-desktop` distro running |
| podman | **Not installed** — required |
| sudo in WSL | Requires password (blocks unattended installs) |

---

## Milestone 1 — Foundation

**Exit criteria:** A custom Fedora bootc image boots in Hyper-V with `/home` and `/var` on their own Btrfs subvolumes. Build v1 → v2, `bootc upgrade`, `bootc rollback`, and verify user data in `/home` survived both transitions.

Nothing else gets built until this is real.

### Step 0 — Toolchain

- WSL2 Ubuntu 26.04 with `podman`, running **rootful** — `bootc-image-builder` requires privileged containers.
- Repo lives at `C:\dev\OS` for editing. Builds run in WSL. If podman builds from `/mnt/c` hit file-ownership or performance problems, mirror to a WSL-native path (`~/dev/OS`) and treat `C:\dev\OS` as the editing copy.
- Hyper-V VMs must be **Generation 2** (UEFI — bootc requires it) with **Secure Boot disabled**, since the image is unsigned until milestone 7.

### Step 1 — Risk spike (do this before anything else)

Research flagged one genuine unknown: bootc-image-builder cannot create Btrfs subvolumes through standard filesystem customizations, and when `rootfs` is btrfs only `/` and `/boot` are configurable. Subvolume support exists only via the newer *disk customizations* path.

The entire second safety layer depends on this. Prove it before building on it.

Attempt, in order:
1. **Disk customizations** with explicit Btrfs subvolumes for `/home` and `/var`.
2. **First-boot subvolume creation** — ship a `systemd` unit that creates and mounts the subvolumes on initial boot rather than at build time. Most likely fallback if (1) fails.
3. **Separate partitions** instead of subvolumes. Works, but loses cheap CoW snapshots — a real downgrade, and worth reconsidering the approach if you land here.

Record which path worked; it constrains milestone 2.

### Step 2 — Repo skeleton

```
Containerfile          # the OS itself
disk-config.toml       # partition/subvolume layout for image builder
build.sh               # build container -> disk image
Justfile               # task runner
.github/workflows/     # CI (defer until step 6 passes locally)
```

### Step 3 — Minimal image

`Containerfile` starting from `quay.io/fedora/fedora-bootc` — **pin an explicit tag**, don't use `:latest`; verify the current release at build time. Add a single marker file so you can prove which version booted. Nothing else yet.

### Step 4 — Disk image

Run `bootc-image-builder` (`quay.io/centos-bootc/bootc-image-builder`) with `--rootfs btrfs` and the layout from step 1. Output **`vhd`** for Hyper-V. Avoid `anaconda-iso` for now — ISO builds pull RPMs and won't work offline.

### Step 5 — Boot

Boot the VHD in a Gen2 Hyper-V VM. Confirm the marker file, and confirm `/home` and `/var` are on the expected subvolumes (`btrfs subvolume list /`).

### Step 6 — Prove rollback

The milestone actually turns on this step:

1. Write a sentinel file into `/home` from inside the running VM.
2. Build v2 with a changed marker, push to a registry (or use a local one).
3. `bootc upgrade`, reboot, confirm v2 booted.
4. `bootc rollback`, reboot, confirm v1 booted.
5. **Confirm the `/home` sentinel survived every step.** If it didn't, the two-layer model is broken and milestone 2 cannot proceed.

---

## Milestone 2 — Complete the safety net

Delivers pillar 4 and the project's most defensible idea.

- `snapper` configured on the `/home` and `/var` subvolumes, with retention policy and disk-budget limits.
- **Escalation hook:** before god mode is granted, pin the current bootc deployment against garbage collection *and* fire a snapper snapshot. Roughly 200 lines of glue over two solved substrates.
- **Recovery environment:** reachable from the bootloader when boot fails. Offers deployment rollback and snapshot restore. Verify against a deliberately corrupted system.
- Adversarial test: run `rm -rf /*` in a VM and document precisely what survives. That output is your honest recovery story — write it down rather than assuming it.

---

## Milestone 3 onward — Provisional

> Detail below is planned against assumptions milestone 1 will test. Treat ordering as firm and specifics as revisable.

**M3 — Desktop and appliance UX (pillar 1).** Desktop environment still undecided; KDE Plasma is the likely answer since the AI sidebar needs to dock over arbitrary windows and Plasma's scripting makes that tractable where GNOME's extension API is restrictive and breaks between releases. Includes the restricted settings app, first-boot flow, and browser/search selection at install. Note: Chrome cannot be bundled in a redistributable image for licensing reasons — ship Chromium or Firefox, fetch Chrome post-install.

**M4 — Sandboxing and hardening (pillar 5).** Flatpak-only application model, SELinux enforcing, `bubblewrap` for system services. Make the write-protection of backup and recovery storage concrete and testable.

**M5 — God mode and 2FA (pillar 3).** Offline TOTP or FIDO2, no network dependency. **Must resolve the threat-model gap first:** gating a settings *GUI* behind 2FA protects nothing if the user already has a shell. Enforcement has to live at the policy layer — a `polkit` agent or LSM — or it's theater. Decide this before writing UI.

**M6 — AI assistant (pillar 2).** The research problem, and the actual product. Build the **policy engine first** — allowlisted verbs, typed arguments, mandatory dry-run with diff preview, tiered confirmation, full audit log. "Root access but constrained" must become a real capability system; an LLM asked politely to behave is not a security boundary. The sidebar UI comes last. **This is testable on plain Fedora with no image involved, so it can progress in parallel with any earlier milestone** — useful when a build is blocked.

**M7 — Distribution infrastructure.** Installer ISO (`anaconda-iso`), image signing, Secure Boot enrollment, container registry hosting, release channels (stable/beta), update cadence. The step where "my project" becomes "other people's computers."

**M8 — Hardware QA and v1.0.** Define supported hardware targets and test matrix. Solo-realistic scope: name a small set of known-good machines rather than claiming broad support.

---

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Btrfs subvolumes unsupported at build time | Blocks the whole data-rollback layer | Milestone 1 step 1 spike, with two fallbacks identified |
| AI policy engine is genuinely hard | Pillar 2 is the differentiator | Isolate it — testable on plain Fedora, independent of the image |
| Solo maintainer bandwidth | Distro death by attrition | Inherit from Fedora aggressively; author only what's differentiating |
| Unsigned images / Secure Boot | Users must disable Secure Boot | Acceptable pre-1.0; M7 addresses it |
| Fedora upstream churn | Breakage between releases | Pin tags explicitly, test upgrades in CI |

---

## Verification

Milestone 1 is complete when, from a clean checkout:

1. `just build` produces a bootable VHD without manual intervention.
2. The VHD boots in a Gen2 Hyper-V VM.
3. `btrfs subvolume list /` shows `/home` and `/var` as separate subvolumes.
4. The full v1 → upgrade → v2 → rollback → v1 cycle completes across reboots.
5. A sentinel file written to `/home` survives that entire cycle.

Step 5 is the one that matters. It is the empirical proof that the two-layer safety net is real rather than assumed.
