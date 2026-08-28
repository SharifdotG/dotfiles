# 🌟 The Ultimate Fedora KDE Setup Guide 🔥

**Target machine:** Lenovo ThinkPad T490s — Intel i5-8365U (4C/8T, Whiskey Lake), 16 GB RAM, UHD 620
**Target OS:** Fedora KDE Plasma Desktop 44 (**Plasma 6.7.4**, Wayland)
**Workload:** Docker, Angular/Nx monorepos, microservices, nopCommerce (.NET + SQL Server)
**Curated by SharifdotG · Revised for KDE + low-RAM stability**

---

## 📋 What changed from the old guide

| Old (GNOME / leftover Windows bits) | New (KDE + T490s) |
|---|---|
| GNOME Tweaks, Extension Manager | KDE System Settings (built in — nothing extra to install) |
| GNOME Terminal | Konsole (ships with Plasma) |
| Nautilus / GNOME Software | Dolphin / Discover |
| "Task Manager → Startup" | System Settings → Autostart |
| "Microsoft Store Apps" / "Windows Apps" sections | Merged into one **Applications** phase |
| AMD Adrenaline | Removed — T490s is Intel-only |
| `sudo dnf install chatgpt.x86_64` | Removed — that package doesn't exist on Fedora |
| `&` between commands | `&&` (your PDF has `&`, which backgrounds the first command) |
| `- global`, `- force`, `- now` | `--global`, `--force`, `--now` (double dashes were mangled) |
| Docker **Desktop** | Docker **Engine** — Desktop runs a VM and wastes 2–3 GB |
| `alias top='btop'` but btop never installed | btop added to the install list |
| Helium browser | **Firefox** — fewer content processes, ~1 GB lighter at 15 tabs |
| No OOM protection | **Phase 4: full anti-freeze setup** |

---

## 🛠 Phase 0: BIOS & Firmware Prep (do this first)

Reboot → press **F1** at the ThinkPad logo to enter BIOS.

- **Config → Power → Sleep State → `Linux`**
  This enables S3 deep sleep instead of Modern Standby. On the T490s this is the difference between losing ~2% and ~15% battery overnight. Do not skip this.
- **Security → Secure Boot** — leave **enabled**. Fedora signs its kernels; it just works, and you'll want it for fwupd.
- **Config → Thunderbolt → Thunderbolt BIOS Assist Mode → Disabled** (better hotplug on Linux).
- **Security → Memory Protection → Execution Prevention → Enabled**.
- Note whether you have 8 GB soldered + 8 GB SODIMM or 16 GB soldered. The T490s has **one** SODIMM slot; if you have 8+8, a 16 GB stick later gets you to 24 GB for ~$30. Worth knowing before you spend hours tuning.

---

## 🛠 Phase 1: Pre-Installation

### 📥 Download the ISO

Get **Fedora KDE Plasma Desktop** (an official Edition since Fedora 42, not a "spin"):
`https://fedoraproject.org/kde/download`

### 🔌 Create Bootable USB

**Fedora Media Writer** is the better choice over Rufus — it verifies the checksum automatically. If you're preparing from Windows, either works; with Rufus use **DD mode**, not ISO mode.

### 💾 Backup

Before you wipe anything, save:

- `~/.zshrc`, `~/.config/starship.toml`, `~/.gitconfig`, `~/.ssh/`
- VS Code settings (or just enable Settings Sync)
- Tampermonkey userscript export
- Browser profile / Bitwarden vault export
- Docker volumes you care about: `docker run --rm -v <volume>:/data -v $(pwd):/backup alpine tar czf /backup/<volume>.tar.gz -C /data .`
- `docker images --format '{{.Repository}}:{{.Tag}}' > images.txt` so you can re-pull quickly

---

## 🚀 Phase 2: Installing Fedora KDE

### 🔄 Boot from USB

Restart → **F12** for the boot menu (ThinkPads use F12; the old guide's F11 is for desktops) → select your USB device.

### 🪟 Installation choices that matter

Fedora 44 uses the new web-based Anaconda installer. Two decisions to get right:

1. **Storage: use Automatic partitioning.** It gives you Btrfs with `zstd:1` compression and `@root` / `@home` subvolumes. Compression is a genuine win on an NVMe laptop — less I/O, and the CPU cost is negligible.
2. **Do NOT create a swap partition.** Fedora will set up **zram** (compressed RAM swap) instead, and Phase 4 tunes it. A disk swap partition is precisely what turns "low memory" into "frozen laptop" — the machine thrashes on disk for minutes instead of killing something.

After first boot: **System Settings → Users → Fingerprint** to enrol the reader (the T490s Synaptics sensor works out of the box via libfprint).

---

## ✨ Phase 3: Base System Setup

### 📦 First update

```bash
sudo dnf upgrade --refresh -y
sudo dnf autoremove -y
```

### 🧹 DNF Optimization

```bash
sudo nano /etc/dnf/dnf.conf
```

Add:

```ini
max_parallel_downloads=10
defaultyes=True
countme=false
```

> ⚠️ **Two changes from your old config.** `fastestmirror=True` is not needed on dnf5 — Fedora's mirror manager already geo-routes, and the option mostly adds latency to every transaction. And I dropped `install_weak_deps=False`: on KDE it silently skips firmware, codecs, and Plasma integration packages, and you'll spend an afternoon debugging why Bluetooth or a print driver doesn't work. Use `--setopt=install_weak_deps=False` per-command when you actually want it.

### 🔒 RPM Fusion + Codecs

```bash
sudo dnf install -y \
  https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
  https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm

sudo dnf group install -y core multimedia
sudo dnf swap ffmpeg-free ffmpeg --allowerasing -y
sudo dnf update @multimedia --setopt="install_weak_deps=False" --exclude=PackageKit-gstreamer-plugin -y
```

### 🎬 Hardware video acceleration (Intel UHD 620)

This offloads video decode to the iGPU. It cuts CPU usage on YouTube by roughly half and saves real battery.

```bash
sudo dnf install -y intel-media-driver libva-utils libva-intel-driver
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

**Do not install TLP.** Fedora KDE ships `power-profiles-daemon`, Plasma integrates with it directly (battery icon → Power Save / Balanced / Performance), and running both causes conflicting settings. `power-profiles-daemon` + the S3 BIOS setting from Phase 0 is enough.

Optional diagnostics only: `sudo dnf install powertop` — run `sudo powertop` to *look* at power draw. Don't run `--auto-tune` on a ThinkPad; it aggressively suspends USB ports and will make your mouse and dock flaky.

---

# 🧠 Phase 4: Memory & Anti-Freeze Setup

**This is the phase that fixes your actual problem.** Read it properly — everything else in this guide is convenience.

### Why your GNOME install froze at 93–95%

That freeze wasn't GNOME's fault, and switching to KDE alone won't fix it. What happened is a classic Linux **low-memory livelock**:

When RAM fills up, the kernel doesn't kill anything immediately — it first evicts *page cache*, which includes the executable code of running programs. So Plasma, your browser, and your terminal get their own code paged out, then instantly need it back, so the kernel reads it from disk again, then evicts it again. The system spends 100% of its I/O re-reading the same pages. Nothing is technically hung, but nothing progresses. The kernel OOM killer only fires when a memory *allocation* actually fails, which can be minutes later — long after the machine became unusable.

The fix is four layers:

1. **zram** — compressed swap in RAM, so pressure relief costs microseconds not milliseconds
2. **A userspace OOM killer** — kills the greedy process *before* the livelock, not after
3. **Hard caps on Docker** — so a container can never take the whole machine
4. **An escape hatch** — so if it happens anyway, you don't hold the power button

KDE Plasma 6.7 idles at roughly **1.1–1.5 GB** on Wayland versus GNOME 50's **1.8–2.3 GB**. Real, but only ~800 MB. The layers below are worth several gigabytes of effective headroom.

---

### 📸 Layer 0 — a way back

Everything below changes system state. Before any of it, get a rollback path. Fedora's
default install is already Btrfs with `@root`/`@home` subvolumes, so this is cheap:

```bash
sudo dnf install -y snapper
sudo snapper -c root create-config /
sudo snapper -c root create --description "before tuning"
sudo snapper -c root list
```

Rolling back a bad change is then `sudo snapper -c root undochange <N>..0`. Without this,
a 95-package removal or a bad `/etc` edit is a reinstall.

### 🗜 Layer 1 — zram, sized properly

Fedora defaults to zram at `min(RAM/2, 8 GB)`. On a 16 GB dev box, set it to full RAM size — `zstd` typically gets 3:1 on dirty anonymous pages. **Measured on this machine: 3.9:1** (`zramctl` showed 8.1 GB of pages held in 2.1 GB of physical RAM), so the real-world win is better than the rule of thumb suggests.

```bash
sudo dnf install -y zram-generator zram-generator-defaults
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

Because Fedora initializes zram at boot, attempting to reconfigure an active block device causes a Device or resource busy error. Reset the existing device first before restarting the swap unit:

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

`systemd-oomd` is enabled by default on Fedora, but its out-of-the-box settings (kill at 60%–80% memory pressure sustained for 20s–30s) react too slowly under heavy workloads. In modern Fedora, slice-level defaults also override service-level limits, requiring drop-ins for both `oomd.conf`, `user@.service`, and the user `slice.d`.

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

# 3. Override Fedora's per-slice defaults for user applications
sudo mkdir -p /etc/systemd/user/slice.d
sudo tee /etc/systemd/user/slice.d/99-oomd-user-slice.conf > /dev/null <<'EOF'
[Slice]
ManagedOOMMemoryPressure=kill
ManagedOOMMemoryPressureLimit=45%
EOF
```

#### Protect the desktop session:

Prevent `systemd-oomd` from killing the shell interface when an application runs out of memory:

```bash
mkdir -p ~/.config/systemd/user/plasma-plasmashell.service.d
tee ~/.config/systemd/user/plasma-plasmashell.service.d/50-oom.conf > /dev/null <<'EOF'
[Service]
ManagedOOMPreference=avoid
OOMScoreAdjust=-500
EOF
```

Apply and Verify

```bash
# Reload configurations
sudo systemctl daemon-reload
systemctl --user daemon-reload

# Restart services to apply limits immediately
sudo systemctl restart systemd-oomd
systemctl --user restart plasma-plasmashell.service

# Check active limits
oomctl
```

*(Expected: Default Memory Pressure Duration: 10s, and /user.slice/.../app.slice displaying Memory Pressure Limit: 45.00%).*

### 🪓 Layer 2b — earlyoom as the hard backstop

`systemd-oomd` is cgroup- and PSI-based, which means it reasons about *slices*. Docker containers live under `system.slice/docker.service` and aren't in its default watch set. `earlyoom` is dumber and better for exactly that case: it polls absolute free memory and kills the single biggest offender.

```bash
sudo dnf install -y earlyoom
sudo nano /etc/default/earlyoom
```

```bash
EARLYOOM_ARGS="-r 3600 -m 4 -s 20 \
  --avoid '^(systemd|systemd-.*|sshd|kwin_wayland|plasmashell|Xwayland|kded6|krunner|dbus-.*|sddm.*)$' \
  --prefer '^(node|Web Content|Isolated Web Co|firefox|code-insiders|dotnet|sqlservr|java)$' \
  -n"
```

```bash
sudo systemctl enable --now earlyoom
```

That means: trigger when free RAM drops below 4% *or* free swap below 20%, never touch the desktop session, preferentially kill Node/Chromium/SQL Server, and send a desktop notification (`-n`) so you know what died and why.

> Running both oomd and earlyoom is fine — they trigger on different signals and oomd will almost always act first. earlyoom exists for the cases oomd misses.

### 🧊 Layer 3 — cap Docker so it can never eat the machine

**Drop Docker Desktop.** On Linux it runs your containers inside a QEMU VM with a fixed memory allocation — you pay for the VM's RAM whether containers use it or not, typically 2–4 GB gone before you start. Docker Engine runs containers natively on your kernel with essentially zero overhead. On 16 GB this is the single biggest win available to you.

```bash
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
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

**Fedora + SELinux note:** bind mounts need a relabel flag or the container gets permission denied — use `-v $(pwd):/app:Z` (private) or `:z` (shared).

Replace Docker Desktop's GUI with something that costs ~15 MB:

```bash
sudo dnf copr enable atim/lazydocker -y && sudo dnf install -y lazydocker
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
**Ctrl + Alt + F3** → log in → `btop` or `pkill -9 node`. A TTY needs almost no memory to render, so it usually responds when Plasma won't.

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

### 🧹 Layer 5 — KDE-specific memory savings

**Remove KDE PIM (Akonadi) if you don't read mail here. This is the single biggest
win in this section — bigger than Baloo.**

Fedora KDE installs `kmail`, `korganizer` and `kaddressbook` by default, and Akonadi — the
storage backend behind them — starts regardless of whether you have ever opened one. It runs
its own MySQL/MariaDB server plus an agent process per data type.

Measured on this machine, with **zero mail accounts and zero stored messages**:

```
16 processes, 507 MB RSS, and a 125 MB database in ~/.local/share/akonadi
```

Check whether you actually use it before removing anything:

```bash
grep -c '^\[Instance ' ~/.config/akonadi/agentsrc     # configured agents; 0 means unused
find ~/.local/share/local-mail -type f | wc -l        # stored messages; 0 means unused
```

If both are `0`:

```bash
akonadictl stop
sudo dnf remove kmail korganizer kaddressbook akonadi-server   # ~95 packages
rm -rf ~/.local/share/akonadi
```

> Take a snapshot first (see *Layer 0* below). `akonadictl stop` alone reclaims the memory for
> the current session but Akonadi returns at next login; removing the packages is what makes
> it permanent.

**Disable Baloo (file indexer).** This is the big one for you specifically: Baloo will try to index every file in every `node_modules` directory on your disk. On an Nx monorepo that's hundreds of thousands of files, and it costs sustained CPU, RAM, and SSD writes for zero benefit.

```bash
balooctl6 disable
balooctl6 purge
```

Or: **System Settings → Search → File Search → uncheck "Enable File Search"**. Use `fzf` and `rg` instead — faster anyway.

**Disable crash reporting** (a few hundred MB and constant background CPU):

```bash
sudo systemctl disable --now abrtd abrt-journal-core abrt-oops abrt-xorg abrt-vmcore 2>/dev/null
```

**Cap the journal** so it doesn't grow to 4 GB on disk:

```bash
sudo sed -i 's/^#SystemMaxUse=.*/SystemMaxUse=500M/' /etc/systemd/journald.conf
sudo systemctl restart systemd-journald
```

**Optional — mask PackageKit** (Discover's backend; it wakes up periodically and can hold 200–300 MB):

```bash
sudo systemctl mask packagekit
```
> Trade-off: Discover will no longer install/update RPMs. Flatpaks still work. Since you update via `dnf` anyway, this is usually the right call — but skip it if you like the GUI.

**Konsole scrollback:** Settings → Edit Profile → Scrolling → **Fixed size: 10000 lines**. Unlimited scrollback across ten tabs of Docker logs is a genuine leak.

**Don't** disable KWin compositing. On Wayland you can't meaningfully, and the UHD 620 handles it in hardware for near-zero cost. Turning off blur/animations saves single-digit MB and makes the desktop feel worse.

### 📊 Your realistic 16 GB budget

| Component | Expected |
|---|---|
| Plasma 6.7 Wayland idle | 1.2–1.5 GB |
| Firefox + ~15 tabs + 3 pinned web apps | 1.5–2.5 GB |
| VS Code + TS language server on Nx monorepo | 1.5–3.0 GB |
| SQL Server container (capped) | 2.5 GB |
| nopCommerce .NET (workstation GC) | 0.5–1.0 GB |
| Postgres + Redis + gateway | 0.7 GB |
| Docker daemon + containerd | 0.3 GB |
| **Subtotal** | **~8.2–11.7 GB** |
| Headroom + zram relief | ~3–7 GB effective |

That fits — but only with the SQL Server cap and Node heap limit in place. Without them, SQL Server alone claims 12.8 GB and you're back to square one.

---

## 🚀 Phase 5: Applications

### 󰞵 Core dev tools & CLI

```bash
sudo dnf install -y \
  git git-lfs gh \
  python3 python3-pip python3-virtualenv \
  nodejs npm \
  dotnet-sdk-9.0 dotnet-sdk-10.0 \
  postgresql postgresql-server \
  unrar p7zip p7zip-plugins \
  btop htop ncdu fzf bat eza ripgrep fd-find jq tldr \
  zsh util-linux-user \
  obs-studio telegram-desktop libreoffice \
  fastfetch
```

> `btop` is now included — your old `alias top='btop'` pointed at a package that was never installed.

Postgres needs initialising if you run it on the host rather than in Docker:

```bash
sudo postgresql-setup --initdb
sudo systemctl enable --now postgresql
```
> Honestly: for your workload, run Postgres in Docker instead and skip the host install entirely. One less always-on service.

### 🦊 Firefox

Firefox ships with Fedora KDE, so there's usually nothing to install. Use the **Fedora RPM**, not the Flatpak — the RPM has VA-API hardware video decode wired up against the system ffmpeg you installed in Phase 3, while the Flatpak sandboxes its own (codec-limited) copy.

```bash
sudo dnf install -y firefox
```

> **Good news for your RAM problem.** Firefox is the better choice on a 16 GB dev box, and not by a little. Chromium-family browsers spin up a process per site *and* per extension; Firefox caps content processes (8 by default) and shares them across tabs. With 15+ tabs open you'll typically see 1–1.5 GB less resident memory than Helium would have used. Switching browsers did more for your headroom than most of the tweaks in Phase 4.

#### Memory settings (`about:config`)

Only three worth changing — don't go further than this:

| Preference | Set to | Why |
|---|---|---|
| `browser.tabs.unloadOnLowMemory` | `true` | Auto-discards background tabs under pressure — Firefox's equivalent of Memory Saver |
| `dom.ipc.processCount` | `4` | Halves per-process overhead. Trade-off: a crashed tab takes more siblings with it |
| `browser.sessionstore.interval` | `60000` | Session saves every 60s instead of 15s — fewer SSD writes |

Check `about:unloads` to see which tabs Firefox considers discardable, and `about:processes` for a live per-tab memory breakdown. That page is genuinely better than anything Chromium offers for diagnosing a memory spike.

#### Hardware video acceleration

Firefox on Wayland enables VA-API by default now. Verify at **`about:support` → Graphics** — look for `HARDWARE_VIDEO_DECODING: available` and `Compositing: WebRender`. If it says software, confirm `vainfo` still works from Phase 3 and that `media.ffmpeg.vaapi.enabled` is `true`.

#### KDE integration

Install the **Plasma Integration** add-on from addons.mozilla.org. The native host is already present on Fedora KDE (`plasma-browser-integration`). You get media controls in the Plasma panel and on the lock screen, downloads in KDE notifications, and open tabs searchable from KRunner.

#### Extensions — your list, ported

Direct Firefox equivalents exist for nearly all of them:

**Install:** uBlock Origin · Bitwarden · Tampermonkey · SponsorBlock · Return YouTube Dislike · Enhancer for YouTube · Cookie Editor · Proton VPN · Wappalyzer · Privacy Badger · To Google Translate · Buster Captcha Solver

**Drop these:** Decentraleyes (dead project — modern cache partitioning made it redundant), Disconnect, and Don't Track Me Google. On Firefox, uBlock Origin runs with **full MV2 `webRequest` blocking**, which Chromium removed. It genuinely covers what those three did, and Firefox's built-in Enhanced Tracking Protection (Settings → Privacy → **Strict**) covers the rest. That's four fewer background processes.

**Add for your work:** Angular DevTools (yes, it's on addons.mozilla.org — no Chromium needed), React DevTools if relevant, and **Multi-Account Containers** for keeping client/staging/prod logins separate without separate profiles.

Then import your Tampermonkey userscripts, and sign into Firefox Sync or import your Bitwarden vault.

### 󰳕 Editors

```bash
sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
sudo tee /etc/yum.repos.d/vscode.repo > /dev/null <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
autorefresh=1
type=rpm-md
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF

sudo dnf check-update
sudo dnf install -y code-insiders
```

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
# Vesktop (lighter Discord client)
sudo dnf install -y https://github.com/Vencord/Vesktop/releases/latest/download/Vesktop-*.x86_64.rpm
```

For **LinkedIn, Reddit, WhatsApp, X, YouTube Music, Figma, ChatGPT, Claude** — this is the one place Firefox costs you something. **Mozilla removed site-specific browser / PWA install support**, so there's no "Install page as app" menu item. Three options, best-first for your machine:

**1. Pinned tabs (recommended).** Right-click tab → **Pin Tab**. They persist across restarts, sit as small icons on the left, and — critically — **share Firefox's existing content processes**. Marginal cost per pinned tab is 50–150 MB rather than a whole new browser instance. On 16 GB this is far and away the right answer.

**2. PWAsForFirefox** — if you specifically want dock icons and separate windows:

```bash
sudo dnf copr enable filips/firefoxpwa -y
sudo dnf install -y firefoxpwa
```

Then install the companion extension from addons.mozilla.org. It creates real `.desktop` entries that show up in KRunner and pin to the panel. Each site runs in its own profile, so budget ~200 MB apiece — cheaper than Chromium PWAs, still not free.

**3. Keep a minimal Chromium** just for PWAs (`sudo dnf install -y chromium`). Only worth it if some site is genuinely broken in Firefox. It costs you a second browser engine in RAM, which defeats the point of switching.

> Whichever you pick: six always-open web apps is 1–1.5 GB permanently gone. Pin your three most-used, bookmark the rest.

### 🧩 Flatpaks (only where the RPM is worse)

```bash
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub com.github.tchx84.Flatseal
flatpak install -y flathub org.gimp.GIMP
```

> You no longer need `com.mattjakeman.ExtensionManager` — that was for GNOME Shell extensions. KDE gets widgets and themes from System Settings → **Get New...** buttons, built in.

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

### 🖥 Konsole

**Settings → Edit Current Profile:**

- Appearance → Font: **Maple Mono NF**, 11pt
- Appearance → Color scheme: Breeze Dark (or import a Catppuccin Latte scheme to match your syntax highlighting)
- Scrolling → **Fixed size: 10000 lines**
- General → Command: `/bin/zsh`

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
# NOTE: do NOT alias fd here. On Fedora the `fd-find` package installs the binary as
# `fd` already; `fdfind` is the Debian/Ubuntu name and does not exist. Aliasing it
# breaks a working command with `fdfind: command not found`.

# ---- Memory & Docker helpers ----
alias mem='free -h && echo && zramctl'
alias memhogs='ps aux --sort=-%mem | head -12'
alias cgtop='systemd-cgtop -m'
alias dps='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
alias dstats='docker stats --no-stream'
alias dprune='docker system prune -af --volumes && docker builder prune -af'
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

## ⚙️ Phase 7: KDE Personalization

Everything here is **System Settings** (`systemsettings` or Meta key → "System Settings"). No Tweaks tool, no extension manager.

### 🖱 Panel & Task Manager (replaces "Start Menu & Taskbar")

- Right-click panel → **Enter Edit Mode** to move, resize, or add widgets
- Pin your most-used apps: right-click app in Task Manager → **Pin to Task Manager**
- Suggested pin order, matching your old Windows layout: Dolphin · Firefox · Konsole · VS Code Insiders · Zed · lazydocker · Vesktop · WhatsApp · X · LinkedIn
- Consider **Icons-only Task Manager** — it's the closest thing to the Windows 11 taskbar you had

### ⌨️ Shortcuts worth setting immediately

System Settings → Shortcuts:

| Action | Suggested key |
|---|---|
| Konsole | `Meta + T` |
| Dolphin | `Meta + E` |
| KRunner | `Meta` or `Alt + Space` |
| System Monitor | `Ctrl + Shift + Esc` |
| Show Desktop | `Meta + D` |
| Overview | `Meta + W` |

### 🖼 GTK apps: KDE already themes them — don't "fix" this

`gtk-theme-name=Breeze` in `~/.config/gtk-3.0/settings.ini` looks wrong next to a Catppuccin
Plasma theme. It is not. Breeze there is the *widget style*; the **colours** come from
`kde-gtk-config`, whose kded module (`gtkconfig.so`) regenerates these from the live Plasma
colour scheme every time it changes:

```
~/.config/gtk-4.0/gtk.css      ~/.config/gtk-4.0/colors.css
~/.config/gtk-3.0/colors.css   ~/.gtkrc-2.0
```

Verified: all four carry the same mtime to the millisecond, and `colors.css` contains the
Catppuccin Latte hexes (`#eff1f5`, `#d20f39`). So GTK apps follow your Plasma theme for free.

**Consequence for dotfiles:** never version-control those four paths. A managed copy is
silently overwritten on the next theme change, and the symptom looks like a theming bug.
They are in `.chezmoiignore` for exactly this reason.

### 🌈 Appearance

- **Global Theme** → Breeze Dark (or Catppuccin via Get New Global Themes, to match your terminal)
- **Wallpaper** → right-click desktop → Configure Desktop and Wallpaper → restore yours
- **Fonts** → set to Maple Mono NF for Fixed width; leave the rest on Noto Sans
- **Night Light** → System Settings → Display → Night Light, enable sunset-to-sunrise

### 🖱 Touchpad & TrackPoint (T490s)

System Settings → **Mouse & Touchpad → Touchpad**:
- Enable **Tap-to-click**
- Enable **Natural scrolling** if you prefer it
- **Disable touchpad while typing** on
- TrackPoint middle-click scroll works out of the box on Wayland

### ⏱️ Autostart (replaces "Task Manager → Startup")

**System Settings → Autostart.** Add only what you truly need at login. Specifically: **do not** autostart Docker Desktop (you removed it), Vesktop, or Telegram — launching them on demand saves ~700 MB at login.

### 🔌 KDE Connect

Already installed. Pair your phone for clipboard sync, notifications, and file transfer — genuinely one of the best things about Plasma.

---

## 🧹 Phase 8: Maintenance

### ♻️ Everything Update

```bash
sudo dnf upgrade --refresh -y
flatpak update -y
sudo dnf autoremove -y
sudo fwupdmgr refresh && sudo fwupdmgr update
```

Save it as a function in `~/.zshrc`:

```bash
update-all() {
  sudo dnf upgrade --refresh -y && \
  flatpak update -y && \
  sudo dnf autoremove -y && \
  sudo flatpak uninstall --unused -y && \
  docker system prune -f && \
  echo "✅ Everything updated"
}
```

### ❌ Removing things

```bash
sudo dnf remove <package_name>
flatpak uninstall --delete-data <app_id>
sudo dnf autoremove
flatpak uninstall --unused
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
| Plasma crashed but system alive | `systemctl --user restart plasma-plasmashell` |
| Absolute last resort | **Alt + PrtSc + R, E, I, S, U, B** (in order, ~2s apart) — safe reboot with disk sync. Never hold the power button first. |

**Before any heavy build:** `capped nx build ... --parallel=2`

---

## 📌 If you do only five things

*Revised 2026-08-28 after measuring the running machine. Items 1–4 of the original list are
now done and holding: Docker Engine is in use, zram is at full size with swappiness 180, and
oomd+earlyoom have logged **zero OOM kills in 7 days**. What's left is different from what
this guide originally assumed.*

1. **Remove KDE PIM (Akonadi)** — 507 MB across 16 processes for zero mail accounts. Layer 5.
2. **Audit your browser and editor extensions.** This is where the memory actually is:
   Firefox measured **8.4 GB across 30 processes with 19 extensions**; VS Code **1.7 GB with
   99 extensions / 2.9 GB on disk**. Extensions inject content scripts into *every* tab, so
   the cost compounds. Use VS Code **Profiles** so the C#/C++/Java/F# language servers aren't
   resident during Angular work.
3. **Mask PackageKit and disable Baloo** — ~260 MB more, and no lost functionality if you
   update with `dnf` and search with `rg`/`fzf`.
4. **Get a rollback path** (Layer 0). Everything else here edits system state.
5. **Apply the settings you already wrote down.** The audit found the VS Code watcher
   excludes, the Firefox prefs and the Konsole scrollback cap were all documented in this
   file but never actually applied. A guide only helps once it's executed — which is why
   this repo now exists.

> **On SQL Server:** the original item 2 warned it would claim ~80% of host RAM. Still true
> *when you run it* — but this machine currently runs 19 containers (Postgres, Keycloak,
> KrakenD, Tryton) totalling **470 MB**. Docker is not the problem here. Keep the caps in the
> compose files for when SQL Server comes back.

---

## 🤖 This guide has an executable half

The repository around this file applies most of the above:

```bash
git clone <this-repo> ~/dotfiles && ~/dotfiles/bootstrap.sh
sudo ./system/apply.sh      # the /etc drop-ins from Phase 4
./scripts/reclaim.sh        # Layer 5, with a safety check before removing PIM
./scripts/doctor.sh         # verifies every claim in this document
```

`scripts/doctor.sh` is the important one: it checks swappiness, oomd/earlyoom, the reclaim
targets, the VS Code settings and the shell fixes, and tells you which are actually live —
so this guide can never quietly drift out of sync with the machine again.

**Terminals:** Ghostty (`ghostty` RPM) is installed alongside Konsole and is the lighter of
the two. Its config lives at `~/.config/ghostty/config.ghostty`.
