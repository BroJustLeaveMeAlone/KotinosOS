# Tests

Scripts that attack and audit a booted KotinosOS machine.

These are **not** installed into the image. Copy them to a test VM and run them
there. Shipping an attack script into `/usr` on every release machine would be a
convenience for an attacker and nothing else.

## Why these exist

This project's rule is that a claim which has not been tested does not count.
The security claims are the easiest ones in the whole system to believe without
checking — apps launch, nothing visibly breaks, and a misconfiguration can
survive for months behind a green build. Every script here exists to turn one
specific claim into evidence, or to fail loudly.

That rule has already earned its keep. On 27 Jul 2026 these scripts, plus two
build-time assertions, found seven defects in code that looked finished:

| Found | What it was |
|---|---|
| `adversarial-user.sh` | Any user in `wheel` — which the primary account is — could delete **every snapshot on the machine** with no password. The test did it: three snapshots created, three destroyed, exit 0 each time |
| `adversarial-user.sh` | Home directories were `0755`, so any local account could read another's files |
| `sandbox-confinement.sh` | The app model was unreachable: per-user installs had no remote, system installs were refused by polkit. A user could not install anything |
| `attack-surface.sh` | LLMNR listening on `0.0.0.0:5355`, a credential-theft vector with no use here |
| `systemd-analyze verify` | Every unit file shipped `-rwxrwxrwx` — world-writable root service definitions |
| build assertion | SSH had never been removed from the firewall's default zone, on any build |
| build assertion | The Flathub remote would not have survived first boot |

The pattern is the same every time: a protection that was written down, looked
present, and was not there. None of them would have been found by reading the
code, because the code says what it intends.

## The scripts

| Script | Claim it tests | Needs |
|---|---|---|
| `adversarial-user.sh` | A hostile process at the ordinary user's privilege cannot delete the snapshots, reach the vault, read another user's data, or switch off the safety services. | Booted VM, ordinary user |
| `adversarial-admin.sh` | The honest cost of admin mode: what an attacker can do *once it is open*, and the few things that still resist. | Booted VM, ordinary user, admin mode unlocked |
| `attack-surface.sh` | Nothing is setuid or listening that has not been justified in writing, and the privilege gate's preconditions still hold. | Booted VM (the setuid section also runs against the container image) |
| `sandbox-confinement.sh` | A Flatpak without filesystem permission cannot read `~/.ssh` or `Documents`, and can once granted. | Booted VM, ordinary user, network on first run |

The two adversarial scripts are a pair and should be read that way.
`adversarial-user.sh` is mostly a list of things that fail, and its answer is 20
of 20. `adversarial-admin.sh` is mostly a list of things that **succeed**,
because admin mode grants root and that is what it is for. A security model that
only publishes its wins is marketing, so the second half exists to state the
price of the first half's boundary in the same detail.

## Running them

Copy to the VM and run as the ordinary user — **not** as root. As root every
probe in the adversarial test succeeds by design and proves nothing, which is
why that script refuses to run as root at all.

```bash
scp tests/*.sh dev@<vm>:~/
ssh dev@<vm>
./adversarial-user.sh
./attack-surface.sh
./sandbox-confinement.sh
```

`attack-surface.sh` can also be pointed at the container image, where the setuid
audit is meaningful but the firewall, SELinux and listening-socket sections are
not — it detects this and skips them rather than reporting three alarming
findings that are only artefacts of not having booted:

```bash
podman run --rm -v ./tests/attack-surface.sh:/as.sh:ro localhost/kotinos:TAG /as.sh
```

## Reading the results

`ALLOWED` is not automatically a failure. A user is supposed to be able to
encrypt and delete their own documents, and an OS that prevented it would be
broken rather than secure. The adversarial test deliberately probes two things
that are *expected* to succeed, because the claim this project makes is not that
ransomware cannot run — it is that the damage stays recoverable, since the
snapshots and the vault copy survive it.

What matters is that everything allowed is something that was decided, and that
the recovery path still exists afterwards.

If something comes out the wrong way, record it as it is. A documented hole is
worth considerably more than a green run that was quietly adjusted until it
passed.
