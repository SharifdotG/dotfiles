# dotfiles

Configuration for a CachyOS + KDE Plasma developer laptop (ThinkPad T490s), built around one
constraint: **16 GB of RAM against Docker, Angular/Nx, .NET and a browser.**

That constraint is more binding than it sounds, and it points somewhere unexpected. Measured
on this machine: the browser held an **8.13 GiB** working set against 15.3 GiB of usable RAM
(Firefox at the time; Brave Origin measures lower but the web apps inside it cost the same),
while the entire Plasma session — compositor, shell, panel, every KDE daemon — is
**0.58 GiB**. The desktop was never where the memory went, which is why almost everything
here is about the browser, the containers and the kernel, and almost none of it is about the
desktop environment.

That is worth stating plainly because this repo briefly got it wrong: it targeted a minimal
tiling compositor specifically to save RAM, on the strength of a published figure that put
Plasma at 1.2–1.5 GB. The figure was ~2.4× too high, the saving was a few hundred megabytes
against an eight-gigabyte browser, and the configuration burden was real. Plasma came back.

```bash
git clone <this-repo> ~/dotfiles && ~/dotfiles/bootstrap.sh
```

`bootstrap.sh` is idempotent — re-running it is the normal update path. It refuses to run
on anything that is not Arch-derived; see `docs/MIGRATION.md` for how the machine got here.

## What's here

| Path | Purpose |
|---|---|
| `bootstrap.sh` | The only entrypoint. Verifies the distro, installs packages, applies `home/`. |
| `home/` | chezmoi source tree → `~`. Shell, terminal, editor and CLI config. |
| `home/.chezmoiscripts/` | Run after the files land: the Plasma theme keys, and the `systemctl --user` reload. |
| `lib/` | `log.sh`, `detect.sh`, `pkg.sh` — sourced by everything else. Plain awk + TSV, no dependencies. |
| `packages/*.tsv` | Logical package id → real name per source (`arch`, `aur`). Plain TSV, parsed with awk. |
| `os/cachyos/prep.sh` | Repo tier, pacman settings and the AUR helper — everything that must be right *before* packages install. |
| `system/` | The `/etc` drop-ins that keep the machine from freezing. Applied by an explicit `sudo`. |
| `scripts/` | `reclaim.sh`, `secrets-setup.sh`, `git-credentials.sh`, `doctor.sh`, and the backup pair `db-backup.sh` / `db-restore.sh` plus `agents-backup.sh`. |
| `docs/SETUP-GUIDE.md` | The long-form guide. This repo is its executable half. |
| `docs/MIGRATION.md` | The one-time move off Fedora KDE. A runbook, not a reference. |
| `docs/BACKUP.md` | Backup and restore: the databases, the `.env` files, and every agent's MCP + skills. |

## After bootstrap

```bash
sudo ./system/apply.sh      # /etc drop-ins, and enable the units Arch ships disabled
sudo usermod -aG docker "$USER"
sudo usermod -aG kvm "$USER"    # only for Claude Desktop's Cowork tab (QEMU/KVM VM)
./scripts/reclaim.sh        # reclaim disk: pacman cache, orphans, coredumps
./scripts/secrets-setup.sh  # generate an SSH key, sign in to GitHub
./scripts/git-credentials.sh # store a PAT per host so HTTPS git stops prompting
./scripts/doctor.sh         # verify
```

## Moving to a new machine

A `git clone` restores your code and `bootstrap.sh` restores your configuration. Between them
they miss three things, all of which live only on the disk you are about to erase: the
**Dockerised databases**, the projects' **gitignored `.env` files**, and your **agent config** —
MCP tokens and skills for Claude Code, Codex and Antigravity 2.0.

Two commands before the wipe:

```bash
./scripts/db-backup.sh            # databases, volumes, and every project .env
./scripts/agents-backup.sh export # MCP servers, skills, rules, settings
```

and two after it, once the repos are cloned:

```bash
./scripts/agents-backup.sh restore -i ~/Backup/claude
./scripts/db-restore.sh ~/Backup/db/<stamp> --list   # read-only. Always first
./scripts/db-restore.sh ~/Backup/db/<stamp>
```

Measured here: **10 MB total, twelve seconds** — it is small because it is logical (dumps and
manifests, not disk images). ~470 MB of database volumes become an 8.3 MB snapshot, and all
three dumps were verified by restoring them into clean throwaway servers.

**`docs/BACKUP.md` is the full guide** — what each script finds, the flags, the restore order
and why it is that order, what is deliberately *not* backed up, and a troubleshooting table.
`docs/MIGRATION.md` is the runbook that calls them.

> Both outputs contain secrets — the `.env` files, Postgres role password hashes and live
> bearer tokens — and are written `0700`/`0600` under `~/Backup/`, outside this tree on
> purpose. Never move them into the repo; it is public.

## Two things not to "fix"

**GTK is themed by KDE, not by this repo.** `kde-gtk-config`'s kded module rewrites
`~/.config/gtk-{3,4}.0/` and `~/.gtkrc-2.0` from the live Plasma colour scheme on every
change. `gtk-theme-name=Breeze` is *correct* — Breeze is the widget style and KDE recolours
it. Those paths are in `.chezmoiignore` on purpose.

> This rule has flipped twice, so here is the test rather than the answer: **does something
> else already own these files?** Under Plasma it does. Under a bare compositor it does not,
> and leaving them unmanaged strands GTK apps on default Adwaita forever.

**`fd-find` installs the binary as `fd`.** There is no `fdfind` — that's the Debian name. An
`alias fd='fdfind'` breaks a working command.

## Things that write over your dotfiles

Several programs rewrite config that chezmoi might otherwise manage. Each is handled, and the
pattern is worth knowing because it caused real confusion during the migration:

| Program | Writes | Handling |
|---|---|---|
| `kde-gtk-config` | `~/.config/gtk-{3,4}.0/`, `~/.gtkrc-2.0` | Ignored by chezmoi — deliberately KDE's, see above |
| btop | its own `btop.conf` on exit | `save_config_on_exit = false` |
| Plasma | most of `~/.config/*rc` | No Plasma *file* is managed. A script writes the handful of *keys* we care about (colour scheme, icons, cursor, fonts) with `kwriteconfig6` — the same API System Settings uses — and leaves the rest of each file to Plasma |

## Secrets

None are stored here. `scripts/secrets-setup.sh` *generates* an SSH key and runs
`gh auth login`; `scripts/git-credentials.sh` *prompts* for a Personal Access Token per host
and hands it to git's credential helper, which puts it in the desktop keyring — so HTTPS
remotes stop asking without a token ever touching this tree. A fresh key per machine beats a
synced one, and it means this repo can be public.

> The one config file those scripts do write, `~/.config/git/credentials.inc`, is deliberately
> *not* chezmoi-managed: `git config --global` writes `~/.gitconfig`, which chezmoi
> regenerates, so anything stored there would silently vanish on the next `apply`.
> `home/dot_gitconfig.tmpl` pulls it in with `[include]` instead, and git ignores the include
> when the file is absent. `~/.ssh`, `~/.config/gh`, `~/.npmrc`, NuGet config and `~/.docker/config.json` are
excluded in both `.gitignore` and `.chezmoiignore`.

That design was vindicated by the migration: the outgoing machine had **no SSH keypair and
zero GPG secret keys**, so there was no key material to carry across at all. But note the
asymmetry it creates — this repo restores everything *except* the handful of credential
files you cannot regenerate. `docs/MIGRATION.md` lists them.
