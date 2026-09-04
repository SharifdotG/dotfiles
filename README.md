# dotfiles

Configuration for **two** CachyOS + KDE Plasma machines — a ThinkPad T490s and a Ryzen
desktop — built around one constraint they happen to share: **16 GB of RAM against Docker,
Angular/Nx, .NET and a browser.**

| | laptop | desktop |
|---|---|---|
| CPU | i5-8365U · 4C/8T · Whiskey Lake | Ryzen 5 3600 · 6C/12T · Zen 2 |
| GPU | Intel UHD 620 | Radeon RX 570 8 GB (Polaris) |
| RAM | 16 GB | 16 GB DDR4-2400 |
| Disk | 238 GB NVMe | 500 GB NVMe + 1 TB HDD (reformatted, game library) |
| Display | 14" 1080p @ 125% | 21.5" 1080p + 18.5" 768p, both @ 100% |
| Extra | — | Steam, Heroic (Epic/GOG), Kdenlive |

Because the RAM is the same on both, **the load-bearing half of this repo is identical on
both machines** — every value in `system/` (swappiness 180, zram, earlyoom, the 6 GiB
browser cap) was derived from 15.3 GiB usable and needs no per-machine variant. What
actually differs is hardware vendor and role, and only that is split.

That constraint is more binding than it sounds, and it points somewhere unexpected. Measured
on the laptop: the browser held an **8.13 GiB** working set against 15.3 GiB of usable RAM
(Firefox at the time; Brave Origin measures lower but the web apps inside it cost the same),
while the entire Plasma session — compositor, shell, panel, every KDE daemon — is
**0.58 GiB**. The desktop *environment* was never where the memory went, which is why almost
everything here is about the browser, the containers and the kernel, and almost none of it
is about Plasma.

(That word does double duty in this repo now, so: "desktop" means the graphical session in
`packages/desktop.tsv` and on both machines, and means the Ryzen tower in `PROFILE=desktop`.
The manifests for the machine are `gaming.tsv` and `creative.tsv`, never `desktop.tsv`.)

That is worth stating plainly because this repo briefly got it wrong: it targeted a minimal
tiling compositor specifically to save RAM, on the strength of a published figure that put
Plasma at 1.2–1.5 GB. The figure was ~2.4× too high, the saving was a few hundred megabytes
against an eight-gigabyte browser, and the configuration burden was real. Plasma came back.

```bash
git clone <this-repo> ~/dotfiles && ~/dotfiles/bootstrap.sh
```

`bootstrap.sh` is idempotent — re-running it is the normal update path. It refuses to run
on anything that is not Arch-derived; see `docs/MIGRATION.md` for how the machine got here.

### How the two machines are told apart

**Not by hostname.** This repo is public, and a hostname is inventory disclosure even though
it is not a credential — the same reason the private git forge is prompted at `chezmoi init`
rather than committed. Instead `lib/detect.sh` reads three facts from the kernel:

| Variable | Values | Read from |
|---|---|---|
| `PROFILE` | `laptop` / `desktop` | `/sys/class/dmi/id/chassis_type`, falling back to `/sys/class/power_supply/BAT*` |
| `CPU_VENDOR` | `intel` / `amd` | `vendor_id` in `/proc/cpuinfo` |
| `GPU` | `intel` / `amd` / `nvidia` / `none` / `mixed` | PCI vendor id in `/sys/class/drm/card*/device/vendor` |

Three variables and not one, deliberately: `thermald` is an Intel-**CPU** fact and
`LIBVA_DRIVER_NAME` is a **GPU** fact. Neither is a "laptop" fact, and folding them into a
single profile name is how the next machine silently gets the wrong driver.

A fresh machine is therefore correct with no setup step. Override with
`--profile=desktop`, with `DOTFILES_PROFILE` / `DOTFILES_CPU_VENDOR` / `DOTFILES_GPU`, or by
putting one word in `/etc/dotfiles-profile`. The environment overrides also mean the machine
you are *not* sitting at can be reviewed from the one you are:

```bash
DOTFILES_PROFILE=desktop DOTFILES_CPU_VENDOR=amd DOTFILES_GPU=amd ./bootstrap.sh --dry-run
```

What each axis selects:

| Axis | Packages | Config |
|---|---|---|
| `CPU_VENDOR` | `packages/cpu-{intel,amd}.tsv` | `thermald` enabled only on Intel |
| `GPU` | `packages/gpu-{intel,amd}.tsv` | `LIBVA_DRIVER_NAME`; `amdgpu.ppfeaturemask`; `lactd` |
| `PROFILE` | `packages/{gaming,creative}.tsv` on desktop | font sizes, scroll step, MangoHud, gamemode |

Everything else — `core`, `dev`, `reliability`, `desktop` (which means the graphical
*session*, on both machines) — is shared.

**The repo clones anywhere, including Windows and macOS** — it just will not *bootstrap*
anywhere but Arch. That distinction had to be fixed on 2026-09-04, because it was not true:

```console
$ git clone <this-repo>
error: invalid path 'home/private_dot_config/systemd/user/app-brave\x2dorigin@.service.d/50-memory.conf'
fatal: unable to checkout working tree
```

One file needed a literal `\` in its filename — systemd escapes the `-` in the unit name
`app-brave-origin@.service`, and a drop-in directory without that escape matches nothing. `\`
is an illegal filename character on Windows, and git refuses the **entire checkout** rather
than skipping the one path, so the clone left a `.git` directory and no files at all. A
Linux-only detail in one file made the whole repo unreadable on every other OS.

The escaped path is load-bearing and still used; it is just no longer *committed* as a path.
The content lives at `home/.chezmoitemplates/systemd-user/` under a portable name, and
`home/.chezmoiscripts/run_onchange_after_30-user-units.sh.tmpl` writes it to the escaped
path at apply time — moving the backslash out of a filename git must check out and into a
string inside a shell script, which git checks out anywhere. One consequence worth knowing:
`chezmoi diff` and `chezmoi status` no longer show drift in that one target file. The script
owns it, and re-runs whenever its content changes.

`.gitattributes` covers the other half of the same problem: Git for Windows defaults to
`core.autocrlf=true`, and a shell script that picks up CRLF fails on Linux as
`$'\r': command not found` — or, for a shebang, as "no such file or directory" naming a
binary that plainly exists. Everything is normalised to LF.

## What's here

| Path | Purpose |
|---|---|
| `bootstrap.sh` | The only entrypoint. Verifies the distro, installs packages, applies `home/`. |
| `home/` | chezmoi source tree → `~`. Shell, terminal, editor and CLI config. |
| `home/.chezmoiscripts/` | Run after the files land: the Plasma theme keys, and the `systemctl --user` write + reload. |
| `home/.chezmoitemplates/` | Content chezmoi cannot apply as a *path* — currently one systemd drop-in whose real filename contains a `\`, which Windows cannot check out. See above. |
| `lib/` | `log.sh`, `detect.sh`, `pkg.sh` — sourced by everything else. Plain awk + TSV, no dependencies. |
| `packages/*.tsv` | Logical package id → real name per source (`arch`, `aur`). Plain TSV, parsed with awk. |
| `os/cachyos/prep.sh` | Repo tier, pacman settings and the AUR helper — everything that must be right *before* packages install. |
| `system/` | The `/etc` drop-ins that keep the machine from freezing. Applied by an explicit `sudo`. |
| `scripts/` | `reclaim.sh`, `secrets-setup.sh`, `git-credentials.sh`, `doctor.sh`, and the backup pair `db-backup.sh` / `db-restore.sh` plus `agents-backup.sh`. |
| `docs/SETUP-GUIDE.md` | The long-form guide. This repo is its executable half. |
| `docs/MIGRATION.md` | The one-time move off Fedora KDE. A runbook, not a reference. |
| `docs/BACKUP.md` | Backup and restore: the databases, the `.env` files, and every agent's MCP + skills. |
| `docs/DESKTOP.md` | The desktop machine: BIOS, migrating the 1 TB disk off NTFS into a game library, gaming, LACT, board sensors. |

## After bootstrap

```bash
sudo ./system/apply.sh      # /etc drop-ins, and enable the units Arch ships disabled
sudo usermod -aG docker "$USER"
sudo usermod -aG kvm "$USER"    # only for Claude Desktop's Cowork tab (QEMU/KVM VM)
./scripts/reclaim.sh        # reclaim disk: pacman cache, orphans, coredumps
./scripts/secrets-setup.sh  # sign in to GitHub (gh auth login, over HTTPS)
./scripts/git-credentials.sh # a PAT per host - github.com and the private forge
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
| **Plasma's Fonts settings module** (`kcm_fonts`) | **`~/.config/fontconfig/fonts.conf` — a file chezmoi *does* manage** | Nothing prevents it. It re-serialises the file and **appends** its rasterisation block instead of replacing one, so the blocks accumulate and the last one wins. Found 2026-09-05 with **78 blocks** where the repo writes 1, and the machine rendering with hinting and subpixel antialiasing **off** while every config file said `hintslight` + `rgb`. `chezmoi apply` restores it; `scripts/doctor.sh` now reads the *effective* values back with `fc-match` so the drift cannot be silent again |

## Secrets

None are stored here, and **the auth path is HTTPS + a Personal Access Token — not SSH**.
Every remote is an HTTPS URL, on github.com and on the private forge alike.
`scripts/git-credentials.sh` *prompts* for a token per host and hands it to git's credential
helper, which puts it in the desktop keyring — so those remotes stop asking without a token
ever touching this tree. `scripts/secrets-setup.sh` covers the `gh` CLI's own session with
`gh auth login`, which is likewise token-based; it generates an SSH key only if you ask for
one with `--ssh`. Credentials issued per machine beat synced ones, and it means this repo can
be public.

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
