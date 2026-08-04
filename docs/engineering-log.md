# Engineering log

A record of how the work actually went — the wrong turns, the things that were
invisible, and the assumptions that turned out to be false. `TODO.md` records
*what* each milestone decided and proved. This records *how* it went, because
the failures are worth more than the successes and they do not survive in a
diff.

One theme runs through all of it, and it is worth stating at the top because it
predicts most of what follows:

> **Nearly every defect found here was a protection that had been written down,
> looked present, and was not there.** Not missing code — code that existed,
> read correctly, and did nothing. None of them would have been found by reading
> the source, because the source says what it intends.

---

## M4 — Sandboxing and hardening

### The one that mattered: an unprivileged user could delete every snapshot

`kotinos-snapshots.sh` configured snapper with `ALLOW_GROUPS=wheel` and
`SYNC_ACL=yes`, presumably so a user could see their restore points without a
password. But `ALLOW_GROUPS` is not a read-only permission — it authorises
create *and delete* over snapperd's D-Bus interface, with no polkit prompt.

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

The project's central promise — *nothing can delete your safety net* — was
false, because of a line we wrote. It had survived since M2, including the
`rm -rf /*` test, which ran as root and therefore proved nothing about this.

**Lesson:** the test that finds this is the one that runs as the actual user
with the actual privileges. Everything else is a rehearsal.

### The world-writable file that led somewhere worse

`systemd-analyze verify` had been printing a warning on every run that nobody
read: unit files were `-rwxrwxrwx`. The cause was mundane — `COPY` preserves the
source mode, and the repo lives on a Windows drvfs mount that reports 0777 for
everything.

Under `/usr` this was invisible, because bootc keeps `/usr` read-only. But three
of the eighteen affected files land in `/etc`, which is not read-only:

```
$ su - kotinos -c 'echo COMPROMISED >> /etc/kotinos/vault.conf'
YES-WROTE-VAULT-CONF
```

`vault.conf` decides what the vault backs up. An ordinary user could append an
exclusion for their own documents and the vault would go on reporting successful
backups of everything that no longer mattered.

**Lesson:** the safety came from the filesystem being read-only, not from the
files being right. Those are not the same thing, and only one of them travels.

### Things that reported success while doing nothing

- **The firewall never removed SSH.** `firewall-offline-cmd --remove-service`
  collides with a legacy lokkit compatibility layer and fails when combined with
  `--zone=`. The call was wrapped in `|| true`, so it failed on every build while
  the build stayed green. Found by adding an assertion to something that had been
  assumed.
- **The Flathub remote would not have survived first boot.** `flatpak remote-add`
  writes to `/var/lib/flatpak/repo/config`, and `@var` is discarded on first
  boot. The build-time check passed inside the container and the shipped machine
  would have had no app source at all.
- **`kotinos-space` never printed the one thing it exists for.** `btrfs qgroup
  show` has four columns; the loop read the fifth as `Exclusive`, so every row
  failed its numeric test and the "held by restore points" section was silently
  skipped — three lines below the comment explaining why that number matters.

That last one had a trap inside the fix: correcting the field count alone would
have summed `@` and `@var` too, reporting nearly the whole disk as held by
snapshots. Fixing the obvious bug would have created a worse one.

### An assumption that was never tested, and was wrong

M4 recorded that forcing `sshd_session_t` enforcing would break login, and left
it. When finally tested, it did not break login at all — key auth, `scp`, `sftp`
and repeated sessions all worked with zero new denials, and the mislabelled
`authorized_keys` attack that had *succeeded* under permissive was now refused
at `permissive=0`.

**Lesson:** "we assumed it would break" is not a finding. It is a note to test
something later.

---

## The code-quality pass

A read-through of the existing scripts looking for logic that was wrong rather
than untidy. Thirteen fixes; the shape repeated so consistently it is worth
naming.

**The comment was the specification, and the code had drifted from it.**

| File | The comment said | The code did |
|---|---|---|
| `kotinos-vault.sh` | logs a successful backup | recorded success unconditionally, discarding rsync's exit status |
| `kotinos-go-back.sh` | "adds vocabulary and confirmation" | never prompted at all, then ran `rsync --delete` over every home |
| `kotinos-wallpaper.sh` | "the first manual change opts out permanently" | only opted out if changed via *our* tool, so the timer overwrote real choices |
| `kotinos-focus.sh` | "restores exactly what it changed" | restored one of three, and unmuted people who were already muted |
| `kotinos-apps.sh` | "these are copied" | copied nothing, and `~/.local/bin` was not even in the vault's list |

The vault one is the worst: a full disk, an unreadable file, or a source that
vanished mid-copy all produced `backup complete` in the log. The one service
nobody watches was the one that could not fail.

`kotinos-apps` was quietly the most consequential. It runs as root from the
vault timer, and root's `flatpak list` sees only the system installation — but
apps install per-user, which is the whole point of the M4 sandbox model. So the
record that exists *"so a restored machine can be rebuilt"* listed nothing, and
said `(none yet)` while doing it. A record that is empty is worse than no record,
because it is believed.

---

## M5 — Admin mode

### The design survived; the mechanisms did not, at first

The enforcement decision (PAM as the gate, sudoers and polkit applying it,
SELinux protecting the grant) was made before anything was tested, with four
mechanism details recorded as believed-but-unverified. Testing them changed the
design once and cost hours twice.

### sudo skips the gate entirely by default

A gate in `/etc/pam.d/sudo` lives in the auth stack, and **sudo does not run that
stack while a cached authentication is valid** — five minutes by default. So
unlock, relock, and a `sudo` within five minutes still gets root while the
machine reports itself locked.

```
default sudoers      second sudo succeeded WITHOUT authenticating   stack ran 1x
timestamp_timeout=0  second sudo refused                            stack ran 1x
```

**Lesson:** the hole arrived through an upstream default, not through anything
we wrote. Those are the ones that survive review, because there is no line to
review.

My first attempt to measure this was wrong in a way worth recording: `sudo -n`
with no valid ticket exits *before* the auth stack, and each `su -` gets its own
ticket, so "0 stack runs" looked like a bypass when it was nothing of the sort.
The result only became meaningful once both calls shared a session.

### `seteuid`, and a message that reads like a malfunction

`pam_exec` runs its helper as the **invoking user** unless told `seteuid`. The
grant was `0600 root:root`, so the helper could not read it, so the gate refused
everything — including valid grants.

It presented as a PAM bug because sudo renders *any* failed auth module as:

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

A `dontaudit` rule had been suppressing it. `polkitd` runs unprivileged in
`policykit_t` and simply could not read the grant.

**Lesson:** when something fails with no error at all, suspect that the error is
being hidden rather than that it does not exist. `semodule -DB` is the switch.

### A guard that could not fire

After building the "privilege gate preconditions" check, I broke each thing it
guards to confirm it noticed. Two of three fired. The third — a polkit rule
using `auth_admin_keep` — did not, because I had grepped for the spelling used
in `.policy` XML while `rules.d` JavaScript spells it `AUTH_ADMIN_KEEP`.

A case-sensitive match that would never have fired on the files the check exists
to read. Written twenty minutes earlier, by me, in the same session as several
findings about checks that verify nothing.

**Lesson:** a regression guard that has never been seen to fire is not a guard.
Break the thing on purpose.

---

## Environment and tooling

Not about the OS, but it cost real time.

- **Every build was rebuilding everything.** `ARG BUILD_ID` was consumed at step
  3, and an `ARG` invalidates the layer cache from its use onward — so changing
  the tag discarded all seventy-odd steps including a several-hundred-package
  desktop install. Measured at **one cached step out of seventy-three**. Moving
  the stamp to the end took the next build to **66 cached steps, step 77 of 80 in
  forty seconds**.
- **The WSL build dies silently under memory pressure**, twice, at the same
  `install-to-filesystem` stage, with no error and no OOM record. Launch with
  `setsid nohup` so it outlives the invoking shell, and poll the log rather than
  holding a connection open.
- **PowerShell mangles `|` and `$` inside arguments passed to `wsl`**, producing
  errors that look like bugs in the remote script. Write the script to a file,
  copy it in, strip CRs, then run it.
- **`/usr` is read-only on bootc**, so `dnf install` at runtime silently fails
  and testing proceeds against software that was never installed. `bootc
  usr-overlay` gives a transient writable `/usr` for exactly this.

---

## What I would tell the next person

1. **Run it as the user who would attack you.** Every serious finding here came
   from executing something as an unprivileged account, not from reading code.
2. **Assertions are the product.** Half these defects were found by adding a
   check to something previously assumed — and several *were* assertions that
   could not fail, which is worse than none.
3. **When a check passes, make it fail on purpose.** Twice a guard was reporting
   "ok" while verifying nothing.
4. **Suspect the comment.** The most reliable signal of a defect was a confident
   comment describing behaviour the code did not have.
5. **Silence is a symptom.** Both hardest bugs presented as *nothing happening*:
   a suppressed SELinux denial, and a PAM message that reads like a crash.
