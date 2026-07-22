# First-boot questions

The exact wording the setup wizard asks. Kept as text, separate from the
wizard's code, so the words can be argued about and improved without touching
software — and so they stay consistent wherever else they appear (settings,
help, the AI's answers).

**Rules these follow.** Ask only what genuinely cannot be decided for the user.
Every question here has a safe default already selected, so the entire setup can
be completed by pressing continue. Never use a word the user would have to look
up: no "partition", no "subvolume", no "redundancy". Say what happens, not what
it is called.

---

## 1. Your account

> **What should we call you?**
>
> This is the name on your account and what you will see when you sign in.

*Name, username, password. Standard, but the password field explains why it
matters rather than just demanding 8 characters.*

---

## 2. Backup on a second disk

> **Keep a spare copy on another drive?**
>
> KotinosOS already keeps protected copies of your important files on this
> computer. That covers almost everything that goes wrong — deleting something
> by accident, an app corrupting your work, or a bad update.
>
> The one thing it cannot survive is this computer's drive failing, because the
> copies are on that same drive.
>
> If you plug in an external drive, we can keep a second copy there
> automatically. You do not have to remember to do anything — whenever it is
> connected, it updates itself.
>
> - **Not now** *(default)* — you can turn this on later at any time.
> - **Yes, use an external drive** — choose the drive on the next screen.
>   Everything on it will be erased.

*Sets `MIRROR_EXTERNAL` in `/etc/kotinos/vault.conf`. Changeable later in admin
mode. The default is off because it requires hardware the user may not have, and
a setup that stalls on missing hardware is a setup people abandon.*

**Why the wording is like this:** it leads with what is already protected, so the
question does not read as "your files are at risk unless you act". Then it names
the single specific gap. It never uses the word backup as a noun, because
everyone thinks they know what that means and everyone means something different.

---

## 3. Browser and search

> **Which browser would you like?**
>
> You can change this later, and install others at any time.

*Firefox default. Search engine defaults to DuckDuckGo — the wizard mentions it
in one line rather than making it a separate screen, because it is a setting
almost nobody wants to be asked about.*

---

## 4. How it should look

> **Pick a look.**
>
> All of these change again later, and you can mix them however you like.

*The five presets from `kotinos-theme`, shown as previews rather than named
options. A picture answers this question faster than any label.*

---

## Deliberately not asked

- **Vault size.** Fixed at roughly a tenth of the disk. The user has no basis to
  answer this before they have any data, and a wrong answer is only fixable by
  reinstalling. Adjustable in admin mode for people who know why they want to.
- **Timezone, keyboard, locale.** Detected. Asking is faster to build and worse
  to use.
- **Anything about snapshots, filesystems or updates.** These work without
  configuration. A question implies a decision, and a decision implies the user
  could get it wrong.
