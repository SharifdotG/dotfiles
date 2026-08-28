# dotfiles

Configuration for a Fedora KDE developer laptop (ThinkPad T490s), built around one
constraint: **16 GB of RAM against Docker, Angular/Nx, .NET and a browser.**

```bash
git clone <this-repo> ~/dotfiles && ~/dotfiles/bootstrap.sh
```

`bootstrap.sh` is idempotent — re-running it is the normal update path.

## What's here

| Path | Purpose |
|---|---|
| `bootstrap.sh` | The only entrypoint. Detects the distro, installs packages, applies `home/`. |
| `home/` | chezmoi source tree → `~`. Shell, terminal, editor and CLI config. |
| `packages/*.tsv` | Logical package id → real name per distro. Plain TSV, parsed with awk. |
| `system/` | The `/etc` drop-ins that keep the machine from freezing. Applied by an explicit `sudo`. |
| `desktops/plasma/` | Konsole profile, colour schemes — things that don't live in `~/.config`. |
| `scripts/` | `reclaim.sh`, `secrets-setup.sh`, `doctor.sh`. |
| `docs/SETUP-GUIDE.md` | The long-form guide. This repo is its executable half. |

## After bootstrap

```bash
sudo ./system/apply.sh      # memory tuning, journald cap, docker daemon
./scripts/reclaim.sh        # drop unused idle services (~800 MB on a stock Fedora KDE)
./scripts/secrets-setup.sh  # generate an SSH key, sign in to GitHub
./scripts/doctor.sh         # verify
```

## Two things not to "fix"

**GTK is themed by KDE, not by this repo.** `kde-gtk-config`'s kded module rewrites
`~/.config/gtk-{3,4}.0/` and `~/.gtkrc-2.0` from the live Plasma colour scheme on every
change. `gtk-theme-name=Breeze` is *correct* — Breeze is the widget style and KDE recolours
it. Those paths are in `.chezmoiignore` on purpose.

**On Fedora, `fd-find` installs the binary as `fd`.** There is no `fdfind` — that's the
Debian name. An `alias fd='fdfind'` breaks a working command.

## Secrets

None are stored here. `scripts/secrets-setup.sh` *generates* an SSH key and runs
`gh auth login`. A fresh key per machine beats a synced one, and it means this repo can be
public. `~/.ssh`, `~/.config/gh`, `~/.npmrc`, NuGet config and `~/.docker/config.json` are
excluded in both `.gitignore` and `.chezmoiignore`.
