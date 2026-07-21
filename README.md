<p align="center">
  <img src="./assets/kotinos-logo.png" alt="KotinosOS logo — an olive wreath" width="160">
</p>

<h1 align="center">KotinosOS</h1>

**A standalone, comfort-first Linux distribution with a native AI and an unbreakable safety net.**

> *Named for the* **kotinos** *(κότινος), the wild-olive wreath awarded to victors at the ancient Olympic Games — a symbol of excellence, wisdom, and peace rather than material reward.*

> ⚠️ **Status: early development.** KotinosOS is being built in the open and is **not yet installable**. The foundation (bootable image, atomic updates, and the data safety net) is under active work — see [the roadmap](#roadmap) and [`PLAN.md`](./PLAN.md).

---

## What it is

KotinosOS is a Linux distribution built around a single idea: **the computer should take care of itself, so the person doesn't have to.**

- **Zero-config, zero-maintenance.** The system scans the hardware at first boot and tunes itself to optimal settings with no user intervention. There is nothing to configure and nothing to keep running.
- **You can't break it.** The OS is immutable and self-healing. A bad update, a broken driver, or even a reckless command cannot leave you with a dead machine.
- **A native AI, everywhere.** A small local model turns plain English into system actions and can reach every part of the machine, available as a sidebar in any application — not an app you open, a capability that is always there.
- **Comfort by default, power on demand.** The everyday user has a clean, restricted experience and cannot accidentally damage the system. Full control — a root terminal and a complete control panel — lives behind an **offline two-factor admin mode**.

It **derives from** Fedora's architecture and reuses upstream work where it makes sense, but it is its own distribution with its own identity, defaults, filesystem experience, and direction — not a reskin.

## Core features

| Pillar | What it means |
|---|---|
| **Effortless** | Self-configuring, self-managing. The user manages nothing they shouldn't have to. |
| **Unbreakable** | Immutable OS + atomic snapshots. Roll back the whole system *or* recover user data. |
| **Native AI** | Plain-English control of the entire machine, present in every app. |
| **Restricted by default** | A sleek settings app for the essentials; no way to accidentally break core system state. |
| **Admin mode** | Offline-2FA gate to total control: rooted terminal, full control panel. |
| **Find anything** | A single search surface across all your files — by name *and* by content, understood by the AI. |

## Architecture at a glance

KotinosOS ships as an **OCI container image** built with [bootc](https://bootc.dev). The whole OS — kernel, bootloader, drivers, userspace — is one image, built and tested as a unit and delivered like a container. Updates are a registry push; installs pull and apply atomically.

**A two-layer safety net**, because the two failure modes are different:

- **bootc** protects the *operating system*. Bad update, broken driver, failed boot → atomic rollback at the bootloader. `/usr` is read-only, so system files can't be deleted.
- **Btrfs + snapper** protect the *user's data* under `/home` and `/var` — the part bootc deliberately never rolls back. This is what saves someone from their own destructive command.

On top of Btrfs sits a **semantic file layer**: a background indexer builds full-text *and* embedding indexes so files are found by content and meaning, not just location — the same local model that powers the assistant, doing double duty.

Full technical detail lives in [`PLAN.md`](./PLAN.md).

## Repository layout

| Path | Purpose |
|---|---|
| `Containerfile` | The OS image definition (pinned to `fedora-bootc:44`). |
| `config.toml` | Disk layout — Btrfs with `@`, `@home`, `@var` subvolumes. |
| `build.sh` | Builds the image and converts it to a bootable disk image. |
| `PLAN.md` | Architecture, milestones, and design decisions. |

## Building

> Development is currently on Windows + WSL2 (podman) with Hyper-V for VM testing. A Linux host works directly.

**Prerequisites:** `podman` (rootful), and the [bootc image builder](https://github.com/osbuild/image-builder).

```bash
# Build the OS image and a Hyper-V disk image (run as root):
sudo ./build.sh v1 vhd
```

`build.sh` builds the container from `Containerfile`, then runs the image builder against `config.toml` to produce a bootable disk image in `output/`. Output type is selectable (`vhd`, `qcow2`, `raw`).

## Roadmap

| | Milestone | Delivers |
|---|---|---|
| **M1** | Foundation | Bootable image, Btrfs subvolumes, rollback proven end-to-end |
| **M2** | Safety net | snapper, snapshot-on-escalation, recovery environment |
| M3 | Desktop & UX | Restricted settings app, first-boot, appliance shell |
| M4 | Sandboxing | Flatpak-only apps, hardened defaults |
| M5 | Admin mode | Offline 2FA, policy-layer enforcement |
| M6 | AI assistant | Constrained command execution + semantic file search |
| M7 | Distribution | Installer, signing, update channels |
| M8 | Hardware QA | Supported-hardware matrix, v1.0 |

*Currently: **M1**, foundation.*

## License

Not yet decided. Until a license is added, no permissions are granted beyond viewing.
