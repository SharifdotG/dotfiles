# 🖥 The Desktop Machine

**Machine:** Ryzen 5 3600 (6C/12T, Zen 2) · 16 GB DDR4-2400 · Radeon RX 570 8 GB
(Polaris, gfx803) · MSI B450M Mortar MAX · 500 GB Samsung 970 EVO NVMe +
1 TB WD 7200 RPM (NTFS, **kept**) · 450 W PSU
**Displays:** Esonic 22ELMW 1920×1080 (primary, right, ~102 ppi) · Samsung
S19F350 1366×768 (left, ~85 ppi) — both at 100 % scale
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

The 1 TB drive is staying as NTFS. Windows does not fully unmount an NTFS volume
when you "shut down" with **Fast Startup** enabled — it hibernates the kernel
instead and leaves the filesystem journal dirty. Linux's `ntfs3` driver reacts to
a dirty volume by **mounting it read-only**, silently. No error, no dialog: writes
just start failing, weeks later, and it reads like a failing disk.

So, in Windows, *before* you install anything:

1. **Control Panel → Power Options → Choose what the power buttons do →
   Change settings that are currently unavailable → uncheck *Turn on fast
   startup*.** Apply.
2. Shut down (not restart, not sleep). That shutdown is the one that leaves the
   NTFS volume clean.

If you skip this and later find the disk read-only, the fix is `sudo ntfsfix -d
/dev/sdXN` — but that is a repair, not a substitute. Do it in the right order.

`scripts/doctor.sh` checks the live mount options for exactly this, because a
read-only NTFS mount is invisible until you try to write.

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
  prefer it, and `nct6687d` is DKMS.
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

**Reboot after `system/apply.sh`.** It installs
`/etc/modprobe.d/99-amdgpu-ppfeaturemask.conf` and regenerates the initramfs, and
amdgpu only picks the option up on the next boot. The script says so, and
`doctor.sh` will show the old value until you do.

---

## Phase 2 — The 1 TB storage disk

Find it, and note that the repo deliberately does **not** manage this: a UUID is
machine-local inventory and this repo is public.

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT
sudo blkid /dev/sdXN
```

Mount point and `/etc/fstab` line:

```bash
sudo mkdir -p /mnt/storage
```

```fstab
UUID=<the-uuid>  /mnt/storage  ntfs3  rw,noatime,uid=1000,gid=1000,umask=022,windows_names  0 0
```

- `ntfs3`, not `ntfs-3g` — the in-kernel driver, far faster than the FUSE one for
  large files.
- `uid`/`gid`/`umask` because NTFS has no Unix ownership; without them the mount
  is root-owned and nothing you run can write to it.
- `windows_names` rejects filenames Windows cannot represent, which keeps the disk
  usable from a Windows box later.
- **`noatime`** — this is a 7200 RPM spinning disk; every read otherwise costs a
  seek and a write.

Then verify the way that matters:

```bash
sudo systemctl daemon-reload && sudo mount -a
findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS /mnt/storage
```

The options must contain `rw`. If they say `ro`, the volume is dirty — go back to
the Phase 0 gate. `doctor.sh` re-checks this on every run.

### ⚠️ Do not put a Steam library here

**Steam does not support NTFS.** Proton games break on its case-insensitivity and
its lack of real symlinks — typically as a game that downloads and installs
perfectly and then will not launch, with nothing useful in the logs. Keep game
libraries on the NVMe. `doctor.sh` fails if it finds a `steamapps` directory on
an NTFS mount.

Media, archives and `~/Backup` output (`db-backup.sh`, `agents-backup.sh`) are
fine here — they are large, sequential and cold, which is exactly what a spinning
disk is good at.

---

## Phase 3 — GPU: proving the driver is real

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

`system/apply.sh` writes `/etc/modprobe.d/99-amdgpu-ppfeaturemask.conf`, which
unlocks amdgpu's power-management interface. **A modprobe.d option, not a kernel
command-line parameter** — every guide reaches for the bootloader, but that means
editing machine-local files that differ between GRUB and systemd-boot. amdgpu
loads from the initramfs and mkinitcpio's `modconf` hook copies
`/etc/modprobe.d/*.conf` in, so this reaches the module the same way and works
under either bootloader.

After the reboot:

```bash
cat /sys/module/amdgpu/parameters/ppfeaturemask     # 0xffffffff
ls /sys/class/drm/card*/device/pp_od_clk_voltage    # must exist
systemctl status lactd
```

If the mask still reads its old value, `/etc/modprobe.d` never reached the
initramfs: check that `HOOKS` in `/etc/mkinitcpio.conf` contains `modconf`, or
fall back to `amdgpu.ppfeaturemask=0xffffffff` on the kernel command line.

**LACT owns the GPU; gamemode owns the CPU.** `home/private_dot_config/gamemode.ini`
sets `apply_gpu_optimisations=0` on purpose. gamemode can drive the same sysfs
knobs LACT does, and two daemons writing one set of files is the
TLP-versus-`power-profiles-daemon` mistake from the setup guide wearing different
names: last writer wins, the fan curve silently reverts, nothing errors.

### Board sensors

The B450M Mortar MAX's Nuvoton chip needs the out-of-tree `nct6687` driver;
the in-tree `nct6683` binds it but reports almost nothing.
`packages/cpu-amd.tsv` installs `nct6687d-dkms-git` and
`system/modules-load.d/99-nct6687.conf` loads it.

```bash
sensors | grep -iE 'fan|tctl'
```

Loaded is not the same as bound — a module can insert on a board without the chip
and report nothing at all. `doctor.sh` checks for an actual fan RPM, which is the
only honest proof.

**DKMS caveat:** the driver rebuilds on every kernel update, and when that build
fails the module is simply absent on the next boot, with no error anywhere you
would look. If fans vanish from `sensors` after an update, run `dkms status`
first.

---

## Phase 4 — Gaming

`packages/gaming.tsv` installs Steam, gamemode, MangoHud, gamescope, Lutris, the
Wine stack, ProtonUp-Qt and umu-launcher, plus every 32-bit half.

**The 32-bit halves are the point.** A 64-bit-only install runs Steam fine and
then renders every 32-bit title on the CPU, because the Vulkan loader substitutes
`llvmpipe` rather than failing. `doctor.sh` checks that
`/usr/share/vulkan/icd.d/radeon_icd.i686.json` and the i686 RADV library are both
present, and that `multilib` is in the **live** repo list — a commented-out
multilib does not error at bootstrap, the `lib32-*` names are just quietly
dropped with one warning you will not remember three weeks later.

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

## Phase 5 — DaVinci Resolve

Read this section before installing, because two of its limits are not fixable
and it is better to know now.

### Limit 1: the free version cannot open your footage

**Free DaVinci Resolve on Linux cannot decode or encode H.264 or H.265 at all**,
in any container. This is a licensing decision, not a bug, and not something
configuration can change. Which means: phone video, screen recordings, most
camera output and most of what you already have will not import.

Options, honestly:

- **Transcode first.** DNxHR in a MOV is the usual intermediate:
  ```bash
  ffmpeg -i in.mp4 -c:v dnxhd -profile:v dnxhr_hq -pix_fmt yuv422p -c:a pcm_s16le out.mov
  ```
  Fine for a handful of clips, tedious as a permanent workflow.
- **Buy Resolve Studio.** Removes the codec restriction. Note it does *not* fix
  Limit 2.
- **Use Kdenlive or Shotcut instead** (both in `extra`). They go through ffmpeg,
  handle H.264/H.265 natively, and use VA-API on the RX 570 with no ROCm anywhere
  near them. If Resolve's colour tools are not what you are actually there for,
  this is the low-friction answer.

### Limit 2: Polaris was dropped from ROCm

Resolve needs an OpenCL device. AMD removed Polaris/gfx803 support after ROCm
5.7, and the repos now ship 7.x, which enumerates **no device** on an RX 570 —
Resolve then refuses to start or hangs on the splash screen.

`scripts/resolve-opencl.sh` handles it:

```bash
scripts/resolve-opencl.sh --dry-run    # see exactly what it will do
scripts/resolve-opencl.sh
```

It downgrades `rocm-core`, `comgr`, `rocm-opencl-runtime` and `rocm-cmake` to
5.7.1 from the Arch Linux Archive in one transaction, holds them with an
`IgnorePkg` line written **into `[options]`** (appended at the end of
`pacman.conf` it would land in the last repo section and silently not apply), and
then proves the result with `clinfo` rather than reporting success because
pacman exited 0. It refuses to run on a non-AMD GPU.

Then launch through the wrapper, never `/opt/resolve/bin/resolve` directly:

```bash
resolve        # ~/.local/bin/resolve, sets ROC_ENABLE_PRE_VEGA=1
```

The variable is scoped to the wrapper on purpose — in `environment.d` it would
re-enable an untested AMD code path for every OpenCL consumer on the machine. The
`.desktop` override in `~/.local/share/applications/` points the menu entry at the
same wrapper, so launching from the application menu behaves identically. Without
it, Resolve works in a terminal and fails from the menu, which is a confusing way
to lose an afternoon.

**Costs of the pin, stated plainly:** those four packages stop receiving fixes for
as long as it is on, and a future `mesa` or `glibc` can break a 5.7.1 binary that
nothing is rebuilding. `scripts/resolve-opencl.sh --undo` removes it.
`--status` reports where things stand. `doctor.sh` checks both that an OpenCL
device is visible and that the hold is still in `pacman-conf IgnorePkg`, because
one `pacman -Syu` that quietly upgraded past it is how this breaks again in six
months.

If the script finishes and `clinfo -l` still shows nothing, the workaround has
run out — that is the point to switch to Kdenlive, not to keep pulling packages
out of the archive.

---

## Phase 6 — Affinity

Affinity has no Linux build. As of **Wine 10.17+ it runs on stock Wine** — the
patched ElementalWarrior fork that every older guide insists on is no longer
required. `packages/gaming.tsv` already installs `wine`, `wine-mono`,
`wine-gecko` and `winetricks`, so the dependencies are in place.

The installation itself is **not automated, deliberately**: it needs your own
Affinity installers, it is interactive, and it builds a Wine prefix — none of
which belong in a non-interactive `bootstrap.sh` that is supposed to be a cheap,
idempotent re-run.

Use the AffinityOnLinux scripts (<https://github.com/seapear/AffinityOnLinux>),
which detect Arch and pull what they need. Keep the prefix out of `$HOME`'s
default location if you would rather it were on the storage disk — but note that
a Wine prefix on NTFS hits the same case-sensitivity problems Steam does, so the
NVMe is the safer home for it.

Krita, Inkscape and GIMP are all in `extra` and native, if the Wine prefix turns
out to be more trouble than the specific Affinity features are worth.

---

## What doctor.sh checks that the laptop's run does not

Two extra sections, both gated on `PROFILE=desktop`:

**Desktop hardware** — `amdgpu` `ppfeaturemask` read from `/sys/module/`;
`pp_od_clk_voltage` present; `lactd` enabled; `nct6687` loaded *and* `sensors`
reporting a real fan RPM; every NTFS mount actually `rw`.

**Gaming & creative stack** — `multilib` in the live repo list; the 32-bit RADV
ICD and library present; Steam installed; the gamemode user unit present; no
Steam library on an NTFS mount; an OpenCL device visible; ROCm still held at the
pinned version.

Plus, on both machines, the new **GPU & display stack** section: chezmoi's stored
`gpu` matching the live PCI read, `LIBVA_DRIVER_NAME` correct for the card,
VA-API actually initialising, and the Vulkan driver not being `llvmpipe`.

None of those read a file this repo wrote. That is the whole point.
