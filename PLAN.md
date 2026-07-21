# KotinosOS — Project Plan

*A standalone, comfort-first Linux distribution with a native AI and an unbreakable safety net.*
*Named for the* kotinos*, the olive wreath awarded to victors at the ancient Olympic Games — a symbol of excellence, wisdom, and peace rather than wealth.*

## Identity & philosophy

A **standalone distribution** with its own identity, defaults, filesystem experience, privilege model, and governance. It *derives from* Fedora's architecture and reuses Fedora code where useful, but it is not a reskin of Fedora. Trajectory chosen: **derive now, diverge over time** — seed the base from `fedora-bootc`, own everything above it from day one, and replace base pieces as the project grows. Every standalone distro starts by deriving; the `FROM` line is a seed, not an identity.

**Governing value: user comfort.** Zero-config, zero resource management. The machine tunes itself; the user manages nothing they shouldn't have to.

**Privilege model:** the ordinary user has almost no privileges and *cannot* break the system. A clean, restricted Settings app covers networks, Bluetooth, display + dark/light, personalization, and basic privacy — nothing that can brick the machine. Full control (rooted terminal, complete control panel) lives behind **offline-2FA admin mode**.

**The AI is the power tool.** A small local model turns plain English into system commands and executes them, available as a sidebar in every application, able to touch every part of the machine. Because the ordinary user is near-powerless, **the AI becomes the primary privilege-escalation surface** — the policy engine constraining it (M6) is therefore the true security boundary, not an add-on.

---



## Working mode

Division of labor:

- **Claude sets up** environment, toolchain, and infrastructure — WSL, podman, Hyper-V, CI wiring.
- **You author the project code** — `Containerfile`, disk config, build scripts — with review and technical input.

**Repository:** https://github.com/BroJustLeaveMeAlone/KotinosOS

---

## Context

The goal is a shippable Linux distribution — one strangers install and rely on — built around five product pillars: zero-config setup, a native AI assistant with constrained root access, a 2FA-gated advanced mode, an atomic snapshot/recovery safety net, and hardened sandboxing by default.

The original concept described this as "building an OS." It isn't, in the kernel sense — every pillar lives in userspace and packaging. That reframe is what makes it achievable solo.

Two research findings shaped the architecture:

1. **bootc dissolves the base-distro question and solves update delivery.** The entire OS ships as an OCI container image built from a `Containerfile`. Updates become `podman push`. Shipping updates to machines you can't see is what kills hobby distros; this removes that problem. bootc is CNCF-incubating with a stable CLI/API, and SteamOS uses it.

2. **bootc does *not* provide the described snapshot feature.** It rolls back `/usr` only. `/var` is deliberately shared across deployments and `/home` is untouched — so `rm -rf /*` on a pure bootc system leaves a working OS with the user's data gone. The safety net therefore needs a second, independent layer.

**Constraint: solo developer.** At the *base*, the strategy is *inherit, don't reinvent* — derive from Fedora rather than rebuild coreutils/kernel packaging. Divergence and ownership go into the layers above the base (filesystem experience, privilege model, settings, AI, branding, repos), which is where the product actually lives. From-scratch (Yocto/LFS) and immediate source-rebuild were both considered and rejected as non-viable solo.

**The "different filesystem" is a semantic file layer, not a kernel FS.** The disk stays btrfs. Above it, a background indexer builds a full-text index *and* a semantic (embedding) index of file contents, and the shell presents a single location-independent search surface — "find files anywhere, by content, using what the AI understands about them." This is an application/service layer spanning the AI (M6) and shell UX (M3), not a change to on-disk format. Precedents for location-independent search are mature (Spotlight, GNOME Tracker); the semantic half is the local model doing double duty. Constraints to respect: indexing is a CPU/disk cost (index on idle, be selective — it tensions with "zero resource management") and a content index is highly sensitive (must stay encrypted, sandboxed, on-device).

**Development environment:** Windows 10 Pro. Builds run in WSL2; VM testing runs in Hyper-V, because Windows 10 gives WSL2 no nested virtualization and KVM is unavailable.

---

## Architecture

| Layer | Choice | Rationale |
|---|---|---|
| Base (seed) | `quay.io/fedora/fedora-bootc:44` | Derivation seed, not identity. Only base with official supported bootc images; newest kernels serve the zero-config hardware goal. Replaced piecewise as the distro diverges. |
| File experience | Semantic file layer over btrfs | Location-independent + content/embedding search as a single surface; the AI's second job |
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

The entire second safety layer depends on Btrfs subvolumes for `/home` and `/var`. Research narrowed the risk considerably — there are **two different customization paths and only one works**:

| Path | Btrfs subvolumes | Notes |
|---|---|---|
| `customizations.filesystem` | **No** | With btrfs rootfs, only `/` and `/boot` configurable. This is the "not supported" stated throughout the docs. |
| `customizations.disk.partitions` | **Yes** | Build-time subvolume creation supported. Use this. |

Working schema shape:

```toml
[[customizations.disk.partitions]]
type = "btrfs"
minsize = "20 GiB"

[[customizations.disk.partitions.subvolumes]]
name = "root"
mountpoint = "/"

[[customizations.disk.partitions.subvolumes]]
name = "home"
mountpoint = "/home"
```

### Validation results (20 Jul 2026)

Schema validated against `bootc-image-builder` using the `manifest` subcommand, which parses config and emits an osbuild manifest without running a build — a fast feedback loop for layout changes.

**Result: accepted, exit 0.** The generated manifest contains:

- An `org.osbuild.btrfs.subvol` stage creating `/@`, `/@home`, `/@var` — **build-time subvolume creation confirmed working.**
- systemd mount units with correct subvolume options:
  | Unit | Where | Options |
  |---|---|---|
  | `-.mount` | `/` | `subvol=@` |
  | `home.mount` | `/home` | `subvol=@home` |
  | `var.mount` | `/var` | `subvol=@var` |
- A GPT table the builder generated **automatically** — BIOS boot (1 MiB), ESP (200 MiB), `/boot` as xfs (1 GiB), and the btrfs volume (~20 GiB).

**Answered:** the ESP and `/boot` do **not** need explicit declaration. The builder supplies the whole boot chain even when `customizations.disk` takes manual control.

### Runtime results (21 Jul 2026) — booted and verified

The image boots in Hyper-V and was inspected over SSH. Runtime layout:

| Subvolume | ID | Mounted at | Verdict |
|---|---|---|---|
| `@` | 256 | `/sysroot`, and `/` via composefs overlay (read-only) | works |
| `@var` | 258 | `/var` | works — the snapshottable data volume |
| `@home` | 257 | **nothing** | created but never mounted — **removed from config** |

**Two findings that reshape the safety-net design:**

**1. There is no `/home`.** Fedora bootc ships `/home` as a symlink to `/var/home`, and `/root` as a symlink to `/var/roothome`. A subvolume mounted at `/home` is inert. *All* user data — including root's — lives under `/var`. So the data safety net consolidates onto `@var`; `@home` was dead weight.

**2. A separate `/var` subvolume does not inherit the image's `/var`.** The image's seeded var stays at `/sysroot/ostree/deploy/default/var` while the live `/var` is the `@var` subvolume, which `systemd-tmpfiles` fills with a bare skeleton. Verified: `/var/roothome/.ssh` exists but is empty, `/var/home` is empty, and no `authorized_keys` exists anywhere under `/var` — yet `getent passwd dev` resolves, because `/etc` is image-managed.

> **Consequence:** anything baked into the image under `/var` is silently discarded. **Users, SSH keys, and any seeded state must be provisioned at first boot**, not at build time. This cost two rebuild cycles to discover and would have been far more expensive to find later.

**Corollary for development access:** inject debug SSH keys under `/usr` (image-managed, never shadowed) rather than via `[[customizations.user]]`, whose keys land under `/var`. `Containerfile` takes a `DEV_SSH_KEY` build arg that writes to `/usr/share/kotinos/ssh/` plus an sshd drop-in; `build.sh` supplies it from `dev-credentials.toml` when present. Release builds pass nothing.

**3. `/boot` mounts far too late, which silently breaks rollback.** The image builder generates `boot.mount` with `WantedBy=multi-user.target`, so `/boot` appeared roughly **two minutes** after boot. `bootc` needs `/boot` to write bootloader state; run `bootc rollback` before it mounts and the command reports *"Next boot: rollback deployment"*, changes nothing, and the next boot returns to the same deployment. Two rollbacks were lost this way before the cause was found.

> **Fix, now in `Containerfile`:** a drop-in pulling `boot.mount` into `local-fs.target`. `/boot` now mounts ~5 s after boot instead of ~2 min, and rollback takes effect.

**Diagnostic note:** ostree does *not* rewrite `/boot/loader/entries` on rollback — it swaps the `/ostree/boot.N` symlink farm, so entry timestamps stay unchanged. Unchanged timestamps are **not** evidence of a failed rollback; check `ostree admin status` instead.

### Step 6 result — rollback proven end-to-end ✅

Full cycle executed against a local registry (`registry:2` in WSL, reached by the guest through a `netsh portproxy` on the NAT gateway):

| Stage | Booted | Digest | Sentinel in `/var` |
|---|---|---|---|
| v1 (initial) | `BUILD_ID=v1` | `c44709f0…` | written |
| after `bootc upgrade` | `BUILD_ID=v2` | `a79e87c5…` | survived |
| after `bootc rollback` | `BUILD_ID=v1` | `c44709f0…` | survived |

`/var` remained on `subvol=@var` throughout. **The two-layer model is empirically real: the OS rolled back while user data persisted.**

### Repo-local gotcha

`/tmp` in this WSL distro is **tmpfs and gets cleared without a reboot** — a spike artifact vanished mid-session. Keep build artifacts and scratch configs under a persistent path, not `/tmp`.

### Step 2 — Repo skeleton

```
Containerfile          # the OS itself
disk-config.toml       # partition/subvolume layout for image builder
build.sh               # build container -> disk image
Justfile               # task runner
.github/workflows/     # CI (defer until step 6 passes locally)
```

### Step 3 — Minimal image

`Containerfile` starting from **`quay.io/fedora/fedora-bootc:44`**. Add a single marker file so you can prove which version booted. Nothing else yet.

**Tag pinning (verified by manifest digest, 20 Jul 2026):**

| Tag | Resolves to |
|---|---|
| `45`, `rawhide` | **Same digest — 45 is the development branch, not a release** |
| `latest`, `44` | Same digest — Fedora 44 is current stable |
| `43` | Previous stable |

Pin `44` explicitly. Never use `:latest` (it moves under you at release boundaries) and never assume the highest number is stable — here it silently lands you on rawhide. Re-verify digests when bumping releases.

### Step 4 — Disk image

Run the image builder with `--rootfs btrfs` and the layout from step 1. Output **`vhd`** for Hyper-V. Avoid `anaconda-iso` for now — ISO builds pull RPMs and won't work offline.

> **Tooling note:** `osbuild/bootc-image-builder` was **archived 18 June 2026** and merged into [`osbuild/image-builder`](https://github.com/osbuild/image-builder). The `quay.io/centos-bootc/bootc-image-builder:latest` container still works during transition, but track the new repo for the successor image and any schema changes.

Invocation requires a privileged container and the host container store:

```bash
sudo podman run --rm -it --privileged --pull=newer \
  --security-opt label=type:unconfined_t \
  -v ./config.toml:/config.toml:ro \
  -v ./output:/output \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type vhd --rootfs btrfs \
  <your-image-ref>
```

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

## Milestone 1.5 — First-boot provisioning

Added after M1, which proved it necessary rather than optional.

Because a separate `/var` subvolume does not inherit the image's `/var`, and
because every home lives under `/var`, **accounts cannot be baked into the
image** — they are discarded at first boot. Provisioning must run on the
booted machine.

This blocks M2: snapper, the escalation hook, and admin mode all assume a real
account exists with data in a snapshottable location.

**Exit criteria:** a fresh image boots to a working account whose home is on
`@var`, created at first boot, surviving an upgrade and a rollback.

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

**Hardware auto-tuning (pillar 1, inside M3).** "Zero-config" was stated as a
goal throughout but never as a mechanism, which left the most-promised feature
the least specified. A profiler runs at first boot, detects CPU, GPU, storage
type, RAM, battery presence, display and network adapter, and writes tuned
settings for each — governor, I/O scheduler, swappiness, power profile,
refresh rate and scaling. It re-runs when the hardware changes rather than only
once, logs *why* each choice was made so the machine can be questioned, stays
conservative when unsure, and leaves every value overridable in admin mode.
Auto-tuning is a default, never a lock.

**M3 — Desktop and appliance UX (pillar 1).** Desktop environment still undecided; KDE Plasma is the likely answer since the AI sidebar needs to dock over arbitrary windows and Plasma's scripting makes that tractable where GNOME's extension API is restrictive and breaks between releases. Includes the restricted settings app, first-boot flow, and browser/search selection at install. Note: Chrome cannot be bundled in a redistributable image for licensing reasons — ship Chromium or Firefox, fetch Chrome post-install.

**M3.5 — Identity and comfort.** Added after M2, once it was clear the roadmap
described plumbing but never the thing that makes KotinosOS *itself*. Boot
splash, own icon/cursor/sound themes, system-wide accent colour, scheduled
light/dark, curated presets instead of infinite knobs.

Two decisions worth stating here. **Motion is spring physics, not fixed-duration
easing** — that is what makes macOS feel fluid, and it is public technique
(Apple's protected material is assets and code, not the approach). It only works
if the compositor never drops frames, so frame pacing is a prerequisite, not a
polish item. **Windows coexist rather than stack**: clicking one must never hide
another, which points at a tiling/mosaic layout with focus change that does not
raise over other windows. Both serve the same principle — the user should never
be doing housekeeping the machine could do.
Plus the comfort features that remove work from the user: a friendly face on the
M2 snapshot restore ("go back to yesterday"), silent background updates, a
plain-English "what changed" after an update, and auto-cleanup with a visible
budget so nobody meets "disk full". Kept separate from M3 because polish sharing
a milestone with plumbing is polish that gets cut.

**M4 — Sandboxing and hardening (pillar 5).** Flatpak-only application model, SELinux enforcing, `bubblewrap` for system services. Make the write-protection of backup and recovery storage concrete and testable.

**M5 — God mode and 2FA (pillar 3).** Offline TOTP or FIDO2, no network dependency. **Must resolve the threat-model gap first:** gating a settings *GUI* behind 2FA protects nothing if the user already has a shell. Enforcement has to live at the policy layer — a `polkit` agent or LSM — or it's theater. Decide this before writing UI.

**M6 — AI assistant (pillar 2).** The research problem, and the actual product. Build the **policy engine first** — allowlisted verbs, typed arguments, mandatory dry-run with diff preview, tiered confirmation, full audit log. "Root access but constrained" must become a real capability system; an LLM asked politely to behave is not a security boundary. Because the ordinary user is near-powerless by design, the AI is the main escalation path — so this engine is *the* security boundary of the whole product. The sidebar UI comes last. **This is testable on plain Fedora with no image involved, so it can progress in parallel with any earlier milestone** — useful when a build is blocked.

**M6b — Semantic file layer (the "different filesystem").** Background indexer building full-text + embedding indexes of file contents; a single location-independent search surface in the shell (M3), content-aware via the local model (M6). Index on idle to honor the zero-resource-management promise; keep the index encrypted and on-device. Shares the model and infrastructure with M6, so it follows naturally from it.

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
