# 🖥 The Desktop Machine

**Machine:** Ryzen 5 3600 (6C/12T, Zen 2) · 16 GB DDR4-2400 · Radeon RX 570 8 GB
(Polaris, gfx803) · MSI B450M Mortar MAX · 500 GB Samsung 970 EVO NVMe +
1 TB Seagate ST1000LM024, 2.5" **5400 RPM** (NTFS today, **reformatted** into
the game library) · 450 W PSU
**Displays:** Esonic 22ELMW 1920×1080 (primary, right, ~102 ppi) · Samsung
S19F350 1366×768 (left, ~85 ppi) — both at 100 % scale
**Network:** Realtek RTL8111H gigabit ethernet (in-tree `r8169`) · MediaTek
MT7601U 802.11n USB Wi-Fi (`148f:7601`, in-tree `mt7601u`) — see Phase 0
**Target:** CachyOS + KDE Plasma 6 / Wayland, Windows removed from the NVMe

This is the desktop's counterpart to `docs/SETUP-GUIDE.md`. It covers **only what
differs from the laptop.** Everything in the setup guide's Phase 4 — zram,
swappiness, earlyoom, systemd-oomd, the browser cap — applies here unchanged and
is not repeated: both machines have 16 GB, so every number was already right.

> The single most useful thing to know before starting: `scripts/doctor.sh` grows
> two extra sections on this machine and they are the acceptance test. Do not
> declare a step finished because a command exited 0 — check the section.

---

## Phase 0 — Before you wipe Windows

### ⚠️ The gate: shut Windows down *properly*, once

The 1 TB drive holds data you are keeping, and the only copy is on it. Windows
does not fully unmount an NTFS volume when you "shut down" with **Fast Startup**
enabled — it hibernates the kernel instead and leaves the filesystem journal
dirty. Linux's `ntfs3` driver reacts to a dirty volume by **mounting it
read-only**, silently.

That used to be a nuisance. Now it is the thing standing between you and your
files: Phase 2 copies that data off before the disk is reformatted, and a
read-only mount is fine for reading — but a volume dirty enough to confuse the
driver is a volume you do not want to be reading your only copy from.

So, in Windows, *before* you install anything:

1. **Control Panel → Power Options → Choose what the power buttons do →
   Change settings that are currently unavailable → uncheck *Turn on fast
   startup*.** Apply.
2. Shut down (not restart, not sleep). That shutdown is the one that leaves the
   NTFS volume clean.

If you skip it and the disk later mounts read-only or refuses, `sudo ntfsfix -d
/dev/sdXN` is the repair — but do it in the right order and you never need it.

### BIOS (MSI B450M Mortar MAX)

Press **Delete** at the MSI splash.

- **OC → DRAM Setting → A-XMP → Profile 1.** The DDR4-2400 kit runs at 2133
  otherwise, and on Zen 2 memory clock drives the Infinity Fabric — this is free
  performance, not an overclock.
- **Settings → Advanced → Integrated Peripherals → SATA Mode → AHCI.** Never RAID;
  Linux will not see the disks in RAID mode.
- **Settings → Advanced → Windows OS Configuration → Fast Boot → Disabled**, and
  **BIOS UEFI/CSM Mode → UEFI**.
- **Settings → Advanced → Wake Up Event Setup**: turn off Wake from USB unless you
  want the machine waking on a mouse nudge.
- **Secure Boot → Disabled.** Consistent with the laptop; `fwupd` and DKMS both
  prefer it, and `nct6687d` (the B550 board-sensor driver) is DKMS.
- Note the BIOS version. B450 boards needed a BIOS update to boot Zen 2 at all, so
  if the board has been running the 3600 it is already new enough.

### Install

Install CachyOS **to the NVMe only**. In the installer, choose manual
partitioning and *do not touch* the 1 TB disk — not even to add a mount point.
Mount it afterwards, from a running system, where a mistake is recoverable.

Match the laptop otherwise: btrfs + zstd, **no swap partition** (zram only — see
the setup guide), and let the installer set the RTC to UTC. With Windows gone
there is no reason to use local time, and `timedatectl show -p LocalRTC` must
read `no`.

Pick the **v3** repo tier. Zen 2 is `x86-64-v3`, same as the laptop — `os/cachyos/prep.sh`
detects this from `ld.so` and `doctor.sh`'s Platform check verifies it, because a
v4 package on a v3 CPU installs cleanly and then dies with SIGILL at runtime,
which reads exactly like failing RAM.

### Network — bootstrap over ethernet

**Both adapters work with in-tree drivers. Neither needs a DKMS package, and
none is in `packages/`** — that absence is deliberate, not an oversight:

| | Chip | Driver | Firmware |
|---|---|---|---|
| Ethernet | Realtek RTL8111H | `r8169` | `linux-firmware-realtek` |
| Wi-Fi | MediaTek MT7601U (`148f:7601`) | `mt7601u` | `linux-firmware-mediatek` |

Verified on the laptop with the dongle attached: `mt7601u` binds it, the
firmware loads, and it comes up as a NetworkManager-managed `wlan*` device with
no configuration at all.

**Use the ethernet cable for `bootstrap.sh` anyway.** It pulls the better part of
a gigabyte of packages, and the MT7601U is a single-band 802.11n dongle - the
slow path on a step where a dropped connection means a half-finished pacman
transaction.

The firmware is the part worth knowing about. `mt7601u` is useless without
`/usr/lib/firmware/mt7601u.bin.zst`, which comes from the `linux-firmware-mediatek`
split package - so `packages/core.tsv` lists `linux-firmware` (the meta-package
over every vendor split) explicitly rather than trusting the installer to have
pulled it in. **Nothing in `base` or in the kernel package depends on it.**

---

## Phase 1 — Bootstrap

```bash
git clone https://github.com/SharifdotG/dotfiles ~/dotfiles && ~/dotfiles/bootstrap.sh
```

Nothing needs a flag. `lib/detect.sh` reads the chassis type, the CPU vendor and
the GPU's PCI vendor id, so the machine identifies itself:

```
==> profile=desktop / cpu=amd / gpu=amd
==> manifests: core.tsv dev.tsv reliability.tsv desktop.tsv cpu-amd.tsv gpu-amd.tsv gaming.tsv creative.tsv
```

If that line says anything else, stop and fix it before continuing — every later
step keys off it. Override with `--profile=desktop`, or put one word in
`/etc/dotfiles-profile`.

Then, as on the laptop:

```bash
sudo ./system/apply.sh
sudo usermod -aG docker "$USER"
./scripts/secrets-setup.sh
./scripts/git-credentials.sh     # a NEW PAT - tokens are per machine, never synced
./scripts/doctor.sh
```

**No reboot needed after `system/apply.sh`** on a fresh machine. It installs no
`/etc/modprobe.d` file and does not touch the initramfs, and the board sensor
driver is loaded during the run rather than waiting for the next boot.

The one exception is a machine that still carries the old
`/etc/modprobe.d/99-amdgpu-ppfeaturemask.conf`: `apply.sh` removes it, regenerates
the initramfs, and **that** needs a reboot to take effect. It says so when it
happens. See [Fan curve and power limit](#fan-curve-and-power-limit-lact) for why
that file is gone.

---

## Phase 2 — Migrating the 1 TB disk into the game library

The disk arrives as NTFS holding data worth keeping (**under 200 GB**), and
leaves as a Linux filesystem holding that data *and* the Steam and Heroic
libraries. Three stages, each gated on the one before. **Do not start this until
Phase 1 is finished** — you want a working system, not a live USB, doing the
copying.

This is a runbook, not a script. It runs once, it is destructive at stage 3, and
the UUIDs are machine-local inventory that this public repo deliberately does not
carry.

### Stage 1 — Copy off, read-only

Mount it **read-only**. Nothing writes to the source until the copy is verified.

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID
sudo mkdir -p /mnt/old
sudo mount -o ro,noatime /dev/sdXN /mnt/old
```

**Measure before committing to anything:**

```bash
du -sh /mnt/old                 # how much there is
df -h /home                     # how much room there is
```

**The gate: free space must be at least 1.2× the data.** The margin is not
padding — `rsync` needs room for partial files, and btrfs needs room to not go
read-only at 100 % full, which is a genuinely unpleasant way to end an evening.
If it does not fit, stop and use an external drive as the staging area instead.

```bash
mkdir -p ~/Storage-staging
rsync -aHAX --info=progress2 /mnt/old/ ~/Storage-staging/
```

### Stage 2 — Verify by content, not by exit status

`rsync` exiting 0 says it finished, not that the bytes match. Check the bytes.
This is the same discipline `scripts/db-backup.sh` and `db-restore.sh` already
apply to database dumps — sha256 manifests on both sides, compared before
anything is destroyed.

```bash
cd /mnt/old        && find . -type f | sort | xargs -d'\n' sha256sum > /tmp/old.sha256
cd ~/Storage-staging && find . -type f | sort | xargs -d'\n' sha256sum > /tmp/new.sha256
diff /tmp/old.sha256 /tmp/new.sha256 && echo "IDENTICAL - safe to reformat"
```

**If that `diff` prints anything, do not continue.** Re-run the `rsync`; it is
incremental and cheap the second time.

### Stage 3 — Reformat, and only then

```bash
sudo umount /mnt/old
sudo mkfs.ext4 -L games /dev/sdXN
```

**ext4, not btrfs, and this is a deliberate departure from the NVMe.** btrfs is
right for a root filesystem — that is where snapshots and `snap-pac` earn their
keep. It is wrong for a games disk: copy-on-write fragments the large files that
games are made of, every shader-cache write becomes a new extent, and there is
nothing here worth snapshotting because Steam can re-download all of it. If you
want subvolumes anyway, use btrfs with `nodatacow` set on the library directory
and accept that you have traded throughput for tidiness.

`/etc/fstab`, by UUID (`sudo blkid /dev/sdXN`):

```fstab
UUID=<the-uuid>  /mnt/games  ext4  defaults,noatime  0 2
```

`noatime` matters here more than on the NVMe: this is a 5400 RPM 2.5" spinning
disk, and every access-time update is a seek plus a write on a drive whose whole
job is sequential reads. The slower the spindle, the more each avoided seek is
worth - this is not a 7200 RPM desktop drive, and the option earns more here than
it would on one.

```bash
sudo mkdir -p /mnt/games && sudo systemctl daemon-reload && sudo mount -a
sudo chown "$USER:$USER" /mnt/games
findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS /mnt/games
```

Then move the data back, verify **again**, and only then delete the staging copy:

```bash
mkdir -p /mnt/games/Storage
rsync -aHAX --info=progress2 ~/Storage-staging/ /mnt/games/Storage/
cd /mnt/games/Storage && find . -type f | sort | xargs -d'\n' sha256sum > /tmp/final.sha256
diff <(sed 's|  ./|  |' /tmp/old.sha256) <(sed 's|  ./|  |' /tmp/final.sha256) &&
  rm -rf ~/Storage-staging
```

### Stage 4 — Point the launchers at it

- **Steam** → Settings → Storage → the `+` → `/mnt/games/SteamLibrary`.
- **Heroic** → Settings → Default install path → `/mnt/games/Heroic`.

Both libraries belong here rather than on the NVMe: a 500 GB NVMe holding the OS
plus a modern game library fills up fast, and large sequential reads that are not
latency critical are the workload a spinning disk handles least badly. Shader
caches stay on the NVMe where Steam already puts them (`~/.steam`), and that is
the part that actually benefits from the fast disk.

**Be honest about the drive, though.** A 5400 RPM 2.5" disk is slow even by
spinning-disk standards, so expect longer level loads and a visible first-run
shader compile. For the games actually played on this machine that is a
non-issue; it is not the disk to put a big open-world title on. If one ever
matters enough, move that single game to the NVMe rather than rethinking the
split.

**The reason this whole phase exists:** while the disk was NTFS, none of it was
possible. Steam does not support NTFS libraries — Proton breaks on its
case-insensitivity and its lack of real symlinks, typically as a game that
installs perfectly and then will not launch, with nothing useful in the logs.
`scripts/doctor.sh` still fails if it ever finds a `steamapps` directory on an
NTFS mount, because that trap is one reformat away from being re-set.

## Phase 3 — GPU: proving the driver is real

> **NB — the card is a Sapphire RX 570 8 GB, and a tool may tell you otherwise.**
> Under Windows this machine ran a *modded* display driver that reports the card
> as an **"RX 580X 4 GB"**. That name is a driver artefact, not the hardware: an
> automated cross-check of this repo read it and "found" that every RX 570 / 8 GB
> reference here was wrong. It is not. Linux uses the in-tree `amdgpu` driver and
> needs no such mod, so `lspci` and `radeontop` report the real card. Both are
> Polaris 20 / gfx803 in any case, so **no package or driver decision changes
> either way** - only the VRAM figure and the PSU arithmetic below would, and
> those are written for the real 8 GB card. Do not "correct" them.

This is the section worth reading twice, because **every failure mode here is
silent.** Vulkan does not error when the driver is missing; the loader falls back
to `llvmpipe` and renders on the CPU. VA-API does not error when the driver name
is wrong; it just stops decoding.

`home/private_dot_config/environment.d/50-wayland.conf.tmpl` sets
`LIBVA_DRIVER_NAME=radeonsi` when `.gpu` is `amd` (it is `iHD` on the laptop —
setting the laptop's value here would disable hardware video decode outright).

Check all of it live, after a **re-login** (environment.d is read by the systemd
user manager at session start):

```bash
systemctl --user show-environment | grep LIBVA   # radeonsi
vainfo | head -5                                 # must name a Mesa Gallium driver
vulkaninfo --summary | grep driverName           # radv - NOT llvmpipe
```

`doctor.sh`'s "GPU & display stack" section runs all three, plus one more: it
compares the `gpu` value chezmoi baked into `~/.config/chezmoi/chezmoi.toml` at
init against a fresh PCI read. Swap a card and that stored answer goes stale
without anything noticing — this is the house rule applied to the split itself.

### Fan curve and power limit (LACT)

**This repo does not set `amdgpu.ppfeaturemask`, and the absence is deliberate.**
LACT still drives the fan curve and the power limit: those go through the standard
hwmon `pwm1` node, which exists on stock amdgpu and needs nothing unlocked. What
is given up — knowingly — is OverDrive clock/voltage editing.

```bash
ls /sys/class/drm/card*/device/hwmon/hwmon*/pwm1   # fan control, must exist
systemctl status lactd
cat /sys/module/amdgpu/parameters/ppfeaturemask    # whatever the driver chose
```

#### Why it was removed — 2026-09-05

`apply.sh` used to install `/etc/modprobe.d/99-amdgpu-ppfeaturemask.conf` with
`options amdgpu ppfeaturemask=0xffffffff`. After a bootstrap that finally pushed
it into the initramfs, the desktop froze for ~10 seconds, recovered, and froze
again, on every boot. **10000 ms is amdgpu's default `lockup_timeout`**, so the
period *was* the diagnosis: the GPU was hanging, being reset, and hanging again.

`0xffffffff` is not "OverDrive on". It forces every PowerPlay bit on, and the
Polaris default `0xfff7bfff` differs from it by exactly two:

| bit | name | wanted? |
|---|---|---|
| `0x4000` | `PP_OVERDRIVE_MASK` | yes — this is the one LACT needs |
| `0x80000` | `PP_GFX_DCS_MASK` | **no** — off by default on gfx803 |

The removed file argued *"there is no benefit to being surgical here on a card you
own"*. The benefit is that the driver's defaults encode which bits are safe on
which silicon, and `0xffffffff` discards that wholesale. The value one would
actually want is `0xfff7ffff` (default `|` `PP_OVERDRIVE_MASK`) — **not**
`0xffffffff`, and not the `0xfffd7fff` the wiki quotes, which also clears GFXOFF
and stutter mode.

Two things make it inert until suddenly it is not, and both are worth knowing:
amdgpu loads from the **initramfs**, so a `modprobe.d` option does nothing until
the image is rebuilt; and under Limine, `mkinitcpio -P` rebuilds the image while
`limine-mkinitcpio` is what makes the bootloader actually *consume* it. The bad
mask sat harmless for a while for exactly that reason, then went off.

If you ever want it back it is now gated behind `DOTFILES_HW_TUNING` — see
[Kernel-level tweaks are opt-in](#kernel-level-tweaks-are-opt-in).

#### Kernel-level tweaks are opt-in

Everything else this repo writes is a config file: get it wrong and you fix it by
editing a file. A module parameter is different in kind — the kernel applies it at
boot, before anything you would use to fix it exists. So `system/apply.sh` refuses
to write into `/etc/modprobe.d` unless you say so explicitly:

```bash
echo on | sudo tee /etc/dotfiles-hw-tuning     # persistent
sudo DOTFILES_HW_TUNING=on ./system/apply.sh   # or per-run
```

Off by default, and the default is the point: a plain `./bootstrap.sh &&
sudo ./system/apply.sh` on a clean machine cannot change how the kernel drives the
hardware. **Removal is never gated** — a guard that can block un-breaking a machine
is worse than no guard.

**LACT owns the GPU; gamemode owns the CPU.** `home/private_dot_config/gamemode.ini`
sets `apply_gpu_optimisations=0` on purpose. gamemode can drive the same sysfs
knobs LACT does, and two daemons writing one set of files is the
TLP-versus-`power-profiles-daemon` mistake from the setup guide wearing different
names: last writer wins, the fan curve silently reverts, nothing errors.

### Board sensors

Two drivers are candidates: the kernel's in-tree `nct6775`, and the out-of-tree
`nct6687` (`nct6687d-dkms-git`) for NCT6687D chips.

**`system/apply.sh` probes; it does not guess.** It loads a candidate, checks
whether a hwmon device actually appeared, and unloads again if not — installing a
`/etc/modules-load.d/` drop-in only for a driver that genuinely bound on *this*
machine, and installing **nothing** when neither does.

That replaces a regex on the DMI board name (`[bB]450` → `nct6775`, everything
else → `nct6687`). A board name is a marketing string and the Super-I/O chip is
the fact; the two are only correlated, and MSI ships revisions. Worse, the `else`
was not a fallback but an assertion — every board that did not match, *including
one where `board_name` could not be read at all*, was declared NCT6687D. Loading
a Super-I/O driver for a chip that is not there is not free: the driver and the
ACPI EC can contend for the same index/data ports.

```bash
sensors | grep -iE 'fan|tctl'
```

```bash
sensors | grep -iE 'fan|tctl'
```

Loaded is not the same as bound — a module can insert on a board without the chip
and report nothing at all. `doctor.sh` checks for an actual fan RPM, which is the
only honest proof, and it counts fan inputs **on the board driver's own hwmon
device** rather than across all of `sensors`. That scoping is not fussiness:
amdgpu publishes its own hwmon with a `fan1`, so the unscoped version went green
off the *GPU* fan on a machine where the board driver was never loaded.

The load happens during the run, not at the next boot: `/etc/modules-load.d` is
read once, by `systemd-modules-load.service` at boot, and nothing re-reads it — so
otherwise a correctly configured machine shows no board sensors until it restarts.
The probe gets this for free, since it has to insert the module to find out
whether it binds.

**If nothing binds but the board does have a Nuvoton chip**, look at
`dmesg | grep -i nct`. The usual answer is `Sensor is bound by ACPI`, which needs
`acpi_enforce_resources=lax` on the kernel command line. This repo does not set
kernel command-line parameters — that is exactly the class of change
`DOTFILES_HW_TUNING` exists to hold back — so that one is yours to make by hand.

**DKMS caveat (for B550 / nct6687):** the out-of-tree driver rebuilds on every kernel update,
and when that build fails the module is simply absent on the next boot, with no error
anywhere you would look. If fans vanish from `sensors` after an update, run `dkms status`
first. B450 boards using in-tree `nct6775` are unaffected.

---

## Phase 4 — Gaming

`packages/gaming.tsv` installs Steam, **Heroic**, gamemode, MangoHud, gamescope,
Lutris, the Wine stack, ProtonUp-Qt and umu-launcher, plus every 32-bit half.

**Heroic Games Launcher is the Epic Games Launcher replacement**, and also covers
GOG and Amazon. It is a GUI over `legendary`, the command-line Epic client, and
runs titles through Proton or Wine. Legendary on its own is CLI-only; Heroic is
the better-maintained path for an Epic library and the one that does not require
you to remember a command per game. Point its default install path at
`/mnt/games/Heroic` — see Phase 2, Stage 4.

**The 32-bit halves are the point.** A 64-bit-only install runs Steam fine and
then renders every 32-bit title on the CPU, because the Vulkan loader substitutes
`llvmpipe` rather than failing. `doctor.sh` checks that `multilib` is in the
**live** repo list — a commented-out multilib does not error at bootstrap, the
`lib32-*` names are just quietly dropped with one warning you will not remember
three weeks later — and then checks the two things the loader actually consults:

```bash
cat /usr/share/vulkan/icd.d/radeon_icd.json   # "library_path": "libvulkan_radeon.so"
ldconfig -p | grep libvulkan_radeon           # ... (libc6) => /usr/lib32/...
```

There is **one** ICD manifest now, not one per architecture. Mesa 26 ships an
arch-neutral `radeon_icd.json` whose `library_path` is the bare soname, and the
32-bit loader resolves it out of `/usr/lib32` itself; `lib32-vulkan-radeon` ships
the `.so` and no manifest at all. So `library_path` staying **relative** is the
thing that matters — an absolute `/usr/lib/...` in there would hand a 32-bit
process the 64-bit driver, failing exactly the silent way this section is about.

Both of these checks were previously written against the old packaging
(`radeon_icd.i686.json`, and a Debian-style `libc6,x86-32` ldconfig label that
Arch never prints) and so could not pass on any machine. They reported red on a
working stack for as long as they existed, which is worse than not checking:
a permanently-failing check trains you to skim past the one that is real.

Per-game launch options in Steam:

```
gamemoderun mangohud %command%
```

MangoHud's config is at `~/.config/MangoHud/MangoHud.conf` and shows `gpu_name`
and `vulkan_driver` deliberately: those two fields are the llvmpipe tripwire, in
the one place you will actually be looking.

**The RX 570's real performance lever is resolution, not settings.** It is an
8 GB Polaris card driving a 1080p panel; rendering at 720p and letting gamescope
upscale usually beats dropping texture quality:

```
gamescope -w 1280 -h 720 -W 1920 -H 1080 -F fsr -f -- gamemoderun %command%
```

Neither monitor supports FreeSync, so VRR and Hyprland-style tearing options do
not apply here — cap frame rate instead if a game runs hot.

**Power:** a 3600 (65 W) plus an RX 570 (~150 W, transient spikes higher) peaks
around 330 W. A healthy 450 W unit has the headroom. If the machine reboots under
load rather than crashing, suspect the PSU before the GPU — that is what an
over-current trip looks like.

---

## Phase 5 — Video: Kdenlive

`packages/creative.tsv` installs `kdenlive` plus `ffmpeg`, `frei0r-plugins`,
`mediainfo` and two Qt image-format packages. Nothing to configure — it decodes
H.264/H.265 natively through ffmpeg and uses VA-API on the RX 570, which the
shared "GPU & display stack" section of `doctor.sh` already verifies. Put project
media on `/mnt/games/Storage` and the render cache on the NVMe.

### Why DaVinci Resolve is not here

It was, briefly, along with a 229-line script to make it work. Both are gone, and
the reasons are worth keeping so nobody re-adds them:

1. **Free Resolve on Linux cannot decode or encode H.264 or H.265 at all**, in
   any container. A licensing decision, not a bug, and not something
   configuration can change — so phone video, screen recordings and most camera
   output simply do not import without transcoding every clip to DNxHR first.
2. **AMD dropped Polaris/gfx803 from ROCm after 5.7**, and the repos ship 7.x,
   which enumerates **no OpenCL device** on an RX 570. Resolve then refuses to
   start. The only route was pinning four packages to a 2023 release out of the
   Arch Linux Archive and holding them there with `IgnorePkg` — forever, with no
   security fixes, and one `pacman -Syu` away from silently breaking.

Kdenlive has neither problem. If you ever need Resolve's colour tools
specifically, the honest options are Resolve Studio on a supported GPU, or a
newer card — not the pin.

### Why Affinity is not here

Affinity has no Linux build. It ran under Wine, needed your own installers and a
GUI, and could never be part of a non-interactive `bootstrap.sh`. Canva in the
browser replaced it. The Wine packages stay in `packages/gaming.tsv` because
Lutris needs them, but they are no longer justified by Affinity. Krita, Inkscape
and GIMP are all in `extra` and native if a local editor is wanted.

---

## What doctor.sh checks that the laptop's run does not

Two extra sections, both gated on `PROFILE=desktop`:

**Desktop hardware** — that **nothing** is forcing `amdgpu.ppfeaturemask`, from any
of the four places one can come from (`/etc`, `/run`, `/usr/lib/modprobe.d`,
`/proc/cmdline`); GPU fan control (`pwm1`) present; `lactd` enabled; a board sensor
driver actually **bound** — not merely loaded — *and* a real fan RPM on its own
hwmon; every NTFS mount actually `rw`.

**Gaming & creative stack** — `multilib` in the live repo list; the RADV ICD
manifest present *with a relative `library_path`*, and the 32-bit RADV library in
the linker cache; Steam, Heroic and Kdenlive installed; the gamemode user unit
present; no Steam library left on an NTFS mount.

Plus, on both machines: the **GPU & display stack** section (chezmoi's stored
`gpu` matching the live PCI read, `LIBVA_DRIVER_NAME` correct for the card,
VA-API actually initialising, the Vulkan driver not being `llvmpipe`), a
**Desktop theme** section (the Catppuccin Global Theme installed *and* selected,
the decoration still Breeze rather than the theme's Aurorae, the cursor still
WhiteSur, the splash package complete rather than merely named), and the font
rasterisation read-back described in the README's clobber table.

None of those read a file this repo wrote. That is the whole point.
