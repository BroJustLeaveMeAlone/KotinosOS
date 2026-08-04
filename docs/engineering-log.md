# Engineering log

How the work actually went, from the first commit to the present: the wrong
turns, the things that were invisible, and the assumptions that turned out to be
false.

`TODO.md` records what each milestone decided and proved. `PLAN.md` records the
architecture. This records the *process* — because the failures are worth more
than the successes and they do not survive in a diff.

**77 commits, 20 July – 4 August 2026**, M1 through M5.

---

## The pattern, stated once

One failure mode accounts for more of this project's bugs than every other cause
combined:

> **A protection that was written down, looked present, and did nothing.**

Not missing code. Code that existed, read correctly, passed review, and had no
effect. It has appeared in every single milestone:

| Milestone | What reported success | What was actually happening |
|---|---|---|
| M1 | `bootc rollback` | `/boot` was not mounted yet; two rollbacks lost before the cause was found |
| M2 | the build, enabling greenboot | unit names did not exist; errors silenced by `2>/dev/null \|\| true`; image shipped with health checking off |
| M2 | the health check | tested that `/var/home` exists, which tmpfiles recreates empty — a machine with every user file destroyed reported healthy |
| M3 | the build wrapper | ended in `echo EXIT=$?`, so a dead build reported success; a stale image was then converted, booted and verified, producing fifteen false failures |
| M3.5 | the vault being unmounted | `systemctl mask` had silently failed; the partition stayed unmounted only because the *mount* had failed too |
| M4 | the firewall build step | `--remove-service` failed on every build inside `\|\| true`; SSH was never removed from the zone |
| M4 | `kotinos-space` | read the wrong `btrfs qgroup` column, so its central explanation never printed |
| M4 | the vault backup | recorded success regardless of what rsync did |
| M5 | the sudo gate | sudo skips its PAM stack for five minutes after any successful auth |
| M5 | a guard I wrote | grepped for the wrong spelling; could never fire |

The lesson is not "write better code". It is that **reading the source cannot
find these**, because the source says what it intends. Only running the thing,
as the user who would attack it, on a machine that was really booted, finds
them.

---

## M1 — bootc foundations (20–21 July)

### A near-miss before anything was built

The base image was nearly pinned to `fedora-bootc:45` on the reasoning that the
highest tag is the newest stable. Digest comparison showed **tag 45 was
byte-identical to `rawhide`** — the development branch. Picking the obvious
number would have silently shipped a distribution built on unstable.

The risk spike also found that only `customizations.disk` supports btrfs
subvolume creation; `customizations.filesystem` silently limits you to `/` and
`/boot`. Validated cheaply with the builder's `manifest` subcommand, which parses
the config without building anything.

### `@home` was mounted nowhere

The disk layout created an `@home` subvolume. Booting and inspecting the running
system showed it mounted nowhere at all: Fedora bootc makes `/home` a symlink to
`/var/home` and `/root` a symlink to `/var/roothome`. **There is no `/home`.**
All user data lives under `/var`, so `@var` alone is what the safety net must
cover.

### The finding that shaped three later milestones

A separate `/var` subvolume **does not inherit the image's `/var`**. The seeded
copy stays at `/sysroot/ostree/deploy/default/var` while systemd-tmpfiles fills
the live `/var` with a bare skeleton. Anything baked into the image under `/var`
— user homes, SSH keys — is silently discarded on first boot.

This locked us out of our own VM twice before it was understood. It produced
M1.5 (first-boot provisioning) as an entire unplanned milestone, and it came back
in M4 as the reason the Flathub remote would not have survived a boot.

The fix for dev access was to put the key under `/usr`, which is image-managed
and cannot be shadowed by the `/var` mount.

### Rollback reported success and did nothing

The headline M1 bug. The image builder generates `boot.mount` with
`WantedBy=multi-user.target`, leaving `/boot` unmounted for roughly two minutes
after boot. bootc needs `/boot` to write bootloader state — so a rollback issued
in that window **reported success, changed nothing, and the next boot came back
on the same deployment.**

Two rollbacks were lost before the cause was found. A drop-in pulling
`boot.mount` into `local-fs.target` moved it to about five seconds.

A related trap recorded at the time: ostree does *not* rewrite
`/boot/loader/entries` on rollback — it swaps the `/ostree/boot.N` symlinks. So
unchanged timestamps are not evidence of failure, and `ostree admin status` is
the thing to read.

---

## M2 — the safety net (21 July)

### Running `rm -rf /*` instead of reasoning about it

The milestone's centrepiece was to execute `rm -rf --no-preserve-root /*` on a
live system and write down precisely what happened.

**What survived:** `/usr`, because bootc mounts it read-only. Every snapshot,
because btrfs read-only snapshots refuse deletion — `rm` failed against them with
*"Read-only file system"*.

**What did not:** `/etc` and `/var/home`.

**And the part that mattered most:** the machine did not come back after a
reboot. The kernel loads, but userspace cannot start without `/etc`. So the
honest recovery story at that moment was *the data survives and the running
system does not*. Every file was still on disk in a snapshot, and nothing running
could reach it, because the OS that would perform the restore was what got
destroyed.

That result specified the recovery environment by evidence rather than by
guesswork: it must boot without `/etc` or `/var`, run from `/usr`, and restore
both. It also surfaced a separate gap — a freshly installed system has only one
deployment, so rollback has no target on day one.

### Two safety features that were switched off

Proving unattended recovery turned up two bugs of the same shape.

The `systemctl enable` line for greenboot **silenced its own errors** with
`2>/dev/null || true` and used unit names that do not exist in greenboot 0.16.3.
The image shipped with health checking disabled and the build passed. Fixed by
using the real unit and adding a following step that asserts the safety units
are enabled, failing the build otherwise.

The health check tested that `/var/home` exists — which systemd-tmpfiles
recreates empty on every boot. **A machine that had lost every user file
reported healthy.** It now checks that the provisioned account's home exists
*and has contents*.

---

## M3 / M3.5 — desktop, identity, and the vault (22 July)

### Secure Boot worked, and constrained the design

The image boots with Secure Boot enabled under the third-party CA template,
inheriting Fedora's signed chain: `mokutil` reports it enabled, the EFI variable
is set, and dmesg logs the kernel locked down from EFI Secure Boot mode. We sign
nothing ourselves, which skips a months-long process with Microsoft and means
users are never asked to disable a security feature to install this.

The test also produced a design constraint worth having early: **lockdown
disables hibernation and refuses unsigned modules.** Power management should
target suspend, and any out-of-tree driver needs MOK enrolment. That reappeared
in M4 as the reason NVIDIA's proprietary driver is deliberately not installed.

### A dead build that reported success

A build wrapper ended in `echo EXIT=$?`, so **a build that had died reported
success**. A stale image was converted, booted and verified against, producing
*fifteen false failures* before the `BUILD_ID` baked into the image gave it away.

The same session found the boot splash had never worked — the theme needs
`plymouth-plugin-script`, which was not installed. That one was caught by an
assertion before it shipped, which is the difference between the two stories.

### The vault was unmounted for the wrong reason

The vault's entire design rests on the partition not being mounted. Verification
found it unmounted — and then found out why, which was not the reason anyone
thought.

The image builder rejects a partition without a mountpoint, so one is declared,
and the builder writes a real unit file to `/etc/systemd/system/vault.mount`.
`systemctl mask` **refuses to overwrite an existing file there**, so the mask
silently failed. The partition stayed unmounted only because the mount attempt
itself had failed.

Right outcome, wrong mechanism — which holds until the day the mount succeeds.

Masking is really a symlink to `/dev/null` at the unit path, so the seal service
now creates that symlink directly, replacing the builder's file. `/etc` outranks
`/run` and `/usr` in the unit search path, so `mask --runtime` would have been
overridden by the very file it was meant to neutralise. The service then checks
its own work and logs an error if the vault is still mounted, rather than
assuming.

A duller bug alongside it: `btrfs subvolume create` does not create intermediate
directories, so excluding `.local/share/Trash` failed on a fresh home while
`.cache` worked, because `.cache` sits directly in the home.

### The infrastructure cost an afternoon

Builds kept hanging because WSL was starving the host of memory — one 32 GB
machine running both a build and a VM test. WSL was capped at 12 GB, which
removed the contention. This came back later anyway; see below.

---

## M4 — sandboxing and hardening (25–28 July)

### An unprivileged user could delete every snapshot

`kotinos-snapshots.sh` configured snapper with `ALLOW_GROUPS=wheel` and
`SYNC_ACL=yes`, presumably so a user could see their restore points without a
password. But `ALLOW_GROUPS` is not a read-only permission — it authorises create
*and delete* over snapperd's D-Bus interface, with no polkit prompt.

The primary account is in `wheel` so it can `sudo`. So the primary user, and
anything running as them, could destroy the entire safety net with one command
and no authentication. The adversarial test did exactly that on its first run:

```
dev deleting snapshot 1:   exit=0
dev deleting snapshot 2:   exit=0
dev deleting snapshot 3:   exit=0
=== snapshots AFTER ===
0 | single | | | root | | | current |          <- nothing left
```

The project's central promise — *nothing can delete your safety net* — was false,
because of a line we wrote. It had survived since M2, **including the `rm -rf /*`
test**, which ran as root and therefore proved nothing about this.

### The world-writable file that led somewhere worse

`systemd-analyze verify` had printed a warning on every run that nobody read:
unit files were `-rwxrwxrwx`. The cause was mundane — `COPY` preserves the source
mode, and the repo lives on a Windows drvfs mount that reports 0777 for
everything.

Under `/usr` this was invisible, because bootc keeps `/usr` read-only. But three
of the eighteen affected files land in `/etc`, which is not:

```
$ su - kotinos -c 'echo COMPROMISED >> /etc/kotinos/vault.conf'
YES-WROTE-VAULT-CONF
```

`vault.conf` decides what the vault backs up. An ordinary user could append an
exclusion for their own documents, and the vault would go on reporting successful
backups of everything that no longer mattered.

The safety came from the filesystem being read-only, not from the files being
right. Those are not the same thing, and only one of them travels.

### More things that reported success while doing nothing

- **The firewall never removed SSH.** `firewall-offline-cmd --remove-service`
  collides with a legacy lokkit compatibility layer and fails when combined with
  `--zone=`. Wrapped in `|| true`, so it failed on every build while the build
  stayed green.
- **The Flathub remote would not have survived first boot** — `remote-add` writes
  into the `/var` that M1 established is discarded. The build-time check passed
  inside the container; the shipped machine would have had no app source at all.
- **`kotinos-space` never printed the one thing it exists for.** `btrfs qgroup
  show` has four columns; the loop read the fifth as `Exclusive`, so every row
  failed its numeric test and the "held by restore points" section was silently
  skipped — three lines below the comment explaining why that number matters.

That last one had a trap inside the fix: correcting the field count *alone* would
have summed `@` and `@var` too, reporting nearly the whole disk as held by
snapshots. Fixing the obvious bug would have created a worse one.

### An assumption that was never tested, and was wrong

M4 recorded that forcing `sshd_session_t` enforcing would break login, and left
it. When finally tested it did not break login at all — key auth, `scp`, `sftp`
and repeated sessions all worked with zero new denials, while the mislabelled
`authorized_keys` attack that had *succeeded* under permissive was now refused at
`permissive=0`.

"We assumed it would break" is not a finding. It is a note to test something
later.

---

## The code-quality pass (28 July)

A read-through of every existing script looking for logic that was wrong rather
than untidy. Thirteen fixes, and the shape repeated so consistently it is worth
naming: **the comment was the specification, and the code had drifted from it.**

| File | The comment said | The code did |
|---|---|---|
| `kotinos-vault.sh` | logs a successful backup | recorded success unconditionally, discarding rsync's exit status |
| `kotinos-go-back.sh` | "adds vocabulary and confirmation" | never prompted at all, then ran `rsync --delete` over every home |
| `kotinos-wallpaper.sh` | "the first manual change opts out permanently" | only opted out via *our* tool, so the timer overwrote real choices |
| `kotinos-focus.sh` | "restores exactly what it changed" | restored one of three, and unmuted people who were already muted |
| `kotinos-apps.sh` | "these are copied" | copied nothing, and `~/.local/bin` was not in the vault's list |

`kotinos-apps` was quietly the most consequential. It runs as root from the vault
timer, and root's `flatpak list` sees only the system installation — but apps
install per-user, which is the whole point of the M4 sandbox model. So the record
that exists *"so a restored machine can be rebuilt"* listed nothing, and said
`(none yet)` while doing it. **A record that is empty is worse than no record,
because it is believed.**

`kotinos-whats-changed` would also have been backwards after a rollback: it
picked the running deployment by directory mtime, which is true right up until
someone rolls back — at which point the booted deployment is the *older* one.
Being wrong exactly when the headline feature is used is worse than being absent.

---

## M5 — admin mode (3–4 August)

### sudo skips the gate entirely by default

A gate in `/etc/pam.d/sudo` lives in the auth stack, and **sudo does not run that
stack while a cached authentication is valid** — five minutes by default. So
unlock, relock, and a `sudo` within five minutes still gets root while the
machine reports itself locked.

```
default sudoers      second sudo succeeded WITHOUT authenticating   stack ran 1x
timestamp_timeout=0  second sudo refused                            stack ran 1x
```

The hole arrived through an upstream default, not through anything we wrote.
Those are the ones that survive review, because there is no line to review.

My first attempt to measure it was itself wrong: `sudo -n` with no valid ticket
exits *before* the auth stack, and each `su -` gets its own ticket, so "0 stack
runs" looked like a bypass when it was nothing of the sort. The result only
became meaningful once both calls shared a session.

### `seteuid`, and a message that reads like a malfunction

`pam_exec` runs its helper as the **invoking user** unless told `seteuid`. The
grant was `0600 root:root`, so the helper could not read it, so the gate refused
everything — including valid grants.

It presented as a PAM bug, because sudo renders *any* failed auth module as:

```
sudo: PAM authentication error: Unknown error -1
```

That message is not an error. `pam_exec /bin/false` produces it identically,
because the message **is** the refusal. Isolated by running the same stack
against `/bin/true` and `/bin/false` until it stopped being mysterious.

### The failure with no error anywhere

The polkit half returned nothing useful and logged nothing — not in the journal,
not in `ausearch`. `polkit.spawn` of `/bin/true` worked; spawning the grant
checker did not. The denial only appeared after `semodule -DB`:

```
avc: denied { read } comm="bash" name="admin-grant"
  scontext=...:policykit_t  tcontext=...:var_run_t  permissive=0
```

A `dontaudit` rule had been suppressing it. When something fails with no error at
all, suspect the error is being hidden rather than absent.

### A guard that could not fire

After building the "privilege gate preconditions" check, I broke each thing it
guards to confirm it noticed. Two of three fired. The third — a polkit rule using
`auth_admin_keep` — did not, because I had grepped for the spelling used in
`.policy` XML while `rules.d` JavaScript spells it `AUTH_ADMIN_KEEP`.

A case-sensitive match that would never have fired on the files the check exists
to read. Written twenty minutes earlier, by me, in the same session as several
findings about checks that verify nothing.

### The honest cost, written down

The adversarial test's second half runs *with* admin mode open: **12 allowed, 2
blocked**. Admin mode grants root, so deleting snapshots, reaching the vault and
stopping the safety services all succeed — as they must. Only writing into `/usr`
resists, because bootc keeps the running deployment read-only.

Two results are recorded as uncomfortable rather than glossed: the TOTP secret is
readable once admin mode is open, so one compromised session can mint second
factors indefinitely; and admin mode can extend its own grant and edit its own
gate, so expiry bounds forgetfulness rather than an adversary already inside.

---

## Environment and tooling

Not about the OS, but it cost real time across the whole project.

- **Every build was rebuilding everything.** `ARG BUILD_ID` was consumed at step
  3, and an `ARG` invalidates the layer cache from its use onward — so changing
  the tag discarded all seventy-odd steps including a several-hundred-package
  desktop install. Measured at **one cached step out of seventy-three**. Moving
  the stamp to the end took the next build to **66 cached steps, step 77 of 80 in
  forty seconds**.
- **The WSL build dies silently under memory pressure.** First hit in M3.5
  (capped WSL at 12 GB), and again in M4/M5 — twice at the same
  `install-to-filesystem` stage, with no error and no OOM record. Launch with
  `setsid nohup` so it outlives the invoking shell, and poll the log rather than
  holding a connection open.
- **PowerShell mangles `|` and `$` inside arguments passed to `wsl`**, producing
  errors that look like bugs in the remote script. Write the script to a file,
  copy it in, strip CRs, then run it.
- **`/usr` is read-only on bootc**, so `dnf install` at runtime silently fails and
  testing proceeds against software that was never installed. `bootc usr-overlay`
  gives a transient writable `/usr` for exactly this.
- **Windows drvfs reports every file as 0777**, which is how eighteen
  world-writable files reached the image.

---

## What I would tell the next person

1. **Run it as the user who would attack you.** Every serious finding here came
   from executing something as an unprivileged account on a booted machine, not
   from reading code. The `rm -rf /*` test ran as root and therefore missed the
   worst bug in the project for six days.
2. **Assertions are the product.** Half these defects were found by adding a
   check to something previously assumed — and several *were* assertions that
   could not fail, which is worse than none.
3. **When a check passes, make it fail on purpose.** Twice a guard reported "ok"
   while verifying nothing.
4. **Suspect the comment.** The most reliable single signal of a defect was a
   confident comment describing behaviour the code did not have.
5. **Silence is a symptom.** The two hardest bugs presented as *nothing
   happening*: a suppressed SELinux denial, and a PAM message that reads like a
   crash.
6. **Verify the thing you shipped, not the thing you patched.** Live-patched
   fixes proved mechanisms; only a clean image build proved the product. Several
   findings — the empty app record, the missing `users.oath` — were only visible
   on a machine nobody had touched.
