# dotfiles

Configuration for a CachyOS + niri developer laptop (ThinkPad T490s), built around one
constraint: **16 GB of RAM against Docker, Angular/Nx, .NET and a browser.**

That constraint is more binding than it sounds. Measured on the machine this repo came
from: Firefox alone held an **8.13 GiB** working set against 15.3 GiB of usable RAM, and
the whole Plasma desktop session — compositor, shell, panel, every KDE daemon — was
**0.58 GiB**. The desktop was never where the memory went, which is why almost everything
here is about the browser, the containers and the kernel, and almost none of it is about
the window manager.

```bash
git clone <this-repo> ~/dotfiles && ~/dotfiles/bootstrap.sh
```

`bootstrap.sh` is idempotent — re-running it is the normal update path. It refuses to run
on anything that is not Arch-derived; see `docs/MIGRATION.md` for how the machine got here.

## What's here

| Path | Purpose |
|---|---|
| `bootstrap.sh` | The only entrypoint. Verifies the distro, installs packages, applies `home/`. |
| `home/` | chezmoi source tree → `~`. Shell, terminal, editor, compositor and shell-UI config. |
| `packages/*.tsv` | Logical package id → real name per source (`arch`, `aur`). Plain TSV, parsed with awk. |
| `os/cachyos/prep.sh` | Repo tier, pacman settings and the AUR helper — everything that must be right *before* packages install. |
| `system/` | The `/etc` drop-ins that keep the machine from freezing. Applied by an explicit `sudo`. |
| `scripts/` | `reclaim.sh`, `secrets-setup.sh`, `firefox-tune.sh`, `doctor.sh`. |
| `firefox/` | `user.js`, installed into every profile by `scripts/firefox-tune.sh` (profile dirs have random names, so chezmoi can't target them). |
| `docs/SETUP-GUIDE.md` | The long-form guide. This repo is its executable half. |
| `docs/MIGRATION.md` | The one-time move off Fedora KDE. A runbook, not a reference. |

## After bootstrap

```bash
sudo ./system/apply.sh      # /etc drop-ins, and enable the units Arch ships disabled
sudo usermod -aG docker "$USER"
./scripts/reclaim.sh        # reclaim disk: pacman cache, orphans, coredumps
./scripts/secrets-setup.sh  # generate an SSH key, sign in to GitHub
./scripts/firefox-tune.sh   # install firefox/user.js into every profile
./scripts/doctor.sh         # verify
```

## One thing not to "fix"

**`fd-find` installs the binary as `fd`.** There is no `fdfind` — that's the Debian name.
An `alias fd='fdfind'` breaks a working command. (On Arch the package is simply `fd`, so
this is now only a warning about the alias, not about the package name.)

## One thing you now *have* to fix

**Nothing themes GTK any more — so this repo does.** Under Plasma, `kde-gtk-config`'s kded
module rewrote `~/.config/gtk-{3,4}.0/` from the live colour scheme on every change, so
those paths were in `.chezmoiignore` and `gtk-theme-name=Breeze` was *correct*.

Under niri there is no kded and nothing regenerates anything, so the old rule would leave
GTK apps on default Adwaita forever — the same symptom, opposite cause. The ownership split
is now:

- **Noctalia owns colour** — its `gtk3`/`gtk4`/`qt6ct` templates write `noctalia.css` and
  import it into `gtk.css`. Those generated files stay in `.chezmoiignore`.
- **chezmoi owns behaviour** — `gtk-3.0/settings.ini` and `gtk-4.0/settings.ini`: theme
  name, icons, font, cursor, hinting.

`.gtkrc-2.0` stays ignored permanently: nothing left after the migration is a GTK2 app.

## Things that write over your dotfiles

Three programs in this setup rewrite config that chezmoi also manages. Each is handled, and
it is worth knowing the pattern because it caused real confusion during the migration:

| Program | Writes | Handling |
|---|---|---|
| Noctalia Settings GUI | `~/.local/state/noctalia/settings.toml`, which loads **last** and wins | Ignored by chezmoi; `doctor.sh` warns when it is non-empty. Promote what you want into `config.toml`, then delete it. |
| btop | its own `btop.conf` on exit | `save_config_on_exit = false` |
| Noctalia templates | `gtk.css`, `noctalia.css`, `qt6ct/` | Ignored by chezmoi — deliberately Noctalia's, see above |

## Secrets

None are stored here. `scripts/secrets-setup.sh` *generates* an SSH key and runs
`gh auth login`. A fresh key per machine beats a synced one, and it means this repo can be
public. `~/.ssh`, `~/.config/gh`, `~/.npmrc`, NuGet config and `~/.docker/config.json` are
excluded in both `.gitignore` and `.chezmoiignore`.

That design was vindicated by the migration: the outgoing machine had **no SSH keypair and
zero GPG secret keys**, so there was no key material to carry across at all. But note the
asymmetry it creates — this repo restores everything *except* the handful of credential
files you cannot regenerate. `docs/MIGRATION.md` lists them.
