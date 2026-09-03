# 🌟 The T490s Low-RAM Setup Guide 🔥
### CachyOS · KDE Plasma

**Target machine:** Lenovo ThinkPad T490s — Intel i5-8365U (4C/8T, Whiskey Lake), 16 GB RAM
(15.3 GiB usable), Intel UHD 620
**Storage:** 238.5 GB Intel NVMe (`INTEL SSDPEKKF256G8L`), btrfs + zstd:1, zram-only swap
**ISA level:** **x86-64-v3** — no AVX-512. This decides which CachyOS repos you may enable;
see Phase 1.
**Displays:** `eDP-1` 1920×1080 @ scale 1.25 · `HDMI-A-2` 1920×1080 @ scale 1.0
**Target OS:** CachyOS (Arch) · KDE Plasma 6, Wayland
**Workload:** Docker, Angular/Nx monorepos, microservices, nopCommerce (.NET + SQL Server)
**Curated by SharifdotG · Revised for low-RAM stability**

> **The one thing to take from this guide, stated up front.** Measured on this machine, the
> entire Plasma session — compositor, shell, panel, every KDE daemon — costs **0.58 GiB**.
> Firefox alone costs **8.13 GiB**. The desktop environment is not where your memory goes,
> and no amount of switching between them will change that. Phase 4 is where the gigabytes
> are.
>
> This is not theoretical. A previous revision of this guide targeted a minimal
> scrollable-tiling compositor specifically to save RAM, on the strength of a claim that
> Plasma idled at 1.2–1.5 GB. That figure was an internet number, never a measurement, and
> it was **~2.4× too high**. The whole detour was chasing a few hundred megabytes against a
> browser costing eight gigabytes. Plasma came back.

> **Coming from Fedora KDE?** The one-time move is `docs/MIGRATION.md`, which is a runbook
> rather than a reference. This file is what you read afterwards, and every time something
> breaks.

---

## 📋 What changed, and why

| Was | Is | Why |
|---|---|---|
| Fedora 44 / `dnf` | CachyOS / `pacman` + `paru` | Rolling, and the v3-optimised repos match this CPU |
| KDE Plasma 6.7 | **KDE Plasma 6, unchanged** | It was never the problem. See the note above |
| Konsole | Ghostty | Already installed and managed; now actually themed, which is why it was not being used before |
| Secure Boot **enabled** | **disabled** in firmware | `linux-cachyos` is not MS-signed, and fwupd never needed Secure Boot |
| `starship` and `chezmoi` via upstream installers | real repo packages | The `-` sentinel in `packages/core.tsv` is gone |
| `/etc/default/earlyoom` | an `ExecStart=` drop-in | On Arch the vendor file wins over `Environment=`. See Layer 2b |
| RPM Fusion for codecs | nothing to do | Arch's `ffmpeg` is unencumbered |
| — | `.pacnew` handling, `paccache`, orphan pruning | Maintenance responsibilities Fedora never imposed. See Phase 8 |

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

Verify later at **`brave://gpu`** — look for *Video Decode: Hardware accelerated* rather than software.

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

**Do not install TLP.** Plasma integrates with `power-profiles-daemon` directly — the battery icon offers Power Save / Balanced / Performance — and running both causes conflicting settings. `power-profiles-daemon` plus the S3 BIOS setting from Phase 0 is enough.

Optional diagnostics only: `sudo pacman -S powertop` — run `sudo powertop` to *look* at power draw. Don't run `--auto-tune` on a ThinkPad; it aggressively suspends USB ports and will make your mouse and dock flaky.

---

## 🖥 Phase 3: Desktop

The CachyOS KDE edition installs the workspace, the display manager, Breeze, the portal and
the core KDE apps at install time. There is nothing to assemble.

That sentence is doing more work than it looks. A bare compositor needs you to supply, and
keep working, a polkit agent, a notification daemon, a screen locker, an idle daemon, a
clipboard manager, a wallpaper setter, an output-configuration tool, portal backends and a
Qt platform theme — and **every one of them fails silently when absent**. No polkit agent
means password dialogs simply never appear. No notification daemon means `earlyoom -n` has
nowhere to report, so OOM kills become invisible, which quietly undermines Phase 4. Plasma
ships all of it, wired together, for the 0.58 GiB measured above.

### What to verify

| Check | Command | Expected |
|---|---|---|
| Wayland session | `echo $XDG_SESSION_TYPE` | `wayland` |
| Per-output scaling | System Settings → Display | `eDP-1` at 125%, `HDMI-A-2` at 100% |
| VA-API | `vainfo \| head -20` | `iHD` driver, H.264/HEVC profiles listed |
| GTK apps themed | open any GTK app | Breeze colours, not default Adwaita |

> **NB — `LIBVA_DRIVER_NAME=iHD` is set in `~/.config/environment.d/50-wayland.conf`.**
> Nothing in this repo set it before, despite `packages/desktop.tsv` carrying
> `intel-media-driver` "for VA-API on UHD 620" since it was written. Having the driver
> installed is not the same as having it selected. It needs a re-login to take effect.

### What to turn off

Plasma's defaults are reasonable, but three things earn nothing on this workload and are
handled by `scripts/reclaim.sh` — see Layer 5 for what each costs.

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

**The desktop was never where the memory went.** Measured on this machine, the entire Plasma session — compositor, shell, panel, every KDE daemon — is **0.58 GiB**. Firefox alone is **8.13 GiB**, 53% of the 15.3 GiB actually available.

If you read this guide expecting the window manager to be the fix, you will tune the wrong thing. The four layers below are worth gigabytes; the lightest possible desktop would be worth a couple of hundred megabytes. That asymmetry is the whole reason this guide is structured the way it is.

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

#### Protect the desktop session:

Prevent `systemd-oomd` from killing the shell when an *application* runs out of memory:

```bash
mkdir -p ~/.config/systemd/user/plasma-plasmashell.service.d
tee ~/.config/systemd/user/plasma-plasmashell.service.d/50-oom.conf > /dev/null <<'EOF'
[Service]
ManagedOOMPreference=avoid
OOMScoreAdjust=-500
EOF
```

> **NB — losing the shell to reclaim memory is worse than almost anything it was holding.**
> `plasmashell` is the panel, the launcher, the notifications and the desktop at once. Take
> it out of the running for both killers, and make sure earlyoom's `--avoid` list names it
> too (Layer 2b).

Apply and verify:

```bash
sudo systemctl daemon-reload
systemctl --user daemon-reload
sudo systemctl enable --now systemd-oomd     # NB: Arch does not enable it for you
systemctl --user restart plasma-plasmashell.service
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
  --avoid '^(systemd|systemd-.*|sshd|kwin_wayland|plasmashell|kded6|krunner|ksmserver|plasma-.*|sddm|sddm-greeter|dbus-.*|pipewire|wireplumber|NetworkManager)$' \
  --prefer '^(node|brave|code-insiders|dotnet|sqlservr|java)$' \
  -n
```

That means: trigger when free RAM drops below 4% *or* free swap below 20%, never touch the
session, preferentially kill Node/Brave/SQL Server, and send a desktop notification (`-n`)
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

> **NB — the `--avoid` list must name the CURRENT session's processes, and it is worth
> re-reading it after any desktop change.** An avoid-list naming processes that do not exist
> protects nothing, and earlyoom's first kill under pressure is then as likely to be the
> compositor as the runaway Node process — which converts your OOM protection into an OOM
> cause. (This is not hypothetical: while this repo briefly targeted a bare compositor, the
> list still named `kwin_wayland` and `plasmashell`, protecting five processes that were not
> running.)
>
> **And names are truncated.** earlyoom matches `/proc/<pid>/comm`, which the kernel caps at
> **15 characters** — anything longer will never match, however correct it looks.
> Check with `ps -eo comm` before adding a long name.
>
> **NB — `--prefer` got weaker when the browser changed.** Firefox named its content
> processes `Isolated Web Co` and its parent `firefox`, so earlyoom could be aimed at *tabs*
> and would never take the whole browser. Chromium names every process in the tree `brave` —
> parent, renderers, GPU, utility alike. earlyoom kills whichever is largest, usually a
> renderer but possibly the parent, which takes the entire browser down. There is no way to
> express "tabs only" here.

Because a silently-ignored config is the exact failure this design avoids, verify from the
**kernel**, never by reading back the file you wrote:

```bash
sudo systemctl enable --now earlyoom
tr '\0' ' ' < /proc/$(systemctl show -p MainPID --value earlyoom)/cmdline
# must contain --avoid ... plasmashell ...
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

> **NB — a crashed shell is recoverable in place; a crashed compositor is not.** If the
> panel and launcher vanish but your windows are still there, `systemctl --user restart
> plasma-plasmashell` gets the session back without losing anything. If `kwin_wayland`
> itself dies, the session goes with it and the TTY is your route.

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

### 🧹 Layer 5 — reclaim what KDE ships but you don't use

Two kinds of reclaim here, and it is worth keeping them apart because Fedora only had one of
them. `scripts/reclaim.sh` does both and reports both.

#### RAM — KDE services you are paying for and not using

| Target | Measured cost | Why it earns nothing here |
|---|---|---|
| **KDE PIM / Akonadi** | **507 MB across 16 processes + a 125 MB MySQL database** | Zero configured mail accounts. Biggest single win on the list |
| **Baloo** | sustained CPU, RAM and SSD writes | It indexes every `node_modules` tree it can find. On an Nx monorepo that is hundreds of thousands of files, and you search with `rg`/`fzf` anyway |
| **PackageKit** | 200–300 MB resident | Discover's backend. You update with `pacman` |
| **Discover notifier** | 24 MB resident / **350 MB swapped** | Measured. Most of its cost was invisible to `ps` because it had been paged out |

> **NB — that last row is a lesson about measurement, not about Discover.** `ps` RSS showed
> 24 MB and the process looked harmless. It had ballooned, gone idle, and been swapped
> wholesale into zram — where it still occupied 350 MB of compressed pages. Resident size is
> not footprint. Check `SwapPss` in `/proc/<pid>/smaps_rollup` before concluding something is
> small.

> **NB — check for real data before removing Akonadi.** `reclaim.sh` refuses to touch it if
> `~/.config/akonadi/agentsrc` or `~/.local/share/local-mail` exist. "I don't use kmail" and
> "kmail has nothing in it" are different statements.

#### Menu clutter — the preinstalled application suite

The KDE edition ships a full app suite: games, a media player, a paint program, a character
map, remote-desktop client and server, a help centre, and so on. `scripts/reclaim.sh` offers
to remove them.

**Be honest about what this buys.** These are not daemons. They sit on disk and cost nothing
at rest, so removing them is about menu clutter and update churn — *not* memory. If you came
to this section looking for RAM, the Akonadi/Baloo/PackageKit block above is where it is,
and the browser is where it really is.

Two design notes on how the script does it, because both are deliberate:

- **It does not hardcode a removal list.** CachyOS's default set is not Fedora's, so a fixed
  list would try to remove things that were never installed and miss things that were. The
  script filters its candidates through `pacman -Qq` first.
- **"Nobody uses this" is a claim about you, not about the package.** So it checks for a
  config or state directory and refuses to offer anything you have actually opened. Measured
  on the outgoing machine, that check mattered: of ~34 candidates, all but three had never
  been launched — but `kwrite`, `kamoso` and `plasma-welcome` had, and a blind list would
  have taken them.

> **NB — some of these look like clutter and are load-bearing.** Never remove
> `kde-gtk-config` (it themes every GTK app from the Plasma colour scheme),
> `plasma-browser-integration`, `xdg-desktop-portal-kde`, `kwallet`/`ksshaskpass`,
> `plasma-nm`/`plasma-pa`, `powerdevil`/`kscreen`, `plasma-thunderbolt` (the T490s has
> Thunderbolt 3 and this is what authorises devices), or `plasma-disks` (the GUI for
> `smartmontools`, which is in `reliability.tsv`). The script's candidate list excludes all
> of them.

> **NB — removing any member of `plasma-meta` removes `plasma-meta` itself**, because the
> meta-package depends on it. Harmless in itself — a meta-package exists only to pull
> dependencies — but it means a future `pacman -Syu` will no longer add newly-introduced
> Plasma components automatically. Reinstall `plasma-meta` if you want that back.

#### Disk — an Arch problem Fedora never had

- **The pacman package cache.** `dnf` defaults to `keepcache=False`; pacman keeps **every
  version of every package it has ever installed, forever**. Routinely 5–20 GB.
  `paccache -rk2` trims it; `paccache.timer` (enabled by `system/apply.sh`) keeps it trimmed.
- **Orphaned packages** — dependencies whose parent is gone. `pacman -Qtdq`. Nothing removes
  these automatically.
- **`systemd-coredump`** — the Arch analogue of ABRT, and a disk problem rather than a RAM
  one: measured **389 MB in `/var/lib/systemd/coredump` with no cap configured at all**.
  `system/systemd/coredump.conf.d/99-size-cap.conf` fixes that going forward.
  > **NB** — `ProcessSizeMax=2G` is the load-bearing key on a 16 GB box. A browser's address
  > space is several GB; without a limit, one browser crash writes a multi-GB core to disk
  > *under the very memory pressure that caused the crash*. Over the limit the dump is
  > skipped rather than truncated, which is what you want.
- **Docker.** 9.08 GB of images (2.74 GB reclaimable) plus **7.49 GB of build cache, 100%
  reclaimable**, on a 238 GB disk.

**Still needed, unchanged:** the journal cap (`system/journald.conf.d/99-size-cap.conf`) —
without it the journal grows to the 10%-of-`/var` default, ~4 GB of logs nobody reads.

**Terminal scrollback** moved from Konsole to Ghostty: `scrollback-limit = 2000000`.
Unlimited scrollback across ten tabs of Docker logs is a genuine leak — though Ghostty's
*default* is already a bounded 10 MB, so this is a tightening rather than a fix, and the
setting is in **bytes**, not lines.

**Don't** disable KWin compositing. On Wayland you can't meaningfully, and the UHD 620
handles it in hardware for near-zero cost. Turning off blur and animations saves single-digit
MB and makes the desktop worse.

> **NB — do not disable `ananicy-cpp` or `scx_loader`/`scx-scheds`.** CachyOS ships these
> deliberately: they are the auto-nice daemon and the `sched_ext` scheduler that make the
> machine feel responsive under load. They look like cruft in a service list and they are
> not. Removing them is a regression, not a reclaim.

### 📊 Your realistic 16 GB budget

| Component | Measured, Fedora KDE 2026-09 | Expected on CachyOS + KDE |
|---|---|---|
| Desktop session, idle | **0.58 GiB** | unchanged — same desktop, newer packages |
| Browser, real working set | Firefox: **8.13 GiB** (4.65 resident + 3.48 in zram) | Brave Origin: ~2.9 GiB measured — but the same web apps, so re-measure under load |
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

On Firefox the browser alone was **53% of the 15.3 GiB this machine actually has**, and the
reason it still felt fine was that **3.48 GiB of it was not in RAM at all** — compressed in
zram at 3.79:1, costing about 0.92 GiB of physical memory.

Brave Origin measures far lower (~3.3 GiB PSS on the same browsing), so the arithmetic is
less brutal now. But **do not read that as headroom**: the five permanently-open web apps
that dominated the Firefox number cost the same in any engine. Brave is capped again as of
2026-09-03 — 6 GiB, via `browser.slice` plus a dash-truncation drop-in, see *The cap that
used to matter, then didn't, and now does again* below — but at ~2× the current working set
that is a backstop, not a working constraint. Re-measure under real load before relaxing
anything.

Either way, zram is not a safety margin here. It is load-bearing, permanently, every day —
worth knowing before you ever set `vm.swappiness` back to something "sensible".

Two consequences for how you read the rest of this guide:

- The lightest possible desktop would be worth a couple of hundred megabytes against this.
  If you came here expecting the window manager to be the fix, you are tuning the wrong
  thing — and that is not hypothetical, this guide once made exactly that mistake.
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
  `vesktop-bin` and `brave-origin-bin`. They are declared in a separate `aur` column and
  installed in their own `paru` transaction, so one failed build cannot take the other ~90
  repo packages down with it.

Postgres needs initialising if you run it on the host rather than in Docker:

```bash
sudo postgresql-setup --initdb
sudo systemctl enable --now postgresql
```
> Honestly: for your workload, run Postgres in Docker instead and skip the host install entirely. One less always-on service.

### 🦊 Brave Origin

**Brave Origin** is the browser here — a stripped-down Brave that removes the
revenue-generating features (Rewards, Wallet, News, Leo, Talk, Tor, VPN, Web Discovery) and
the telemetry, keeping Shields and the Chromium core. **Free on Linux**; the $59.99 one-time
charge applies only to macOS/Windows/Android/iOS.

It is installed from Brave's own repository, not Arch's — `packages/desktop.tsv` marks it as
an AUR row. If the AUR package name has drifted, the universal fallback works on any distro:

```bash
curl -fsS https://dl.brave.com/install.sh | FLAVOR=origin sh
```

#### Why this browser, measured rather than assumed

The previous version of this guide argued at length for Firefox on a low-RAM machine. That
argument was tested and it did not survive.

Controlled comparison — identical six pages, fresh profile, no extensions, PSS:

| | Processes | Memory |
|---|---|---|
| Firefox | 18 | **1,328 MB** |
| Brave Origin | 18 | **766 MB** |

Two honest caveats, because this is the kind of number that gets quoted out of context:

- **Neither profile had extensions.** The strongest theoretical argument *against* Chromium
  is its process model — Firefox runs all extensions in one shared process (measured at
  191 MB for 19 extensions), while Chromium gives each extension its own. That was never
  tested and remains unverified in both directions.
- **This is engine overhead, not your real workload.** The measured 8.13 GiB on the old
  Firefox setup was five permanently-open logged-in web apps at ~580 MB each. Those cost the
  same in any engine. No browser switch touches them.

#### The cap that used to matter, then didn't, and now does again

Firefox got a hard 6 GiB ceiling here, and it was genuinely load-bearing: measured working
set 8.13 GiB against a 6 GiB `MemoryHigh`, with **~114,000 throttle events in 8 hours** —
roughly four per second, sustained. The machine felt fine *because* of that cap.

That mechanism did not survive the switch to Brave, and this guide spent a while asserting
that **no** mechanism could. That was wrong. Here is the corrected reasoning, because the
wrong version was specific and confident and is worth being able to recognise.

Under Plasma, KDE's KProcessRunner launches each `.desktop` app as a transient unit, so
Firefox landed in `app-firefox@<hex>.service` and a drop-in on the *template* unit applied
to every instance. Brave gets such a unit too — `app-brave\x2dorigin@<hex>.service` is
created and does exist. But **Chromium then self-registers its own transient scope**,
`app-org.chromium.Chromium-<PID>.scope`, and migrates the bulk of its processes into it.

Measured on this machine (2026-09-03, Fedora, before the move):

```
app-brave\x2dorigin@<hex>.service         2 processes
app-org.chromium.Chromium-34947.scope    33 processes
app-org.chromium.Chromium-285773.scope    2 processes
```

Note the **two** Chromium scopes. The name is fixed at first launch, and a relaunch inside
the same session makes another one. That matters below.

So a drop-in on the template unit would cap about 5% of the browser and silently miss the
rest, and the scope's name carries a PID that changes every launch. The old conclusion drawn
from that — *therefore nothing can target it* — skipped a step.

> **The step it skipped: templating is not the only way to reach a family of unit names.**
> systemd also searches drop-in directories built by **repeatedly truncating the unit name
> at dashes**. `systemd.unit(5)`, verified against the systemd 259 man page on this machine:
>
> > for a unit name `foo-bar-baz.service` not only the regular drop-in directory
> > `foo-bar-baz.service.d/` is searched but also both `foo-bar-.service.d/` and
> > `foo-.service.d/`
>
> `app-org.chromium.Chromium-<PID>.scope` therefore reads
> **`app-org.chromium.Chromium-.scope.d/`** for any PID at all. That is a different systemd
> feature from unit templating, which is why "no *template* drop-in can target it" was true
> and useless at the same time.

The ceiling is now two files, both in the chezmoi tree under
`home/private_dot_config/systemd/user/`:

| File | Does |
|---|---|
| `app-org.chromium.Chromium-.scope.d/50-memory.conf` | `MemoryHigh=6G` + `Slice=browser.slice` on every Chromium scope, whatever its PID |
| `browser.slice` | `MemoryHigh=6G` on the **sum** of those scopes |

Both, not either. They cover different failure modes:

- **The slice is the real ceiling.** cgroup limits are per-cgroup, so a 6 GiB cap applied to
  two live scopes is a 12 GiB ceiling — not a ceiling. The slice caps the total no matter
  how many scopes Chromium invents.
- **The scope `MemoryHigh` is what reaches a browser that is already running.** `Slice=`
  only binds scopes created *after* the drop-in lands, because a live cgroup cannot be
  re-parented. Right after install, `systemctl --user show` reports
  `Slice=browser.slice` while `ControlGroup=` still says `app.slice`; the scopes move at the
  next Brave launch. Until then the per-scope value is the only thing holding.

Verified live, against a running Brave and against synthetic scopes made to mimic Chromium's
naming and its launch properties:

```
systemctl --user daemon-reload      # no browser restart needed
systemctl --user show app-org.chromium.Chromium-<PID>.scope -p MemoryHigh -p DropInPaths
  → MemoryHigh=6442450944, the drop-in listed in DropInPaths
cat /sys/fs/cgroup/.../app-org.chromium.Chromium-<PID>.scope/memory.high
  → 6442450944
```

`Slice=` in the drop-in also beats the `Slice=app.slice` Chromium passes explicitly in its
own `StartTransientUnit` call — a fresh scope launched with `--property=Slice=app.slice`
landed in `user@1000.service/browser.slice/` anyway.

> **Read the number differently than you read Firefox's.** 6 GiB against Firefox's 8.13 GiB
> working set was an *actively throttling* cap, firing four times a second, and the machine
> depended on it. 6 GiB against Brave's measured ~3.3 GiB PSS is a **backstop with roughly
> 2× headroom** — `memory.events` reads `high 0`, i.e. it has never fired. Same number,
> completely different job. Do not "tune" it down toward the working set to make it look
> active; the Firefox experience is what that produces.

`scripts/doctor.sh` now checks both as pass/fail rather than reporting a note, plus a note
for how many scopes have physically moved into the slice yet.
#### Diagnosing it

`brave://system` and Brave's own Task Manager (`Shift+Esc`) give a per-tab breakdown.

> ⚠️ **Never sum `ps` RSS for a multi-process browser.** RSS counts every shared page in full
> against *every* process mapping it, so a 30-process Chromium double-counts its shared
> runtime ~30 times. This guide's own doctor check once did exactly that and reported
> **8.3 GB** where the system monitor said **5.6 GB**. Use PSS, which divides each shared
> page by its sharer count:
> ```bash
> for p in $(pgrep -f /opt/brave.com/brave-origin); do
>   awk '/^Pss:/{print $2}' /proc/$p/smaps_rollup 2>/dev/null
> done | awk '{s+=$1} END {printf "%.2f GiB\n", s/1048576}'
> ```

#### Extensions are not free

An extension with access to every site injects a content script into **every** renderer, so
its cost scales with tab count rather than with how often you use it. On the old Firefox
profile that was **10 of 20** extensions.

Chromium additionally gives **each extension its own process**, where Firefox used one shared
process for all of them. Porting a large extension set across is therefore the one place the
switch could plausibly cost you memory — worth watching in `Shift+Esc` as you re-add them.

Drop anything the browser or desktop already does natively: Brave has Shields (so a separate
blocker is redundant), picture-in-picture, and screenshots built in, and Plasma handles media
keys via `plasma-browser-integration`.

#### Hardware video acceleration

`LIBVA_DRIVER_NAME=iHD` is set in `~/.config/environment.d/50-wayland.conf`. Verify with
`vainfo`, and check `brave://gpu` reports hardware decode rather than software.

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

For **LinkedIn, Reddit, WhatsApp, X, YouTube Music, Figma, ChatGPT, Claude** — the browser
switch actually improved this. Firefox needed a workaround here because **Mozilla removed
site-specific browser / PWA support**, so there was no "install page as app". Chromium has it
natively.

**1. Install as app (now the easy answer).** ⋮ menu → **Cast, save and share → Install page
as app**. You get a real `.desktop` entry that shows up in KRunner and pins to the panel, in
its own window without browser chrome.

> **NB — but check the process cost before you convert everything.** Each installed app gets
> its own renderer, and Chromium is less willing to share renderers across app windows than
> Firefox was across pinned tabs. Watch `Shift+Esc` (Brave's task manager) after converting
> two or three, rather than doing all six and then wondering where the memory went.

**2. Pinned tabs** remain the cheaper option for anything you don't need a separate window
for. They persist across restarts and share existing renderers.

> Whichever you pick: six always-open web apps is 1–1.5 GB permanently gone, and that was
> true on Firefox and is true on Brave. This is the same finding as the budget table — the
> pages cost what they cost. Pin your three most-used, bookmark the rest.

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

### 🔤 The coding font

**Cascadia Code NF** — `ttf-cascadia-code-nerd`, in the Arch repos, installed by
`bootstrap.sh`. Nothing to download by hand.

> **NB — the family string is `Cascadia Code NF`, not `Cascadia Code Nerd Font`.**
> fontconfig matches on the name in the font's own name table, and the Nerd Font build
> reports "NF". Give it the wrong string and fontconfig silently substitutes some other
> monospace — no error, just the wrong font. Check with:
> ```bash
> fc-match 'Cascadia Code NF'
> ```

This replaced **Maple Mono NF**, for two reasons. The AUR package
(`ttf-maplemono-nf-unhinted`) failed to install during VM testing, and Cascadia is in the
official repos — one fewer AUR dependency in the critical path. Maple's stylistic sets also
did not survive the move; see the Ghostty section.

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
| `theme` | `Catppuccin Latte` | *nothing* — bundled with Ghostty, no external file needed |
| `font-family` / `font-size` | Cascadia Code NF, 10 | was Maple Mono NF; the guide once said 11pt, the profile said 10 |
| `font-feature` | `calt`, `zero` | matches `editor.fontLigatures` in the VS Code settings exactly |
| `window-width` / `window-height` | 125 × 30 | Konsole `TerminalColumns`/`TerminalRows` |
| `cursor-style` | `bar` | Konsole `CursorShape=1` |
| `command` | `/bin/zsh` | same |
| `scrollback-limit` | 2000000 | Konsole `HistorySize=10000` *lines* |
| `window-decoration` | `server` | let KWin draw the frame, matching every other window |

> **NB — the font-feature list shrank from 16 entries to 2, and that is a fix rather than a
> loss.** The old list (`cv03`, `cv05`, `cv09`, `cv10`, `cv61`, `cv38`, `cv42`, `cv43`,
> `ss03`, `ss07`–`ss11`) named *Maple Mono's* stylistic sets. Cascadia Code NF does not have
> them. Read straight out of the font's GSUB table, its complete feature set is:
>
> ```
> aalt calt case ccmp dnom fina frac init locl medi numr ordn
> rclt rlig sinf ss02 ss19 ss20 subs sups zero
> ```
>
> So 14 of the 16 would have been **silently ignored** — a font feature that does not exist
> is not an error, it is just absent. `calt` (ligatures) and `zero` (slashed zero) are the
> two that carry over. `ss02`/`ss19`/`ss20` exist but carry no UI label in the font and
> Microsoft does not document them, so they are left off rather than cargo-culted.
>
> Verify any font's real features rather than copying a list between fonts:
> ```bash
> python3 -c "
> import struct,sys; d=open(sys.argv[1],'rb').read()
> u16=lambda o: struct.unpack('>H',d[o:o+2])[0]; u32=lambda o: struct.unpack('>I',d[o:o+4])[0]
> t={d[12+i*16:16+i*16].decode('latin1'):u32(12+i*16+8) for i in range(u16(4))}
> b=t['GSUB']; f=b+u16(b+6)
> print(sorted({d[f+2+i*6:f+6+i*6].decode('latin1') for i in range(u16(f))}))
> " "$(fc-match -f '%{file}' 'Cascadia Code NF')"
> ```

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

## ⚙️ Phase 7: Plasma personalization

Short, because this is the phase you get for free. Everything below is a System Settings
panel, and none of it needs a config file in this repo.

### 🖥 Displays

System Settings → Display Configuration. The measured layout on this machine:

| Output | Resolution | Scale |
|---|---|---|
| `eDP-1` (internal) | 1920×1080 | **125%** |
| `HDMI-A-2` (external) | 1920×1080 | 100% |

> **NB — mixed per-output fractional scaling is the single strongest practical argument for
> Plasma on this hardware.** Plasma 6 on Wayland handles it correctly per output. The lighter
> desktops that look attractive on a RAM budget — XFCE, LXQt, Cinnamon — are X11-first and
> handle it badly, and you would be trading roughly 200 MB (a few percent of what the browser costs)
> for blurry or wrongly-sized windows every time you dock. That is a bad trade.

### ⌨️ Shortcuts worth setting immediately

System Settings → Shortcuts. The defaults that matter are already right: `Meta+L` locks,
`Meta+D` peeks at the desktop, `Meta+W` is the overview, `Ctrl+Alt+Del` opens the logout
screen, and the media keys work including `Shift`+volume for 1% steps.

Worth adding: a shortcut for Ghostty (`Meta+Return` if you like), and `Ctrl+Shift+Esc` for
System Monitor.

### 🖼 GTK apps: KDE already themes them — don't "fix" this

`kde-gtk-config`'s kded module regenerates `~/.config/gtk-{3,4}.0/` and `~/.gtkrc-2.0` from
the live Plasma colour scheme on **every** scheme change. Verified: all four files rewritten
within milliseconds of each other at login. A chezmoi-managed copy would be silently
clobbered and would look like a theming bug, which is why those paths are in
`home/.chezmoiignore`.

`gtk-theme-name=Breeze` is *correct*. Breeze is the widget style and KDE recolours it.

> **NB — this rule flipped twice, so here is the test rather than the answer.** It was briefly
> inverted while this repo targeted a bare compositor: with no kded, nothing regenerates GTK
> config, so leaving it unmanaged left GTK apps on default Adwaita forever — the same symptom
> as clobbering, from the opposite cause. The question is never "should GTK config be
> version-controlled"; it is **"does something else already own these files?"** Under Plasma
> it does.

### 🖱 Touchpad & TrackPoint (T490s)

System Settings → Mouse & Touchpad. Enable tap-to-click and disable-while-typing (the
touchpad sits directly under the space bar). The TrackPoint gets press-to-scroll via the
middle button — that is the entire reason a ThinkPad has one.

### ⏱️ Autostart

System Settings → Autostart. **Do not autostart Vesktop or Telegram** — that is ~700 MB at
login for two things you open a few times a day. This is the single most effective item in
the whole phase.

### 🔌 Browser integration

Install the **Plasma Integration** add-on from addons.mozilla.org; the native host
(`plasma-browser-integration`) is in `packages/desktop.tsv`. You get media controls in the
panel and on the lock screen, downloads in KDE notifications, and open tabs searchable from
KRunner.

> **NB — it is worth the extension slot, but count it.** Phase 5 asks you to audit extensions
> holding `<all_urls>` because their cost scales with tab count. Plasma Integration is one
> more. It happens to buy back real functionality; most of the others on your list do not.

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
| Plasma crashed but the system is alive | `systemctl --user restart plasma-plasmashell` |
| Absolute last resort | **Alt + PrtSc + R, E, I, S, U, B** (in order, ~2s apart) — safe reboot with disk sync. Never hold the power button first. |

**Before any heavy build:** `capped nx build ... --parallel=2`

---

## 📌 If you do only five things

*Revised after the move to CachyOS. Items 1 and 3 of the original list still stand — Akonadi,
Baloo and PackageKit come back with KDE and are still worth reclaiming — but they are no
longer the top of the list, because measurement moved them down it:*

* in 8 days the old
machine logged **one** OOM kill (earlyoom, a `code-insiders` renderer at `oom_score` 1178,
which took the window with it), and Firefox's 6 GiB cap fired **~114,000 times in 8 hours**.
The list below is ordered by measured impact, not by how satisfying the cleanup feels.*

1. **Watch the browser working set.** Firefox measured 8.13 GiB against 15.3 GiB usable,
   with its 6 GiB cap engaged roughly four times a second. Brave Origin measures far lower
   (~2.9 GiB) — but it has **no cap at all**, because Chromium self-scopes and the drop-in
   mechanism does not port. Nothing else on this list is within an order of magnitude of the
   browser, and no setting will fix it — see Phase 5.
2. **Audit your browser and editor extensions.** On the old Firefox profile, **10 of 20
   extensions held `<all_urls>`** — and Chromium gives each extension its own process, so
   porting a large set across is the one place this browser switch could cost you; VS Code
   is 2.9 GB on disk across 97 extensions, and the one OOM kill in 8 days was a
   `code-insiders` renderer. An `<all_urls>` extension injects a content script into *every*
   content process, so its cost scales with tab count rather than with how often you use it.
   Use VS Code **Profiles** so the C#/C++/Java/F# language servers aren't resident during
   Angular work.

   > **NB — an earlier revision of this list said "8.4 GB across 30 processes".** That was
   > an RSS sum, which is precisely the mistake this guide warns against 300 lines earlier:
   > RSS counts every shared page in full against every process that maps it, so a
   > 27-process browser double-counts libxul dozens of times. The 8.13 GiB above is PSS.
3. **Remove KDE PIM (Akonadi) and disable Baloo.** 507 MB across 16 processes plus a 125 MB
   MySQL database, for zero mail accounts; and an indexer that walks every `node_modules`
   tree on the disk. ~770 MB for nothing. Layer 5, and `scripts/reclaim.sh` does it with a
   safety check first.
4. **Get a rollback path** (Layer 0), on day one. `snapper` has been the single failing check
   in `scripts/doctor.sh` since this repo was created, and a fresh install is the moment it
   is free. Everything else here edits system state.
5. **Apply the settings you already wrote down, and then verify them from the kernel.** The
   audit found the VS Code watcher excludes, the browser prefs and the terminal scrollback
   cap were all documented here but never applied. Worse, three settings *looked* applied and
   were not: `bat`'s `--theme=auto` silently fell back to Monokai, `ghostty` had no theme at
   all while the shell inside it assumed one, and the browser `MemoryHigh` drop-in would have
   sat under a unit name that no longer holds the processes. A guide only helps once it's executed —
   and a config only helps once something reads it back. That is what `scripts/doctor.sh` is
   for.

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
- The browser `MemoryHigh` drop-in survived two renames (Fedora's
  `app-org.mozilla.firefox@` → Arch's `app-firefox@`) and then stopped applying entirely,
  because Chromium self-registers a PID-named scope and migrates its processes out of the
  unit KDE creates. Measured: 2 processes capped, 32 not. (Fixed 2026-09-03 with a
  dash-truncation drop-in plus a slice; the *second* failure here was concluding for a while
  that it could not be fixed at all.)

None of the three produced an error. All three are the reason doctor now verifies from the
**kernel** — the live `earlyoom` argv, the real cgroup path, `sysctl -n vm.swappiness` — and
not by reading back the files it just wrote.

**Related:** `docs/MIGRATION.md` is the one-time move off Fedora KDE. It is a runbook with
hard gates, not a reference, and it is deliberately short enough to read from a phone while
the laptop is being reinstalled.
