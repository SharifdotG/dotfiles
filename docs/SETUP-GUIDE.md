# 🌟 The T490s Low-RAM Setup Guide 🔥
### CachyOS · niri · Noctalia v5

**Target machine:** Lenovo ThinkPad T490s — Intel i5-8365U (4C/8T, Whiskey Lake), 16 GB RAM
(15.3 GiB usable), Intel UHD 620
**Storage:** 238.5 GB Intel NVMe (`INTEL SSDPEKKF256G8L`), btrfs + zstd:1, zram-only swap
**ISA level:** **x86-64-v3** — no AVX-512. This decides which CachyOS repos you may enable;
see Phase 1.
**Displays:** `eDP-1` 1920×1080 @ scale 1.25 · `HDMI-A-2` 1920×1080 @ scale 1.0
**Target OS:** CachyOS (Arch) · niri (scrollable-tiling Wayland compositor) · Noctalia v5 shell
**Workload:** Docker, Angular/Nx monorepos, microservices, nopCommerce (.NET + SQL Server)
**Curated by SharifdotG · Revised for low-RAM stability**

> **Coming from the Fedora KDE version of this guide?** The one-time move is
> `docs/MIGRATION.md`, which is a runbook rather than a reference. This file is what you
> read afterwards, and every time something breaks.

---

## 📋 What changed, and why

Only the decisions worth carrying forward. This table is deliberately short — the previous
version grew to eighteen rows of GNOME-to-KDE trivia and aged badly.

| Was | Is | Why |
|---|---|---|
| Fedora 44 / `dnf` | CachyOS / `pacman` + `paru` | Rolling, and the v3-optimised repos match this CPU |
| KDE Plasma 6.7 | niri + Noctalia v5 | Measured: the whole Plasma session was 0.58 GiB, so this is worth a few hundred MB, not gigabytes. See the budget table |
| Konsole | Ghostty | Already installed and managed; now actually themed, which is why it was not being used before |
| Dolphin / Okular / Gwenview / Ark / Spectacle / KCalc | Thunar + yazi / zathura / imv / file-roller / **niri built-in** / **Noctalia built-in** | Two of them needed no package at all |
| Secure Boot **enabled** | **disabled** in firmware | `linux-cachyos` is not MS-signed, and fwupd never needed Secure Boot |
| `starship` and `chezmoi` via upstream installers | real repo packages | The `-` sentinel in `packages/core.tsv` is gone |
| GTK themed for free by `kde-gtk-config` | Noctalia owns colour, chezmoi owns settings | The one rule in this guide that **inverted**. See Phase 7 |
| RPM Fusion for codecs | nothing to do | Arch's `ffmpeg` is unencumbered |

---

## 🛠 Phase 0: BIOS & Firmware Prep (do this first)

Reboot → press **F1** at the ThinkPad logo to enter BIOS.

- **Config → Power → Sleep State → `Linux`**
  This enables S3 deep sleep instead of Modern Standby. On the T490s this is the difference between losing ~2% and ~15% battery overnight. Do not skip this.
- **Security → Secure Boot** — leave **enabled**. **Disable it.** `linux-cachyos` is not signed by a key in the default UEFI db, so Secure Boot would mean enrolling your own keys with `sbctl` and re-signing on every kernel update. And correcting a claim this guide used to make: **fwupd does not require Secure Boot** - LVFS updates work fine with it off.
- **Config → Thunderbolt → Thunderbolt BIOS Assist Mode → Disabled** (better hotplug on Linux).
- **Security → Memory Protection → Execution Prevention → Enabled**.
- Note whether you have 8 GB soldered + 8 GB SODIMM or 16 GB soldered. The T490s has **one** SODIMM slot; if you have 8+8, a 16 GB stick later gets you to 24 GB for ~$30. Worth knowing before you spend hours tuning.

---

## 🛠 Phase 1: Verify the install did what you asked

Installing is a one-shot procedure and it lives in **`docs/MIGRATION.md`** — you cannot read
this file while the disk is being repartitioned. Come back here at first boot and check that
the installer actually did what you told it to.

| Check | Command | Must show |
|---|---|---|
| ISA level | `/lib64/ld-linux-x86-64.so.2 --help \| grep x86-64-v` | `v3 (supported, searched)`; **`v4` listed but NOT marked** |
| Repo tier | `pacman-conf --repo-list` | `cachyos-v3`, `cachyos-core-v3`, `cachyos-extra-v3` — **never `-v4`** |
| Root filesystem | `findmnt -no FSTYPE,OPTIONS /` | `btrfs`, `compress=zstd:1`, `ssd`, `discard=async` |
| Subvolumes | `sudo btrfs subvolume list /` | `@` → `/`, `@home` → `/home` |
| **No disk swap** | `swapon --show` | `/dev/zram0` and nothing else |
| Secure Boot | `bootctl status \| grep -i secure` | `disabled` |
| ESP headroom | `df -h /boot` | ≥ 40% free with two kernels installed |

> **NB — if `swapon --show` lists a disk partition, stop and remove it before you run
> `system/apply.sh`.** This is the single most dangerous interaction in the repo.
> `vm.swappiness = 180` is correct *only* because swap is zram. Pointed at an NVMe
> partition, that same value reproduces exactly the low-memory livelock described below —
> the repo's own tuning becomes the thing that freezes the machine, and it would be worse
> than stock.

> **NB — the v3/v4 trap fails at runtime, not at install time.** A v4 package on this CPU
> installs perfectly cleanly and then dies with `Illegal instruction (core dumped)` from
> arbitrary binaries, at arbitrary times. It reads exactly like failing RAM, and people
> memtest for a day over it. The absence of `(supported, searched)` next to `x86-64-v4` in
> that first command *is* the test.

Fingerprint enrolment, if you use it, is `fprintd-enroll` on the command line plus PAM
configuration — there is no System Settings panel any more. That is a genuine loss of
convenience and it is worth saying so.

---

## ✨ Phase 2: Base system setup

### 📦 First update

```bash
sudo pacman -Syu
```

> **NB — never `pacman -Sy <pkg>`.** A partial upgrade (syncing the database without
> upgrading the packages, then installing against it) is the number one way to break an Arch
> system, and the failure is usually a mismatched glibc that takes the shell with it. Always
> `-Syu`. `bootstrap.sh` folds its install into a full upgrade for exactly this reason.

### ⚙️ pacman settings

`os/cachyos/prep.sh` sets these idempotently; they are the direct analogue of the dnf tuning
this guide used to carry:

```ini
# /etc/pacman.conf, under [options]
ParallelDownloads = 10
Color
VerbosePkgLists
```

> **NB — they must go under `[options]`.** Appended to the end of the file — the way the old
> `dnf.conf` loop did it — they land inside whichever repo section happens to be last, where
> pacman ignores them silently.

The AUR helper is `paru`, which CachyOS preinstalls. `os/cachyos/prep.sh` verifies it rather
than bootstrapping it from git: if `paru` is missing *and* the `cachyos` repo cannot provide
it, the repo configuration is broken and that is the bug to fix.

> **NB — set `BUILDDIR=/var/tmp/makepkg` in `/etc/makepkg.conf`** (prep.sh does this). On a
> systemd default install `/tmp` is a tmpfs, so an AUR build happens **in RAM**. On 16 GB,
> building something large that way is precisely the freeze Phase 4 exists to prevent.

### 🔒 Codecs

Nothing to do. Arch's `ffmpeg` is unencumbered, so the entire RPM Fusion dance this guide
used to carry — third-party repos, `dnf swap ffmpeg-free`, the `-freeworld` packages — has no
equivalent. This is a real simplification, not an omission.

### 🎬 Hardware video acceleration (Intel UHD 620)

This offloads video decode to the iGPU. It cuts CPU usage on YouTube by roughly half and saves real battery.

```bash
sudo pacman -S --needed intel-media-driver libva-utils
vainfo | head -20   # should list VAProfileH264 / VAProfileHEVC entries
```

Firefox picks this up automatically on Wayland. Verify later at **`about:support` → Graphics** → `HARDWARE_VIDEO_DECODING: available`.

### ⚡ Firmware Updates

ThinkPads have excellent LVFS coverage — update the UEFI, Thunderbolt controller, and NVMe firmware:

```bash
sudo fwupdmgr refresh --force
sudo fwupdmgr get-updates
sudo fwupdmgr update
sudo reboot
```

### 🔋 Power management

**Do not run TLP and `power-profiles-daemon` together** — they fight over the same knobs.

The old advice here was "install ppd, Plasma integrates with it" — and that premise is gone: there is no battery applet wired to it any more. So this is now a real choice. `power-profiles-daemon` is the right pick **if** Noctalia's bar exposes a profile switcher (check its power widget); otherwise `tlp` is fire-and-forget and needs no desktop integration at all. Either one, plus the S3 BIOS setting from Phase 0, is enough.

Optional diagnostics only: `sudo pacman -S powertop` — run `sudo powertop` to *look* at power draw. Don't run `--auto-tune` on a ThinkPad; it aggressively suspends USB ports and will make your mouse and dock flaky.

---

## 🧩 Phase 3: Session components

A bare niri session is missing a set of things Plasma provided invisibly. Each one fails
**silently and confusingly** when absent, which is why they get a phase of their own rather
than a bullet list — the symptom rarely points at the cause.

| Missing piece | What it looks like when absent |
|---|---|
| polkit agent | Every GUI action needing a password does *nothing at all*. No dialog, no error, no log line. |
| Notification daemon | `notify-send` fails — which silently disables `earlyoom -n`, so **OOM kills become invisible**. Load-bearing for Phase 4. |
| Screen locker + idle daemon | Closing the lid leaves the session unlocked. |
| Clipboard manager | Copy from a window, close the window, clipboard is empty. Wayland has no clipboard owner after the source exits. |
| XDG portals | File pickers in Firefox and VS Code fall back to broken or absent; screen sharing in Teams/Meet does not work. |
| Qt platform theme | Every remaining Qt app renders in default Fusion regardless of your theme. |
| Network / Bluetooth applet | `nmcli` and `bluetoothctl` only. |
| Output configuration | No display-arrangement UI at all — it is `outputs.kdl` or nothing. |

**Noctalia v5 covers more of this than you might expect**, which is the main reason it is
worth running rather than assembling a shell from parts. It provides the bar, the launcher,
the notification daemon, the lock screen, the clipboard history, the OSD for volume and
brightness, the network and Bluetooth widgets, **and** a calculator in the launcher (it links
`libqalculate`, which is why KCalc needed no replacement package).

What Noctalia does *not* provide, and `packages/desktop.tsv` therefore installs:

- `polkit-gnome` — the authentication agent
- `xdg-desktop-portal`, `-gnome` and `-gtk` — see Phase 7 for which backend serves what
- `gnome-keyring` — the Secret Service provider, replacing kwallet
- `xwayland-satellite` — X11 clients. niri auto-spawns it and sets `DISPLAY` when present
- `qt6ct` — Qt theming
- `brightnessctl`, `playerctl`, `wl-clipboard` — the plumbing the binds call into
- `grim`, `slurp` — only for *scripted* screenshots; interactive ones are built into niri

> **NB — the notification daemon is not cosmetic.** `earlyoom` is configured with `-n`, which
> sends a desktop notification naming what it killed and why. With nothing on the bus to
> receive it, an OOM kill is completely silent: an application vanishes and you have no idea
> which subsystem decided that. Verify with `notify-send hello` before you trust Phase 4's
> reporting.

---

# 🧠 Phase 4: Memory & Anti-Freeze Setup

**This is the phase that fixes your actual problem.** Read it properly — everything else in this guide is convenience.

### Why the machine froze at 93–95% memory

It was never the desktop environment's fault, and no amount of switching between them fixes it. What happens is a classic Linux **low-memory livelock**:

When RAM fills up, the kernel doesn't kill anything immediately — it first evicts *page cache*, which includes the executable code of running programs. So Plasma, your browser, and your terminal get their own code paged out, then instantly need it back, so the kernel reads it from disk again, then evicts it again. The system spends 100% of its I/O re-reading the same pages. Nothing is technically hung, but nothing progresses. The kernel OOM killer only fires when a memory *allocation* actually fails, which can be minutes later — long after the machine became unusable.

The fix is four layers:

1. **zram** — compressed swap in RAM, so pressure relief costs microseconds not milliseconds
2. **A userspace OOM killer** — kills the greedy process *before* the livelock, not after
3. **Hard caps on Docker** — so a container can never take the whole machine
4. **An escape hatch** — so if it happens anyway, you don't hold the power button

**The desktop was never where the memory went.** Measured on this machine, the entire Plasma session — compositor, shell, panel, every KDE daemon — was **0.58 GiB**. Firefox alone was **8.13 GiB**, 53% of the 15.3 GiB actually available. niri + Noctalia is cheaper still and worth having, but the win is in the low hundreds of megabytes.

If you read this guide expecting the window manager to be the fix, you will tune the wrong thing. The four layers below are worth gigabytes. The desktop swap is worth a rounding error.

---

### 📸 Layer 0 — a way back

Everything below changes system state. Before any of it, get a rollback path. The
default install is already Btrfs with `@root`/`@home` subvolumes, so this is cheap:

```bash
sudo pacman -S --needed snapper snap-pac
sudo snapper -c root create-config /
sudo snapper -c root create --description "before tuning"
sudo snapper -c root list
```

Rolling back a bad change is then `sudo snapper -c root undochange <N>..0`. Without this,
a 95-package removal or a bad `/etc` edit is a reinstall.

### 🗜 Layer 1 — zram, sized properly

CachyOS enables zram by default via its own `cachyos-settings` config, sized conservatively. On a 16 GB dev box, set it to full RAM size — `zstd` typically gets 3:1 on dirty anonymous pages. **Measured on this machine: 3.79:1** (`zramctl` showed 8.1 GB of pages held in 2.1 GB of physical RAM), so the real-world win is better than the rule of thumb suggests.

```bash
sudo pacman -S --needed zram-generator   # Arch has no -defaults split package
sudo nano /etc/systemd/zram-generator.conf
```

```ini
[zram0]
zram-size = ram
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
```

#### Apply and verify:

Because zram is brought up at boot by a generator, reconfiguring an already-active block device gives a `Device or resource busy` error. On CachyOS this is the **normal** path, not an edge case, since its vendor config starts zram before ours is read. Reset the existing device first before restarting the swap unit:

```bash
# Deactivate and reset existing device
sudo swapoff /dev/zram0 2>/dev/null || true
sudo zramctl --reset /dev/zram0

# Reload and start the swap unit
sudo systemctl daemon-reload
sudo systemctl restart dev-zram0.swap

# Verify
zramctl
swapon --show   # should show /dev/zram0, ~16G, priority 100
```

*(Alternatively, rebooting the system will load the new configuration automatically).*

### 🎚 Layer 1b — kernel VM tuning for zram

```bash
sudo nano /etc/sysctl.d/99-memory-tuning.conf
```

```ini
# zram is RAM-speed, so swap EARLY and OFTEN. This is correct for zram-only
# systems and is the opposite of the usual "set swappiness low" advice, which
# assumes swap is on a slow disk.
vm.swappiness = 180

# zram has no seek penalty — never read ahead on swap-in.
vm.page-cluster = 0

# Don't over-reclaim into huge free blocks we don't need.
vm.watermark_boost_factor = 0

# Start reclaiming a bit earlier so we never hit the wall at full speed.
vm.watermark_scale_factor = 125

# Enable magic SysRq — your emergency brake (see Layer 4).
kernel.sysrq = 1

# Nx / Angular / VS Code watch enormous trees. Without this you get ENOSPC.
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
```

```bash
sudo sysctl --system
```

### 🔫 Layer 2 — systemd-oomd, tuned

**`systemd-oomd` is NOT enabled by default on Arch or CachyOS** — Fedora switched it on via a preset, and Arch's default preset is `disable *`. `system/apply.sh` enables it explicitly, and until it does, every drop-in below is inert. Its out-of-the-box settings (kill at 60%–80% memory pressure sustained for 20s–30s) react too slowly under heavy workloads. Fedora also shipped a per-slice default that overrode service-level limits, so these drop-ins were *corrective* there. On Arch there is no such default, which makes the user-slice drop-in below the **only** thing setting the limit - additive, and more load-bearing rather than less.

```bash
# 1. Tighten system-wide pressure detection duration
sudo mkdir -p /etc/systemd/oomd.conf.d
sudo tee /etc/systemd/oomd.conf.d/99-aggressive.conf > /dev/null <<'EOF'
[OOM]
DefaultMemoryPressureDurationSec=10s
EOF

# 2. Set memory pressure kill threshold on user manager service
sudo mkdir -p /etc/systemd/system/user@.service.d
sudo tee /etc/systemd/system/user@.service.d/99-oomd.conf > /dev/null <<'EOF'
[Service]
ManagedOOMMemoryPressure=kill
ManagedOOMMemoryPressureLimit=45%
EOF

# 3. Set the per-slice limit for user applications
sudo mkdir -p /etc/systemd/user/slice.d
sudo tee /etc/systemd/user/slice.d/99-oomd-user-slice.conf > /dev/null <<'EOF'
[Slice]
ManagedOOMMemoryPressure=kill
ManagedOOMMemoryPressureLimit=45%
EOF
```

#### Protect the shell:

Prevent `systemd-oomd` from killing the desktop shell when an *application* runs out of
memory. Under Plasma this drop-in went on `plasma-plasmashell.service`; here it goes on the
Noctalia unit this repo ships (`home/private_dot_config/systemd/user/noctalia.service`), which
already carries it:

```ini
[Service]
ManagedOOMPreference=avoid
OOMScoreAdjust=-500
```

> **NB — this is the concrete reason Noctalia gets a systemd unit at all.** Started from
> niri's `spawn-at-startup` it would be an unsupervised child of the compositor: there would
> be no unit to attach these two lines to, and nothing to restart it afterwards. Since
> Noctalia is simultaneously the bar, the launcher, the notifications, the OSD *and* the lock
> screen, having the OOM killer choose it means losing all five at once — with only a TTY to
> recover from.

Apply and verify:

```bash
sudo systemctl daemon-reload
systemctl --user daemon-reload
sudo systemctl enable --now systemd-oomd     # NB: Arch does not enable it for you
systemctl --user restart noctalia.service
oomctl
```

*(Expected: Default Memory Pressure Duration: 10s, and /user.slice/.../app.slice displaying Memory Pressure Limit: 45.00%).*

### 🪓 Layer 2b — earlyoom as the hard backstop

`systemd-oomd` is cgroup- and PSI-based, which means it reasons about *slices*. Docker containers live under `system.slice/docker.service` and aren't in its default watch set. `earlyoom` is dumber and better for exactly that case: it polls absolute free memory and kills the single biggest offender.

```bash
sudo pacman -S --needed earlyoom
```

The arguments live in a systemd drop-in — `system/systemd/system/earlyoom.service.d/99-args.conf`,
installed by `system/apply.sh`:

```ini
[Service]
ExecStart=
ExecStart=/usr/bin/earlyoom -r 3600 -m 4 -s 20 \
  --avoid '^(systemd|systemd-.*|sshd|niri|noctalia|xwayland-satell|Xwayland|greetd|agreety|tuigreet|dbus-.*|pipewire|wireplumber|gnome-keyring-d|NetworkManager)$' \
  --prefer '^(node|Web Content|Isolated Web Co|firefox|code-insiders|dotnet|sqlservr|java)$' \
  -n
```

That means: trigger when free RAM drops below 4% *or* free swap below 20%, never touch the
session, preferentially kill Node/Firefox/SQL Server, and send a desktop notification (`-n`)
so you know what died and why.

> **NB — why an `ExecStart=` override and not `/etc/default/earlyoom`, which is where this
> guide used to put it.** Arch's `earlyoom` package ships a *populated*
> `/etc/default/earlyoom` and a unit that reads it with `EnvironmentFile=`. And
> `systemd.exec(5)` is explicit that **`EnvironmentFile=` overrides `Environment=`**. So the
> obvious "modernisation" — a drop-in setting `Environment="EARLYOOM_ARGS=…"` — loses
> silently to the vendor file: `systemctl cat` shows your config, `systemctl is-active` says
> `active`, and earlyoom runs upstream defaults. Overriding argv directly is the only form
> immune to that. It also keeps us out of a pacman `backup=` file, so an `earlyoom` upgrade
> can never park a `.pacnew` beside your settings.
>
> The empty `ExecStart=` line is required — it *resets* the list. Without it systemd refuses
> the unit with "more than one ExecStart= setting".

> **NB — the `--avoid` list is load-bearing, and it was actively dangerous after the move.**
> It used to name `kwin_wayland|plasmashell|kded6|krunner|sddm` — five processes that do not
> exist here. **An avoid-list naming only dead processes protects nothing**, so earlyoom's
> first kill under pressure would have been as likely to be `niri` as the runaway Node
> process, taking the whole session with it. That converts your OOM protection into an OOM
> cause.
>
> And note `xwayland-satell`, not `xwayland-satellite`: earlyoom matches
> `/proc/<pid>/comm`, which the kernel truncates to **15 characters**. The 18-character name
> would never match. `Isolated Web Co` in the `--prefer` list is the same trap, already
> worked around.

Because a silently-ignored config is the exact failure this design avoids, verify from the
**kernel**, never by reading back the file you wrote:

```bash
sudo systemctl enable --now earlyoom
tr '\0' ' ' < /proc/$(systemctl show -p MainPID --value earlyoom)/cmdline
# must contain --avoid ... niri ...
```

`scripts/doctor.sh` runs exactly this check.

> Running both oomd and earlyoom is fine - they trigger on different signals. **Measured, though: in 8 days on the old machine there was exactly one OOM kill and it was earlyoom's**, not oomd's. Combined with the fact that Arch does not enable `systemd-oomd` at all by default, treat earlyoom as the one that actually fires and oomd as the PSI-based second opinion. earlyoom exists for the cases oomd misses.

### 🧊 Layer 3 — cap Docker so it can never eat the machine

**Drop Docker Desktop.** On Linux it runs your containers inside a QEMU VM with a fixed memory allocation — you pay for the VM's RAM whether containers use it or not, typically 2–4 GB gone before you start. Docker Engine runs containers natively on your kernel with essentially zero overhead. On 16 GB this is the single biggest win available to you.

```bash
sudo pacman -S --needed docker docker-buildx docker-compose containerd
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
newgrp docker
```

Daemon config — caps log growth and enables build cache GC:

```bash
sudo nano /etc/docker/daemon.json
```

```json
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "storage-driver": "overlay2",
  "builder": {
    "gc": { "enabled": true, "defaultKeepStorage": "10GB" }
  },
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Soft": 65536, "Hard": 65536 }
  }
}
```

```bash
sudo systemctl restart docker
```

**No SELinux here.** Arch does not ship an SELinux policy, so the `:Z` / `:z` relabel flags this guide used to require are unnecessary. They are accepted and ignored, so old compose files copied across are harmless — just meaningless. Do not cargo-cult them into new ones.

Replace Docker Desktop's GUI with something that costs ~15 MB:

```bash
sudo pacman -S --needed lazydocker   # in extra, no AUR needed
```

#### 🩸 The nopCommerce / SQL Server trap

This is very likely what was killing you. **SQL Server in a container reads the *host's* total RAM and helps itself to ~80% of it.** It doesn't know it's in a container. On your 16 GB machine that's SQL Server deciding it owns 12.8 GB.

Always set both the container limit *and* the SQL Server-internal limit:

```yaml
services:
  sqlserver:
    image: mcr.microsoft.com/mssql/server:2022-latest
    environment:
      ACCEPT_EULA: "Y"
      MSSQL_SA_PASSWORD: "${SA_PASSWORD}"
      MSSQL_MEMORY_LIMIT_MB: "2048"   # SQL Server's own max server memory
    mem_limit: 2560m                  # hard kernel cgroup ceiling
    memswap_limit: 2560m              # no swap escape hatch
    cpus: 2.0

  nopcommerce:
    build: .
    environment:
      DOTNET_GCHeapHardLimit: "0x20000000"   # 512 MB GC ceiling
      DOTNET_gcServer: "0"                   # workstation GC — far less RAM
    mem_limit: 1g

  redis:
    image: redis:alpine
    command: redis-server --maxmemory 256mb --maxmemory-policy allkeys-lru
    mem_limit: 320m
```

Two .NET flags worth knowing outside Docker too: `DOTNET_gcServer=0` switches from Server GC (one heap per core = 8 heaps on your i5) to Workstation GC. For local dev this alone often halves a .NET process's footprint.

Set defaults for every project via `~/.zshrc`:

```bash
export DOTNET_gcServer=0
export DOTNET_TieredPGO=1
```

#### Microservices: run only what you need

```bash
docker compose up -d gateway auth-service postgres   # not `up -d`
docker compose --profile core up -d                  # if you define profiles
```

Add profiles to your compose file so `up` doesn't start all fifteen services:

```yaml
services:
  reporting-service:
    profiles: ["full"]
```

### 🅰️ Angular / Nx tuning

Node's default heap on a 16 GB box is ~4 GB per process, and Nx will happily spawn one per core. That's how you get to 95%.

In `~/.zshrc`:

```bash
export NODE_OPTIONS="--max-old-space-size=3072"
export NX_DAEMON=true
```

In your workspace `nx.json`:

```json
{
  "parallel": 2,
  "cacheDirectory": ".nx/cache",
  "tasksRunnerOptions": {
    "default": {
      "options": { "parallel": 2 }
    }
  }
}
```

- `nx build myapp --parallel=2` — never leave it at the default 3+ on 4 cores
- Jest: `--maxWorkers=2` (or `50%`) in `jest.config.ts`
- `nx reset` when the daemon starts misbehaving or ballooning
- `ng serve` one app at a time; if you need two, give each `--port` and accept the cost
- Watch mode is the memory hog, not the build — `nx build` then serve statically when you're only checking output

### 🚨 Layer 4 — the escape hatch

Even with all of the above, one day you'll paste a bad `docker run`. Know these three:

**1. Magic SysRq — instant OOM kill (enabled in Layer 1b)**
Hold **Alt + PrtSc** and press **F**. The kernel immediately kills the largest memory consumer. On the T490s, PrtSc sits between right Alt and right Ctrl. This works even when the GUI is completely frozen, because it's handled in the keyboard interrupt path. Practise it once now so you don't fumble it under pressure.

**2. Drop to a TTY**
**Ctrl + Alt + F3** → log in → `btop` or `pkill -9 node`. A TTY needs almost no memory to render, so it usually responds when the compositor won't.

> **NB — recovery is different under niri, and worse in one specific way.** On Plasma, a
> crashed shell left the compositor running and `systemctl --user restart
> plasma-plasmashell` got your session back. niri *is* the compositor: if it dies, the
> session goes with it. What you can recover in place is the **shell** — because this repo
> runs Noctalia as a supervised systemd user unit rather than a `spawn-at-startup` child:
> ```bash
> systemctl --user restart noctalia.service
> ```
> If you had started it from `spawn-at-startup`, nothing would restart it and the TTY would
> be your only route. That is the practical payoff of the unit.

**3. Run risky builds inside a cage — the best habit here**

```bash
capped() { systemd-run --user --scope -p MemoryMax=6G -p MemoryHigh=5G -p MemorySwapMax=2G "$@"; }
```

Then `capped nx build my-monorepo --parallel=2`. If it exceeds 6 GB it gets killed and *nothing else on the system is affected*. Add that function to `~/.zshrc` and use it for every full-monorepo build. This is the difference between "my build failed" and "I lost 20 minutes to a hard reboot."

**4. See where memory is actually going**

```bash
systemd-cgtop -m            # memory by cgroup/slice — shows you docker vs your session
btop                        # general
docker stats                # per container
ps aux --sort=-%mem | head  # per process
```

### 🧹 Layer 5 — what you no longer have to reclaim

This section used to be sixty-six lines of removal work. On CachyOS + niri most of it is
**prevented rather than reclaimed**, and that inversion is the interesting part — it is the
clearest single argument for a minimal session.

| Old target | What it cost on Fedora KDE | Status here |
|---|---|---|
| KDE PIM / Akonadi | **507 MB across 16 processes and a MySQL database, for zero mail accounts** | Never installed. Not a task. |
| Baloo | indexed every `node_modules` tree it could find — sustained CPU, RAM and SSD writes | Does not exist |
| PackageKit | 200–300 MB resident, woken periodically by Discover | Not installed; pacman has no resident daemon |
| `abrtd` and friends | Fedora-only crash reporting | Does not exist — but see `systemd-coredump` below |
| Discover notifier | measured at 24 MB resident / **350 MB swapped** | Not installed |

That Akonadi number is worth keeping as history rather than instruction: **507 MB for zero
mail accounts** is the most memorable measurement in this guide, and it is why the default
posture here is "install the session, not the desktop environment".

**What Arch has instead is a disk problem Fedora never had**, and this is what
`scripts/reclaim.sh` now targets:

- **The pacman package cache.** `dnf` defaults to `keepcache=False`; pacman keeps **every
  version of every package it has ever installed, forever**. Routinely 5–20 GB. `paccache
  -rk2` trims it and `paccache.timer` (enabled by `system/apply.sh`) keeps it trimmed.
- **Orphaned packages** — dependencies whose parent is gone. `pacman -Qtdq`. Nothing removes
  these automatically.
- **`systemd-coredump`.** The Arch analogue of ABRT, and a *disk* problem rather than a RAM
  one: measured **389 MB in `/var/lib/systemd/coredump` with no cap configured at all**.
  `system/systemd/coredump.conf.d/99-size-cap.conf` fixes that going forward.
  > **NB** — `ProcessSizeMax=2G` is the load-bearing key on a 16 GB box. Firefox's address
  > space is several GB; without a limit, one browser crash writes a multi-GB core to disk
  > *under the very memory pressure that caused the crash*. Over the limit the dump is
  > skipped rather than truncated, which is what you want — a truncated core is useless
  > anyway.
- **Docker.** 9.08 GB of images (2.74 GB reclaimable) plus **7.49 GB of build cache, 100%
  reclaimable**. `daemon.json`'s `builder.gc` caps the build cache; dangling images and
  stopped containers are not covered by it.

**Still needed, unchanged:** the journal cap
(`system/journald.conf.d/99-size-cap.conf`) — without it the journal grows to the
10%-of-`/var` default, which on a 238 GB disk is ~4 GB of logs nobody reads.

**Terminal scrollback** moved from Konsole to Ghostty: `scrollback-limit = 2000000` in
`~/.config/ghostty/config.ghostty`. Unlimited scrollback across ten tabs of Docker logs is a
genuine leak — though note Ghostty's *default* is already a bounded 10 MB, so this is a
tightening rather than a fix, and the setting is in **bytes**, not lines.

**Do not** chase compositor micro-optimisations. The reasoning that applied to KWin applies
to niri: the UHD 620 handles compositing in hardware for near-zero cost, and turning effects
off saves single-digit MB while making the desktop feel worse. (This config already disables
shadows and blur — but for a different reason: 3456×1080 logical pixels across two heads on
an integrated GPU is a frame-rate budget, not a memory one.)

> **NB — do not disable `ananicy-cpp` or `scx_loader`/`scx-scheds`.** CachyOS ships these
> deliberately: they are the auto-nice daemon and the `sched_ext` scheduler that make the
> machine feel responsive under load. They look like cruft in a service list and they are
> not. Removing them is a regression, not a reclaim.

### 📊 Your realistic 16 GB budget

| Component | Measured on Fedora KDE, 2026-09 | Expected on CachyOS + niri |
|---|---|---|
| Desktop session, idle | **0.58 GiB** | 0.25–0.40 GiB — *re-measure and fill in* |
| Firefox, real working set | **8.13 GiB** (4.65 resident + 3.48 held in zram) | unchanged — these are your pages, not your DE |
| VS Code + TS language server on Nx monorepo | 1.5–3.0 GB | unchanged |
| SQL Server container (capped) | 2.5 GB *when running* | unchanged |
| nopCommerce .NET (workstation GC) | 0.5–1.0 GB | unchanged |
| Postgres + Redis + gateway | 0.7 GB | unchanged |
| Docker daemon + containerd | 0.3 GB | ~0 when idle, with `docker.socket` activation |

**It does not fit, and it has not been fitting.** That is the finding, and the old version of
this table hid it in two directions at once: it claimed Plasma idled at 1.2–1.5 GB when the
whole session measured **0.58 GiB**, and it put Firefox at 3.5–5.5 GB when the real working
set was **8.13 GiB**. It was wrong by roughly 2× about the desktop and by ~3 GB about the
browser, and both errors pointed attention at the wrong component.

Firefox alone is **53% of the 15.3 GiB this machine actually has**. The reason the machine
still feels fine is that **3.48 GiB of Firefox is not in RAM at all** — it is compressed in
zram at 3.79:1, costing about 0.92 GiB of physical memory. zram is not a safety margin here.
It is load-bearing, permanently, every day. That is worth knowing before you ever set
`vm.swappiness` back to something "sensible".

Two consequences for how you read the rest of this guide:

- The desktop swap from Plasma to niri + Noctalia is worth a few hundred megabytes. Real,
  and worth doing — but if you came here expecting the window manager to be the fix, you are
  tuning the wrong thing.
- The SQL Server cap and the Node heap limit are not optimisations. Without them SQL Server
  alone claims 12.8 GB against a budget that is already over.

---

## 🚀 Phase 5: Applications

### 󰞵 Core dev tools & CLI

**Do not hand-copy a package list into this guide.** The authoritative list is
`packages/*.tsv` and `bootstrap.sh` installs it — a duplicate list in prose is exactly how
this document drifted out of sync with the machine last time.

```bash
./bootstrap.sh          # resolves packages/*.tsv, then pacman -Syu + paru
```

Two things worth knowing about that resolution:

- **`starship` and `chezmoi` are real repo packages on Arch.** On Fedora they were manual
  installs — `starship` was marked `-` in `packages/core.tsv` and bootstrap fell back to
  piping the upstream installer into `sh`, dropping a binary in `/usr/local/bin`. Both of
  those special cases are gone, and `pkg_unavailable arch` now returns **nothing**.
- **Exactly two packages come from the AUR**: `visual-studio-code-insiders-bin` and
  `vesktop-bin`, plus the Maple Mono NF font. They are declared in a separate `aur` column and
  installed in their own `paru` transaction, so one failed build cannot take the other ~90
  repo packages down with it.

Postgres needs initialising if you run it on the host rather than in Docker:

```bash
sudo postgresql-setup --initdb
sudo systemctl enable --now postgresql
```
> Honestly: for your workload, run Postgres in Docker instead and skip the host install entirely. One less always-on service.

### 🦊 Firefox

Use the **repo package**, not the Flatpak — it has VA-API hardware video decode wired up against the system ffmpeg, while the Flatpak sandboxes its own codec-limited copy.

```bash
sudo pacman -S --needed firefox
```

> **Firefox is still the right pick on a 16 GB dev box** — but the reason given here originally was wrong, and it is worth correcting because it led to a useless config.
>
> The old claim was "Firefox caps content processes (8 by default) and shares them across tabs." That has not been true since **Fission** (site isolation) became the default. Fission allocates a content process per *site*, not from a fixed pool, so `dom.ipc.processCount` no longer bounds anything. Measured on this machine at Firefox 154: **13 tabs → 22 content processes**, with `dom.ipc.processCount` pinned to 4. The pref was doing nothing.
>
> Measured cost of a real working set (13 tabs, 2 windows): **5.6 GiB PSS**, of which the four largest content processes were 598 / 583 / 456 / 446 MB. None of that is a leak — each was a genuine long-lived SPA (Teams, WhatsApp Web, Gmail, Docs, Claude, Linear). **A dozen web apps cost roughly what a dozen native apps cost.** Budget for it rather than expecting a pref to fix it.
>
> Measure it yourself with PSS, never RSS — see the warning under *Diagnosing it* below.

#### Memory settings

Don't hand-edit `about:config`. Run **`scripts/firefox-tune.sh`**, which installs `firefox/user.js` into every profile on the machine (the profile directory has a random prefix, so chezmoi can't target it). Prefs take effect at the **next Firefox launch**.

| Preference | Set to | Why |
|---|---|---|
| `browser.sessionhistory.max_total_viewers` | `2` | The big one. Default `-1` means "derive from RAM", which hits the formula's ceiling of **8**. A "viewer" is a fully rendered, still-live page kept for instant Back. |
| `browser.sessionstore.max_tabs_undo` | `5` | Default 25 *per window*. This profile was retaining 50 closed tabs, all held by the parent process. |
| `browser.sessionstore.max_windows_undo` | `1` | Default 5. Same story. |
| `browser.tabs.unloadOnLowMemory` | `true` | Firefox's Memory Saver equivalent. |
| `browser.sessionstore.interval` | `60000` | Session saves every 60s instead of 15s — fewer NVMe writes. |
| `dom.ipc.processCount` | `8` (shipped default) | **A dead letter under Fission** — see the correction above. Reset *explicitly*, not deleted: removing a line from `user.js` does **not** unset the pref, because the old value is already saved in `prefs.js` and outlives it. |
| `dom.ipc.processCount.webIsolated` | `2` | The Fission-era equivalent (default 4) = max processes *per site*. Honest scope: with 13 tabs on 13 domains this changes nothing; it only guards the many-tabs-of-one-site case. |

Realistically these reclaim a few hundred MB of *overhead*. They cannot shrink the pages themselves. **The ceiling that actually protects the rest of the system is the cgroup cap**, below.

#### The cap that actually matters

Firefox has no "use at most N GB" setting, so the ceiling has to come from outside it. On
this machine that ceiling is **6 GiB of `MemoryHigh` on Firefox's own cgroup** — and both
*how* it is applied and *what it costs* changed with the move off Plasma. Read both halves.

##### Getting Firefox into its own cgroup

Under Plasma this was free: KDE's KProcessRunner launched every `.desktop` app as a transient
systemd user unit named `app-<desktop-id>@<hex>.service`, so Firefox already had a private
cgroup and a drop-in on the *template* unit applied to every instance.

**niri does not do this**, and the failure is silent. niri's shipped unit sets
`Slice=session.slice`, so applications it spawns are direct children of the compositor and
inherit *its* cgroup. No `app-*.service` is ever created, the drop-in matches nothing, and
you have no cap.

> **NB — this is the worst class of config failure, because everything still looks correct.**
> The drop-in file is present, `systemctl --user daemon-reload` succeeds, `chezmoi` reports
> it applied, and the cap does not exist. You would believe you had a 6 GiB ceiling on the
> single largest process on the machine, and you would not. Nothing logs it.
>
> The check that actually proves it — and the reason `scripts/doctor.sh` prints the cgroup
> path as a note rather than just a pass/fail:
> ```bash
> cat /proc/$(pgrep -x firefox | head -1)/cgroup
> ```
> A path ending in `session.scope` or `niri.service` means there is no per-app cap. You want
> to see an `app-…firefox….service` path.

There are two working answers, and this repo ships both:

| | How | When |
|---|---|---|
| **Wrapper** | `~/.local/bin/firefox-capped` runs `systemd-run --user --scope --slice=app.slice -p MemoryHigh=6G`, and a shadowing `~/.local/share/applications/firefox.desktop` points every launch path at it | Default. Works on any compositor, needs nothing installed, and can be tested before you commit to anything |
| **uwsm** | `uwsm start -S -F -- niri.desktop` with `UWSM_APP_UNIT_TYPE=service` recreates real per-app units — `app-niri-firefox@<hex>.service` — so the original drop-in works unchanged | Preferred once you are on CachyOS. Also restores per-app cgroups for VS Code, node and dotnet, which the wrapper does not |

**Use one or the other, never both.** Under uwsm the wrapper would produce a unit named
`app-niri-firefox-capped@…`, which a `firefox` drop-in would not match.

The `.desktop` shadow matters more than it looks: pointing only the `Mod+B` keybind at the
wrapper would leave the Noctalia launcher, `xdg-open` and portal hand-offs uncapped. And the
`Exec=` line must be an **absolute** path — `~/.local/bin` is on the *shell's* `PATH`, which
a launcher or a portal does not inherit.

##### What the cap actually costs

`MemoryHigh` **throttles and reclaims**; it does not kill. Over the line the kernel pushes
Firefox's coldest pages out until it fits, and zram takes them at **3.79:1 with zstd**, so
reclaimed memory costs about a quarter of its size. That is why this is cheap *on this
machine specifically*, and it is the same reasoning behind `vm.swappiness = 180`.

> **NB — an earlier revision of this guide told you to run
> `grep '^high' memory.events  # 0 = never throttled yet`, framing the cap as a safety net
> you would probably never touch. That was measured and it is false.** On the old machine:
> **~114,000 `high` events in 8 hours** — roughly four per second, sustained — against
> **7.2 million major faults**, with an 8.13 GiB working set held under a 6 GiB cap.
>
> This is not a ceiling you occasionally brush. It is a **permanently engaged throttle**, and
> it has been running that way every day. The machine feels fine *because* of it, not
> despite it.

Be careful about what those 7.2M major faults cost, and do not let this guide overclaim.
Under zram-only swap, a swap-in counts as `pgmajfault` even though it never touches the NVMe
— that half is a zstd decompression, microseconds, exactly as promised above. But
file-backed pages (libxul and friends) evicted under the same pressure *are* re-read from
the SSD, at millisecond cost and against a consumer NVMe's write-endurance budget. Get the
split rather than guessing:

```bash
grep -E '^(pswpin|pgmajfault)' /proc/vmstat
# the gap between them is the file-backed re-read
```

So treat this as a decision with measured inputs, not a solved problem:

- **Raise the cap toward 8G** and accept that Firefox owns over half the machine.
- **Keep 6G** and accept ~114k throttle events plus the NVMe traffic.
- **Cut the working set** — which is what item 1 of "If you do only five things" now says,
  and the only option that actually changes the arithmetic.

Two things the cap does **not** do, so a quiet no-op is not mistaken for success:

- It makes the *kernel* reclaim pages. It does **not** make Firefox free anything.
  `browser.tabs.unloadOnLowMemory` polls system-wide `MemAvailable` and is **not
  cgroup-aware**, so it will never fire because of this cap. Knowing the cap fires constantly
  makes that caveat more important, not less.
- It is per-cgroup. If the cgroup is wrong, everything above is theatre — which is why the
  `/proc/<pid>/cgroup` check comes first.

#### Diagnosing it

`about:processes` gives a live per-tab breakdown — genuinely better than anything Chromium offers. `about:unloads` shows discard order.

> ⚠️ **Never sum `ps` RSS for a multi-process browser.** RSS counts every shared page in full against *every* process mapping it, so a 25-process Firefox double-counts libxul and the shared JS runtime ~25 times. This guide's own doctor check did exactly that and reported **8.3 GB** where the system monitor said **5.6 GB**. Use PSS, which divides each shared page by its sharer count:
> ```bash
> for p in $(pgrep -f /usr/lib64/firefox/firefox); do
>   awk '/^Pss:/{print $2}' /proc/$p/smaps_rollup 2>/dev/null
> done | awk '{s+=$1} END {printf "%.2f GiB\n", s/1048576}'
> ```

#### Extensions are not free

An extension holding `<all_urls>` injects a content script into **every** content process, so its cost scales with tab count rather than with how often you use it. This profile had **10 of 20** extensions on `<all_urls>`, plus a 173 MB `WebExtensions` process. `scripts/doctor.sh` reports the ratio. Audit anything on that list you don't use daily — and drop the ones Firefox or Plasma already do natively (screenshots, picture-in-picture, media keys via Plasma Integration).

#### Hardware video acceleration

Firefox on Wayland enables VA-API by default now. Verify at **`about:support` → Graphics** — look for `HARDWARE_VIDEO_DECODING: available` and `Compositing: WebRender`. If it says software, confirm `vainfo` still works from Phase 3 and that `media.ffmpeg.vaapi.enabled` is `true`.

#### What you lose without Plasma Integration

`plasma-browser-integration` has no niri equivalent, and it is worth naming what goes rather
than pretending otherwise: media controls in the panel and on the lock screen, downloads
surfaced as desktop notifications, and open tabs searchable from the launcher.

Noctalia's media widget picks up anything exposing MPRIS, which covers Firefox's own media
sessions — so the panel controls largely come back. Tab search does not. Do not install the
add-on: without its native host it does nothing but add an `<all_urls>` extension to the
count, which is the opposite of what the section above is asking you to do.

#### Extensions — your list, ported

Direct Firefox equivalents exist for nearly all of them:

**Install:** uBlock Origin · Bitwarden · Tampermonkey · SponsorBlock · Return YouTube Dislike · Enhancer for YouTube · Cookie Editor · Proton VPN · Wappalyzer · Privacy Badger · To Google Translate · Buster Captcha Solver

**Drop these:** Decentraleyes (dead project — modern cache partitioning made it redundant), Disconnect, and Don't Track Me Google. On Firefox, uBlock Origin runs with **full MV2 `webRequest` blocking**, which Chromium removed. It genuinely covers what those three did, and Firefox's built-in Enhanced Tracking Protection (Settings → Privacy → **Strict**) covers the rest. That's four fewer background processes.

**Add for your work:** Angular DevTools (yes, it's on addons.mozilla.org — no Chromium needed), React DevTools if relevant, and **Multi-Account Containers** for keeping client/staging/prod logins separate without separate profiles.

Then import your Tampermonkey userscripts, and sign into Firefox Sync or import your Bitwarden vault.

### 󰳕 Editors

```bash
paru -S visual-studio-code-insiders-bin
sudo tee /etc/yum.repos.d/vscode.repo > /dev/null <<'EOF'
```bash
paru -S visual-studio-code-insiders-bin
```

> **NB — this is one of only two AUR packages in the whole manifest, and it deserves one
> moment of thought.** On Fedora you were implicitly trusting a Microsoft-signed yum repo;
> here you are trusting a build script maintained by a third party. `paru` shows you the
> PKGBUILD before building — `bootstrap.sh` passes `--skipreview` so unattended runs do not
> block on a pager, so read it once by hand the first time. `packages/dev.tsv` declares it in
> a separate `aur` column precisely so this is visible rather than buried in a package list.

**Essential VS Code settings for Nx monorepos** — without these the file watcher and search index will eat a gigabyte on their own:

```json
{
  "files.watcherExclude": {
    "**/node_modules/**": true,
    "**/.nx/**": true,
    "**/dist/**": true,
    "**/.angular/**": true,
    "**/bin/**": true,
    "**/obj/**": true
  },
  "search.followSymlinks": false,
  "search.exclude": {
    "**/node_modules": true,
    "**/dist": true,
    "**/.nx": true
  },
  "typescript.tsserver.maxTsServerMemory": 3072,
  "typescript.disableAutomaticTypeAcquisition": true,
  "extensions.autoUpdate": false
}
```

**Zed** as a lightweight alternative — you already had it on Windows, and for quick edits it starts in ~200 MB versus VS Code's 800 MB+:

```bash
curl -f https://zed.dev/install.sh | sh
```

### 💬 Chat & Social

```bash
paru -S vesktop-bin
```

> **NB — take the `-bin`.** The plain `vesktop` package builds Electron from source with
> pnpm: 30–60 minutes on 4 cores, and multiple GB of RAM while it runs. On this machine that
> build can itself trip the OOM protections Phase 4 just installed.

For **LinkedIn, Reddit, WhatsApp, X, YouTube Music, Figma, ChatGPT, Claude** — this is the one place Firefox costs you something. **Mozilla removed site-specific browser / PWA install support**, so there's no "Install page as app" menu item. Three options, best-first for your machine:

**1. Pinned tabs (recommended).** Right-click tab → **Pin Tab**. They persist across restarts, sit as small icons on the left, and — critically — **share Firefox's existing content processes**. Marginal cost per pinned tab is 50–150 MB rather than a whole new browser instance. On 16 GB this is far and away the right answer.

**2. PWAsForFirefox** — if you specifically want dock icons and separate windows:

```bash
paru -S firefox-pwa
```

Then install the companion extension from addons.mozilla.org. It creates real `.desktop`
entries that show up in the Noctalia launcher. Each site runs in its own profile, so budget ~200 MB apiece — cheaper than Chromium PWAs, still not free.

**3. Keep a minimal Chromium** just for PWAs (`sudo pacman -S chromium`). Only worth it if some site is genuinely broken in Firefox. It costs you a second browser engine in RAM, which defeats the point of switching.

> Whichever you pick: six always-open web apps is 1–1.5 GB permanently gone. Pin your three most-used, bookmark the rest.

### 🧩 Flatpak — deliberately not used

There are **no flatpaks installed on this machine**, and that is a decision rather than an
oversight. With the AUR available, the "only where the repo package is worse" case that
justified Flatpak on Fedora almost never comes up, and each Flatpak carries its own runtime
copy — which on a 16 GB / 238 GB box is a cost with no matching benefit.

If you do install one later, remember to add `flatpak update` and
`flatpak uninstall --unused` back into `update-all` in Phase 8; they were removed because
they fail on a machine with no `flatpak` binary.

---

## 💻 Phase 6: Terminal & Shell

### 🔤 Install Maple Mono

```bash
mkdir -p ~/.local/share/fonts
cd /tmp
curl -LO https://github.com/subframe7536/maple-font/releases/latest/download/MapleMono-NF-unhinted.zip
unzip -o MapleMono-NF-unhinted.zip -d ~/.local/share/fonts/MapleMono
fc-cache -fv
```

### 🖥 Ghostty

Ghostty is now *the* terminal, and it is configured at
`~/.config/ghostty/config.ghostty` (chezmoi-managed) rather than through a settings dialog.

> **NB — a small archaeology lesson worth keeping.** Ghostty was installed, chezmoi-managed
> and described in this guide as "the lighter of the two" for months — while **Konsole was
> what actually got used every day**. The reason turned out to be that the config set a font
> and *nothing else*: no theme. So Ghostty opened in its stock palette while the shell inside
> it hard-coded Catppuccin Latte's light-background hexes, and it simply looked wrong.
> Theming it was not polish; it was the thing that made it usable. Assume any config you have
> never actually looked at is in this state.

What it now sets, with the Konsole profile's settings ported across before that file was
deleted:

| Setting | Value | Was |
|---|---|---|
| `theme` | `catppuccin-latte` | *nothing* — bundled with Ghostty, no external file needed |
| `font-family` / `font-size` | Maple Mono NF, 10 | same (the guide previously said 11pt; the profile said 10) |
| `font-feature` | 16 stylistic sets | matches `editor.fontLigatures` in the VS Code settings exactly |
| `window-width` / `window-height` | 125 × 30 | Konsole `TerminalColumns`/`TerminalRows` |
| `cursor-style` | `bar` | Konsole `CursorShape=1` |
| `command` | `/bin/zsh` | same |
| `scrollback-limit` | 2000000 | Konsole `HistorySize=10000` *lines* |
| `window-decoration` | `server` | pairs with niri's `prefer-no-csd` |

> **NB — `scrollback-limit` is in BYTES, not lines**, despite the name, and Ghostty's
> *default* is already a bounded 10 MB. So writing `10000000` would be a silent no-op — the
> value simply matches the default and disappears from `ghostty +show-config`. 2 MB is the
> honest port of Konsole's 10k lines, and it is a tightening rather than a fix. Ghostty 1.4
> splits this into `scrollback-limit-bytes` / `-lines`; switch to
> `scrollback-limit-lines = 10000` then.

### 🐚 Zsh + Starship

```bash
# Starship
curl -sS https://starship.rs/install.sh | sh

# Set zsh as login shell
chsh -s "$(command -v zsh)"

# Oh My Zsh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

# Plugins
git clone https://github.com/zsh-users/zsh-autosuggestions.git \
  ~/.oh-my-zsh/custom/plugins/zsh-autosuggestions
git clone https://github.com/zsh-users/zsh-completions.git \
  ~/.oh-my-zsh/custom/plugins/zsh-completions
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git \
  ~/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting

# Catppuccin syntax highlighting theme
mkdir -p ~/.zsh
curl -fLo ~/.zsh/catppuccin_latte-zsh-syntax-highlighting.zsh \
  https://raw.githubusercontent.com/catppuccin/zsh-syntax-highlighting/main/themes/catppuccin_latte-zsh-syntax-highlighting.zsh

# Starship config
mkdir -p ~/.config && touch ~/.config/starship.toml
```

### `~/.zshrc`

```bash
export ZSH="$HOME/.oh-my-zsh"
plugins=(git z docker docker-compose zsh-autosuggestions zsh-completions zsh-syntax-highlighting)
fpath+=${ZSH_CUSTOM:-${ZSH:-$HOME/.oh-my-zsh}/custom}/plugins/zsh-completions/src

source $ZSH/oh-my-zsh.sh
source ~/.zsh/catppuccin_latte-zsh-syntax-highlighting.zsh
eval "$(starship init zsh)"

# ---- Memory-conscious dev environment ----
export NODE_OPTIONS="--max-old-space-size=3072"
export NX_DAEMON=true
export DOTNET_gcServer=0
export DOTNET_CLI_TELEMETRY_OPTOUT=1

# Run a command in a memory-capped cgroup — use for heavy builds
capped() { systemd-run --user --scope -p MemoryMax=6G -p MemoryHigh=5G -p MemorySwapMax=2G "$@"; }

# ---- Aliases ----
alias cat='bat --paging=never'
alias top='btop'
alias ls='eza --icons --group-directories-first'
alias ll='eza -l -a --icons --git --group-directories-first'
alias la='eza -la --icons --git --group-directories-first'
alias lt='eza --tree --level=2 --git-ignore'
alias lS='eza --oneline'
alias help='tldr'
# NOTE: do NOT alias fd here. The package installs the binary as `fd` already;
# `fdfind` is the Debian/Ubuntu name and does not exist here. Aliasing it breaks a
# working command with `fdfind: command not found`.

# ---- Memory & Docker helpers ----
alias mem='free -h && echo && zramctl'
alias memhogs='ps aux --sort=-%mem | head -12'
alias cgtop='systemd-cgtop -m'
alias dps='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
alias dstats='docker stats --no-stream'
alias dprune='docker system prune -f && docker builder prune -f'
# NB: no --volumes and no -a, deliberately. `docker system prune` removes stopped
# containers FIRST, which orphans their named volumes; --volumes then deletes those
# orphans in the same command, and -f means no prompt. On this machine that is the
# Postgres, MinIO and Keycloak data. `-a` separately removes every image not backed
# by a RUNNING container. The old version of this alias had both flags.
alias lzd='lazydocker'
alias nxr='nx reset'
```

```bash
rm -f ~/.zcompdump*
exec zsh
tldr --update
```

### 🔧 Git Configuration

```bash
git config --global user.name "Sharif Md. Yousuf"
git config --global user.email "sharifmdyousuf007@gmail.com"
git config --global init.defaultBranch main
git config --global pull.rebase true
git config --global core.editor "code-insiders --wait"

# Big monorepos: these three make git noticeably faster
git config --global core.fsmonitor true
git config --global core.untrackedCache true
git config --global feature.manyFiles true

# SSH key
ssh-keygen -t ed25519 -C "sharifmdyousuf007@gmail.com"
gh auth login
```

---

## ⚙️ Phase 7: niri + Noctalia

Phase 7 used to be a list of places to click in System Settings. It is now a list of files,
all of them in this repo, all version-controlled. That is a straight upgrade: the old Phase 7
could not be applied by `bootstrap.sh` and this one can.

> **The biggest adjustment in this whole migration is not technical.** `kwinrc` on the old
> machine reported `[Desktops] Number=1` — one virtual desktop, two monitors, windows placed
> by hand. niri is a *scrollable-tiling* compositor built around an infinite horizontal strip.
> Expect the window model, not the distro, to be the thing that takes a week.

### 🗂 The files

| File | What it owns |
|---|---|
| `~/.config/niri/config.kdl` | input, layout, window rules, environment, startup |
| `~/.config/niri/outputs.kdl` | the display geometry — the one file hardware changes touch |
| `~/.config/niri/binds.kdl` | keybindings |
| `~/.config/noctalia/config.toml` | bar, launcher, theme mode, templates |
| `~/.config/noctalia/palettes/CatppuccinLatte.json` | the pinned palette |
| `~/.config/systemd/user/noctalia.service` | supervision for the shell (see below) |
| `~/.config/xdg-desktop-portal/niri-portals.conf` | portal arbitration |
| `~/.config/environment.d/50-wayland.conf` | session-wide environment |

`niri validate` checks the config; niri also hot-reloads it on save, so iteration is fast.

### 🖥 Outputs — the fiddly part

```kdl
output "eDP-1"     { mode "1920x1080@60.000"; scale 1.25; position x=0    y=216 }
output "HDMI-A-2"  { mode "1920x1080@60.000"; scale 1.0;  position x=1536 y=0   }
```

> **NB — those two numbers are arithmetic, not taste, and they look arbitrary enough that
> someone will "fix" them.** Positions are in *logical* pixels. `eDP-1` at scale 1.25 is
> 1920 / 1.25 = **1536** logical wide, so the external starts at x=1536; using 1920 leaves a
> 384px dead zone the pointer gets stuck in. And 1080 − 864 = **216** bottom-aligns the
> shorter internal panel against the taller external.

Mixed fractional scaling across two heads is the highest-risk part of this config on an
integrated GPU. Test hotplug in both directions, and check that XWayland clients are not
blurry on the scaled head.

### ⌨️ Keybindings

The actions worth keeping from Plasma survived: `Mod+L` locks, `Ctrl+Alt+Del` opens the
session panel, and the media keys keep their behaviour — including `Shift`+volume for 1%
steps and `allow-when-locked=true` so they work on the lock screen.

> **NB — one real conflict, resolved deliberately.** Vim-style tiling would put
> `focus-column-right` on `Mod+L`, but `Mod+L` has been "lock the screen" for years. The
> home-row pair here is therefore `Mod+H` / `Mod+Semicolon`, with the arrow keys doing the
> same job. If you would rather have `hjkl`, move lock to `Mod+Escape` in `binds.kdl`.

Screenshots need no package: niri has `screenshot`, `screenshot-screen` and
`screenshot-window` built in, bound to `Print`, `Ctrl+Print` and `Alt+Print`. `grim`/`slurp`
are installed only for scripted captures.

### 🧩 Noctalia, and the config layer that beats yours

Noctalia loads three layers: built-in defaults, then `~/.config/noctalia/config.toml`, then
**`~/.local/state/noctalia/settings.toml`, written by the Settings GUI — which loads last and
wins.** A value you set in the file this repo manages can be silently overridden by something
you clicked once, months ago.

Do not fight it. Noctalia *removes* a GUI key when its value matches the layer below, so
`settings.toml` self-prunes to exactly what diverges — which makes it an accurate drift
signal rather than noise. The workflow:

```bash
noctalia config export > /tmp/merged.toml
diff /tmp/merged.toml ~/.config/noctalia/config.toml   # promote what you want to keep
chezmoi re-add ~/.config/noctalia/config.toml
rm ~/.local/state/noctalia/settings.toml               # clears all GUI overrides
```

`scripts/doctor.sh` warns whenever that file is non-empty, so it never goes unnoticed.

**Noctalia gets a hand-written systemd user unit**, because its package ships none. Started
from `spawn-at-startup` it would be an unsupervised child of the compositor: nothing restarts
it when it crashes, and there is no unit to attach `ManagedOOMPreference=avoid` to. Since
Noctalia *is* the bar, the launcher, the notifications, the OSD and the lock screen, losing
it means losing all of them at once with only a TTY to recover from.

```bash
systemctl --user add-wants niri.service noctalia.service
```

### 🖼 GTK and Qt — the rule that inverted

The old version of this section argued at length that KDE themed GTK for free — that
`kde-gtk-config`'s `gtkconfig.so` rewrote `~/.config/gtk-{3,4}.0/` and `~/.gtkrc-2.0` from
the live colour scheme on every change (verified at the time: all four files rewritten within
milliseconds of each other at login), and therefore that you must **never** version-control
those paths.

**Every word of that was right for Plasma, and every word of it is now wrong.** There is no
kded and nothing regenerates anything. Left unmanaged, GTK apps sit on default Adwaita
forever — the same symptom the old note warned about, arriving from the opposite direction.

The ownership split now:

- **Noctalia owns colour.** Its `gtk3`/`gtk4`/`qt6ct` templates write `noctalia.css` and
  import it into `gtk.css`. Those generated files are in `.chezmoiignore`.
- **chezmoi owns everything that is not colour** — `gtk-3.0/settings.ini` and
  `gtk-4.0/settings.ini`: theme name, icon theme, font, cursor, hinting.
- **`.gtkrc-2.0` stays ignored permanently.** Nothing left after the migration is a GTK2 app.

Qt is now *also* your problem, which it never was under Plasma. After dropping the KDE apps
the survivors are OBS and Telegram, so `qt6ct` plus `QT_QPA_PLATFORMTHEME=qt6ct` covers it.
Skip Kvantum.

> **NB — do not set `GTK_THEME` in the environment.** It hard-overrides `settings.ini` and
> breaks libadwaita apps, and it is a confusing thing to debug months later.

### 🔌 Portals — three separate things depend on this

```ini
[preferred]
default=gtk
org.freedesktop.impl.portal.ScreenCast=gnome
org.freedesktop.impl.portal.Settings=gtk
org.freedesktop.impl.portal.Secret=gnome-keyring
```

- **`Settings=gtk`** serves `org.freedesktop.appearance`, which is what VS Code's
  `window.autoDetectColorScheme` reads. Without it VS Code silently stops following the theme.
- **`ScreenCast=gnome`** is what makes screen sharing work at all (Teams/Meet in Firefox,
  OBS). With no `portals.conf` present the backends race on D-Bus and you get a picker that
  works in one app and hangs in another.
- **`Secret=gnome-keyring`** replaces kwallet, which left with Plasma. `gh`, VS Code and
  anything else using libsecret talk to this.

Verify after login — this must print `2` (light):

```bash
gdbus call --session -d org.freedesktop.portal.Desktop -o /org/freedesktop/portal/desktop \
  -m org.freedesktop.portal.Settings.Read org.freedesktop.appearance color-scheme
```

### 🖱 Touchpad & TrackPoint (T490s)

Same settings as the old System Settings panel, now declarative in `input {}`: tap-to-click,
disable-while-typing, natural scroll, clickfinger.

> **NB — the TrackPoint needs its own `trackpoint {}` block.** It inherits nothing from
> `touchpad {}` — they are separate libinput devices — so without it the red nub gets stock
> settings and, in particular, no press-to-scroll. `scroll-method "on-button-down"` with
> `scroll-button 274` is the entire reason a ThinkPad has a middle button.

### ⏱️ Autostart

`spawn-at-startup` in `config.kdl`, or a systemd user unit wired in with
`systemctl --user add-wants niri.service <unit>` — niri's own unit pulls in
`xdg-desktop-autostart.target`, so `.desktop` autostart files still work too.

**The advice is unchanged and still worth following: do not autostart Vesktop or Telegram.**
That is ~700 MB at login for two things you open a few times a day.

## 🧹 Phase 8: Maintenance

### ♻️ Everything Update

```bash
sudo pacman -Syu
paru -Sua                                   # AUR packages, separately
sudo pacman -Rns $(pacman -Qtdq)            # orphans, if any
sudo paccache -rk2                          # keep 2 versions of each package
sudo fwupdmgr refresh && sudo fwupdmgr update
sudo pacdiff                                # merge .pacnew files - see the NB
```

Save it as a function in `~/.zshrc`:

```bash
update-all() {
  sudo pacman -Syu --noconfirm && \
  paru -Sua --noconfirm && \
  { pacman -Qtdq | sudo pacman -Rns - || true; } && \
  sudo paccache -rk2 && \
  docker system prune -f && \
  echo "✅ Everything updated — now run: sudo pacdiff"
}
```

> **NB — `.pacnew` files are a maintenance responsibility Fedora never imposed on you.** When
> pacman upgrades a package whose config you have edited, it does not overwrite your file —
> it parks the new vendor version alongside it as `<file>.pacnew` and says nothing further.
> Ignore those for six months and you are running a `pacman.conf`, `sudoers` or
> `mkinitcpio.conf` that has silently diverged from what the tooling expects, and it breaks
> at the worst possible moment. `pacdiff` walks them. `scripts/doctor.sh` counts them.

> **NB — never `pacman -Sy <pkg>`.** Syncing the database without upgrading, then installing
> against it, gives you a partial upgrade — the number one way to break an Arch system, and
> the usual symptom is a mismatched glibc that takes your shell with it. Always `-Syu`.

> **NB — check the CachyOS and Arch news before a large `-Syu`.** Manual-intervention
> announcements are the mechanism a rolling distro uses instead of release notes.

### ❌ Removing things

```bash
sudo pacman -Rns <package_name>     # -R remove, -n no backup files, -s unused deps
pacman -Qtdq | sudo pacman -Rns -   # orphans
```

### 🧼 Weekly Docker cleanup

Docker will quietly consume 30+ GB in dangling images and build cache:

```bash
docker system prune -af --volumes   # ⚠️ removes unused volumes too — check first
docker builder prune -af
docker system df                    # see what's actually taking space
```

### 🩺 Health check

```bash
mem                     # RAM + zram state
oomctl                  # what systemd-oomd is monitoring
journalctl -k --since "1 hour ago" | grep -i "oom\|killed process"
systemctl --failed
sudo btrfs filesystem usage /
```

### 📈 Verify the anti-freeze setup is live

Run these once after Phase 4 — all should return sensible values:

```bash
swapon --show                      # /dev/zram0, 16G
cat /proc/sys/vm/swappiness        # 180
systemctl is-active systemd-oomd   # active
systemctl is-active earlyoom       # active
cat /proc/sys/kernel/sysrq         # 1
```

---

## 🎯 Quick Reference: if it starts to freeze

| Situation | Do this |
|---|---|
| Feels sluggish, RAM at 85% | `memhogs`, close browser tabs, `docker compose stop <service>` |
| Fully frozen, no cursor | **Alt + PrtSc + F** (kills biggest process) |
| Frozen, SysRq did nothing | **Ctrl + Alt + F3**, log in, `pkill -9 node` or `sudo systemctl restart docker` |
| Building something large from the AUR | `capped paru -S <pkg>` — `makepkg` builds in `/var/tmp`, but a big Rust or Electron build still wants gigabytes |
| Bar/launcher/notifications gone, windows still work | `systemctl --user restart noctalia.service` |
| Compositor itself is gone | There is no in-place fix — niri *is* the session. Ctrl+Alt+F3 and restart from the TTY |
| Absolute last resort | **Alt + PrtSc + R, E, I, S, U, B** (in order, ~2s apart) — safe reboot with disk sync. Never hold the power button first. |

**Before any heavy build:** `capped nx build ... --parallel=2`

---

## 📌 If you do only five things

*Revised after the move to CachyOS + niri. The original list's items 1 and 3 named software
that no longer exists on this machine — Akonadi, Baloo and PackageKit are not "reclaimed"
here, they are simply never installed. What replaced them is measurement: in 8 days the old
machine logged **one** OOM kill (earlyoom, a `code-insiders` renderer at `oom_score` 1178,
which took the window with it), and Firefox's 6 GiB cap fired **~114,000 times in 8 hours**.
The list below is ordered by measured impact, not by how satisfying the cleanup feels.*

1. **Cut the Firefox working set.** 8.13 GiB against 15.3 GiB usable, with the cap engaged
   roughly four times a second. Nothing else on this list is within an order of magnitude,
   and no pref will fix it — see Phase 5.
2. **Audit your browser and editor extensions.** Firefox's working set is **8.13 GiB (PSS)**
   across ~27 content processes, with **10 of 20 extensions holding `<all_urls>`**; VS Code
   is 2.9 GB on disk across 97 extensions, and the one OOM kill in 8 days was a
   `code-insiders` renderer. An `<all_urls>` extension injects a content script into *every*
   content process, so its cost scales with tab count rather than with how often you use it.
   Use VS Code **Profiles** so the C#/C++/Java/F# language servers aren't resident during
   Angular work.

   > **NB — an earlier revision of this list said "8.4 GB across 30 processes".** That was
   > an RSS sum, which is precisely the mistake this guide warns against 300 lines earlier:
   > RSS counts every shared page in full against every process that maps it, so a
   > 27-process browser double-counts libxul dozens of times. The 8.13 GiB above is PSS.
3. **Fix earlyoom's `--avoid` list.** It named `kwin_wayland|plasmashell|kded6|krunner|sddm`
   — five processes that do not exist on this machine any more. An avoid-list naming only
   dead processes protects nothing, and under memory pressure earlyoom's first kill is then
   as likely to be `niri` as the runaway Node process. That converts your OOM protection into
   an OOM *cause*. It must name `niri`, `noctalia`, `xwayland-satell` and the greeter.
4. **Get a rollback path** (Layer 0), on day one. `snapper` has been the single failing check
   in `scripts/doctor.sh` since this repo was created, and a fresh install is the moment it
   is free. Everything else here edits system state.
5. **Apply the settings you already wrote down, and then verify them from the kernel.** The
   audit found the VS Code watcher excludes, the Firefox prefs and the terminal scrollback
   cap were all documented here but never applied. Worse, three settings *looked* applied and
   were not: `bat`'s `--theme=auto` silently fell back to Monokai, `ghostty` had no theme at
   all while the shell inside it assumed one, and the Firefox `MemoryHigh` drop-in would have
   matched no unit under niri. A guide only helps once it's executed — and a config only
   helps once something reads it back. That is what `scripts/doctor.sh` is for.

> **On SQL Server:** the original item 2 warned it would claim ~80% of host RAM. Still true
> *when you run it* — but the measured stack here (Postgres, Traefik, nginx, MinIO, .NET,
> Keycloak, Tryton) is a few hundred MB of RSS. Docker is not the problem on this machine.
> Keep the caps in the compose files for when SQL Server comes back.
>
> Docker's *disk* is a different story: 9.08 GB of images (2.74 GB reclaimable) and
> **7.49 GB of build cache, 100% reclaimable**, on a 238 GB disk. That is what
> `scripts/reclaim.sh` is now for.

---

## 🤖 This guide has an executable half

The repository around this file applies most of the above:

```bash
git clone <this-repo> ~/dotfiles && ~/dotfiles/bootstrap.sh
sudo ./system/apply.sh      # the /etc drop-ins from Phase 4, plus enabling the
                            # units Arch ships disabled (oomd, earlyoom, fstrim)
./scripts/reclaim.sh        # Layer 5 — now disk, not RAM: pacman cache, orphans, coredumps
./scripts/firefox-tune.sh   # Firefox prefs into every profile (needs a Firefox restart)
./scripts/doctor.sh         # verifies every claim in this document
```

`scripts/doctor.sh` is the important one. It checks swappiness, oomd/earlyoom, the disk
caps, the VS Code settings and the shell fixes, and tells you which are **actually live** —
so this guide can never quietly drift out of sync with the machine again.

That framing earned its keep during the migration. Three settings in this repo looked
correct and did nothing:

- `bat`'s `--theme=auto` silently fell back to Monokai whenever the terminal could not answer
  an OSC 11 query — so the configured Catppuccin theme never applied in a pipe.
- `ghostty` had a font and no theme at all, which is why Konsole was the terminal actually
  in use.
- The Firefox `MemoryHigh` drop-in targeted a unit template that niri never instantiates.

None of the three produced an error. All three are the reason doctor now verifies from the
**kernel** — the live `earlyoom` argv, the real cgroup path, `sysctl -n vm.swappiness` — and
not by reading back the files it just wrote.

**Related:** `docs/MIGRATION.md` is the one-time move off Fedora KDE. It is a runbook with
hard gates, not a reference, and it is deliberately short enough to read from a phone while
the laptop is being reinstalled.
