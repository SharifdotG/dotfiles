# Migration: Fedora KDE → CachyOS (KDE Plasma)

**Machine:** Lenovo ThinkPad T490s · i5-8365U (4C/8T, Whiskey Lake) · 16 GB (15.3 GiB usable)
· Intel UHD 620 · 238.5 GB Intel NVMe (`INTEL SSDPEKKF256G8L`)
**Plan:** external-drive backup, full wipe, fresh CachyOS install. No in-place upgrade.

> **This is a one-shot, destructive procedure.** Every stage ends in a gate. Do not start a
> stage until the previous gate passes. Once Stage 4 begins, the contents of the NVMe are
> gone.

**Read this from your phone or a second machine.** Between Stage 3 and Stage 5 the laptop
is a brick and `docs/SETUP-GUIDE.md` is on it — that is the whole reason this is a separate
file.

---

## Stage 0 — Push the dotfiles repo. Before reading further.

This repo now HAS a remote (`origin` → github.com/SharifdotG/dotfiles) — that part of Stage 0
is done. What is not done is the pushing: it sits on `master`, and work has repeatedly
accumulated ahead of the remote (3 unpushed commits and 6 dirty paths when the migration was
first planned; 3 unpushed commits again on 2026-09-04). It is the executable half of everything below, and
its only copy is on the disk you are about to erase.

1. Create the remote (`gh repo create`, or on github.com) and `git remote add origin …`.
2. **Commit everything untracked first.** Push a partial repo and you restore a guide that
   describes files the repo no longer contains.
3. Check `.gitignore` before `git add -A` — it excludes `.ssh/`, `*.key`, `*_ed25519`,
   `.config/gh/`, `.npmrc`, `*.age`. This repo is intended to be public.
4. Decide `master` vs `main` now. `home/dot_gitconfig.tmpl` sets `init.defaultBranch main`
   while the repo is on `master`. Renaming is free today and annoying later.

**GATE 0** — `git log --branches --not --remotes` is empty · `git status --porcelain` is
empty · the repo loads on github.com from another device.

---

## Stage 1 — Rehearse the install in a VM

The desktop is not changing — Plasma on CachyOS is Plasma. What *is* changing is the distro
underneath it, and that half is worth rehearsing where a mistake costs nothing.

KVM is already available on this machine (`/dev/kvm`, VT-x). Roughly 20 minutes:

```bash
sudo dnf install -y qemu-kvm libvirt virt-manager virt-install edk2-ovmf virt-viewer
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt "$USER"     # then log out and back in

virt-install \
  --name cachyos-test --memory 6144 --vcpus 4 \
  --cpu host-passthrough --machine q35 \
  --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no,firmware.feature1.name=enrolled-keys,firmware.feature1.enabled=no \
  --disk size=35,bus=virtio,format=qcow2 \
  --cdrom ~/Downloads/cachyos.iso --os-variant archlinux \
  --video model.type=virtio,model.acceleration.accel3d=yes \
  --graphics spice,gl.enable=yes,listen=none \
  --channel spicevmc --network default
```

> **NB — `--cpu host-passthrough` is mandatory, not a performance tweak.** QEMU's default
> `qemu64` model reports roughly x86-64-**v1** — no AVX2, not even SSE4.2. The guest would
> then pick generic repos, `os/cachyos/prep.sh` would report the wrong tier, and you would be
> rehearsing a different code path than the real machine.

> **NB — Secure Boot must be explicitly disabled in the VM too.** `--boot uefi` alone selects
> the *secboot* OVMF build with Microsoft keys enrolled, and CachyOS's bootloader is not
> signed by them. The symptom is the boot-device menu accepting your selection and silently
> returning to itself, with no error anywhere. The feature toggles above are what avoid it —
> verify with `virt-install --print-xml | grep secure-boot`, because a passing `--dry-run`
> does not prove the firmware choice.

What the VM validates, and it is the half you cannot test on Fedora at all:

- every package name in `packages/*.tsv` resolving against the real CachyOS repos — a single
  typo makes `pacman -Syu` abort atomically, so this is the highest-value check
- `os/cachyos/prep.sh`, the v3 repo tier, pacman config, and the AUR seam (`paru`)
- `system/apply.sh`: the `/etc` drop-ins, the unit-enabling loop, the zram reset dance
- `scripts/doctor.sh` running clean with no false failures

What it cannot validate: your mixed-DPI dual-monitor layout, VA-API on the UHD 620, the
TrackPoint, real memory pressure, or `thermald`/`fwupd`. None of those are worth a VM.

Remove it completely afterwards:

```bash
virsh --connect qemu:///session destroy cachyos-test
virsh --connect qemu:///session undefine cachyos-test --nvram --remove-all-storage
```

**GATE 1** — `bootstrap.sh` completes in the VM, and `doctor.sh` fails only on things a VM
genuinely cannot satisfy.

---

## Stage 2 — Resolve every repository with no remote

**This is the irreversibility gate.** A git repo is only safe if it is *pushed*.

Four repos under `$HOME` had **no remote at all** when this was planned:

| dirty | unpushed | path |
|---|---|---|
| 6 | 3 | `~/Documents/Code/VSCode/dotfiles` — Stage 0 handles this one |
| 35 | 1 | `~/Backup/machine-backup-20260822/portfolio-dotg-2` |
| 20 | 1 | `~/Backup/machine-backup-20260822/try-coding-fonts` |
| 0 | 1 | `~/.codex/.tmp/plugins` — almost certainly disposable; confirm, then ignore |

And five with remotes but uncommitted work: `BSS Blogs` (**94 dirty**), `structflow` (19),
`Python Certification - freeCodeCamp` (19), `sharifdotg-v2` (12), `~/fastfetch` (1). Each
needs a push, or a written decision to discard it.

Per repo, four checks — and note that "did I commit" is only the first:

```bash
git status --porcelain                            # uncommitted
git log --branches --not --remotes                # committed but unpushed
git stash list                                    # stashes are neither
git ls-files --others --ignored --exclude-standard -- . ':!node_modules'
```

> **NB — the fourth is the one that bites, and no git command warns you about it.** Files
> that are gitignored *by design* — `.env`, `appsettings.Development.json`, local dev
> certs, `*.pfx`, `docker-compose.override.yml`, `secrets.json` — are exactly the files a
> clean `git clone` will never bring back, and exactly the files you need on day one of the
> new machine. `git status` is clean and they are still unique. Sweep for them explicitly
> and put them in one small, clearly-labelled archive. Per byte, it is the most valuable
> thing on the disk.

> **NB — do not prune `~/Backup` yet.** It is 3.1 GB of stale Aug 22/26 snapshots plus a
> 1.5 GB `olasportswear_live_20260720.bak` SQL dump, and it mostly duplicates the live
> tree — but it holds the **only** copies of two of the no-remote repos above. Resolve
> those first; then the rest of it is prunable and the payload drops from ~18 GB to ~15 GB.

Also capture, onto the external drive (small, one-time, useful later):

```bash
lsblk -f; findmnt; sudo btrfs subvolume list /; bootctl status; efibootmgr -v
swapon --show; zramctl; free -h
dnf repoquery --userinstalled            # reconcile against packages/*.tsv later
docker images --format '{{.Repository}}:{{.Tag}}'; docker volume ls; docker ps -a
npm ls -g --depth=0; dotnet --list-sdks; code-insiders --list-extensions
systemctl list-unit-files --state=enabled; systemctl --user list-unit-files --state=enabled
sudo tar czf etc-backup.tgz /etc         # cheap insurance for diffing configs after
```

**Photograph on your phone:** the BIOS screens you change, `lsblk -f`,
`findmnt -no OPTIONS /`, `free -h`, `zramctl`. The laptop will not be available to consult.

**GATE 2** — for every repo: zero unresolved no-remote, zero unresolved unpushed, zero
unresolved dirty trees; and the gitignored-secrets sweep is done and its output is a
directory you can list.

---

## Stage 3 — Back up to the external drive

**Sizing, measured:**

| | |
|---|---|
| `$HOME` total | 26.3 GB |
| − `.cache` 3.1 · `.vscode-insiders` 2.9 · `.npm` 1.5 · `.npm-global` 1.0 · `.nuget` 0.65 · `.codex/.tmp` 0.11 | **−9.3 GB** |
| remaining `$HOME` | ~16.6 GB |
| + Docker named volumes | +433 MB |
| **payload** | **~18 GB** (~15 GB once `~/Backup` is pruned after Gate 2) |

**A 32 GB drive is enough.** No external drive was attached when this was written.

### Do not back up — all regenerable

| Path | Size | Why not |
|---|---|---|
| `~/.cache` | 3.1 GB | Regenerable by definition |
| `~/.vscode-insiders` | 2.9 GB | Extension **binaries**. See the NB below |
| `~/.npm` / `~/.npm-global` | 2.5 GB | Capture `npm ls -g --depth=0` (a list, ~1 KB) and reinstall |
| `~/.nuget` | 649 MB | Restored by `dotnet restore` |
| Docker build cache | **7.49 GB** | 100% reclaimable. Never |
| Docker images | 9.08 GB / 64 images | Re-pull. See the NB below |
| `node_modules`, `bin/`, `obj/`, `.nx/`, `dist/` | — | `npm ci` / `dotnet restore` after |
| the two loose `.mp4` screen recordings in `$HOME` | 275 MB | Decide explicitly; easiest 275 MB you will ever drop |

> **NB — never restore a native-module tree across a distro change.** `~/.npm-global`,
> `~/.nuget` and the VS Code extension directory all contain binaries compiled against a
> specific glibc and Node ABI (ripgrep, esbuild, sqlite bindings, `node-gyp` output).
> Restoring them gives you packages that load and then segfault or misbehave in ways that
> look like application bugs. Reinstall from the captured lists instead.

> **NB — split the Docker images into two sets, because the answer differs.** Anything with
> a registry origin: capture the tag list and re-pull. Anything **locally built with no
> registry** (`structflow-*`, `vera_api-*`, `config-mapper-*`, the local `dotnet` image, or
> anything tagged `<none>` you still need) has no re-pull path and needs `docker save`.
> Getting this backwards is how people either waste 9 GB or lose an image.

### Must not be lost

- The gitignored-secrets archive from Stage 2.
- **The credential files this repo deliberately excludes** — `~/.npmrc`,
  `~/.nuget/NuGet.Config`, `~/.docker/config.json`, `~/.config/gh/hosts.yml`. They are in
  both `.gitignore` and `.chezmoiignore` on purpose (see `scripts/secrets-setup.sh`), which
  creates the trap: **the dotfiles repo restores everything except the few things you
  cannot regenerate.**
- **kwallet contents.** Export before the wipe. This item used to say "KDE is going and
  kwallet goes with it, `gnome-keyring` is the successor" — that was written while the target
  was a bare compositor, and it is **wrong now**: the target is CachyOS **KDE Plasma**, so
  kwallet comes with it and stays the Secret Service provider (on Plasma 6 the daemon
  answering `org.freedesktop.secrets` is `ksecretd`). It still starts EMPTY on a fresh
  install, which is the actual reason to export: nothing carries a wallet across a wipe.
  `scripts/git-credentials.sh` puts your git PATs in there, so an unexported wallet means
  re-issuing tokens, not losing the mechanism.
- **The Brave profile, tarred whole** — `~/.config/BraveSoftware/Brave-Origin/` (212 MB).
  Note `Brave-Origin`, **not** `Brave-Browser`; that is regular Brave's path and every guide
  online uses it. Skip `~/.cache/BraveSoftware`.
  > **NB — passwords and cookies are encrypted against the system keyring, not the profile.**
  > Bookmarks, history, extensions and settings restore fine; saved logins and sessions may
  > not, depending on whether the new install wires up a keyring where the old one didn't.
  > Turn on **Brave Sync** (`brave://settings/braveSync`) before the wipe — it is chain-based
  > with a 24-word code and no account. Write the code somewhere that is not this laptop.
  > Restore into the **same or a newer** Brave version; older builds can corrupt the profile.
- `~/Documents` (3.8 GB); `~/.config` and `~/.local` **backed up wholesale, restored
  selectively**; `~/.claude` (241 MB — real config, not just cache).
- `~/.ssh/config` and `known_hosts` if they exist. **There is no keypair and there are zero
  GPG secret keys** — measured — so there is no key material to migrate at all.

### Method

```bash
rsync -aHAX --info=progress2 --exclude-from=exclusions.txt ~/ /run/media/<you>/BACKUP/home/
```

> **NB — into a plain directory, not a tarball.** An 18 GB tar must be extracted wholesale,
> which defeats every "do not restore this" decision above.

> **NB — format the external ext4 or btrfs.** On exFAT or NTFS, rsync silently drops POSIX
> permissions, xattrs and symlinks: `~/.ssh` comes back world-readable (ssh then refuses to
> use it) and git symlinks come back as regular files. Check with
> `findmnt -no FSTYPE <mountpoint>` before the first byte is copied.

Docker volumes — all 8, they are only 433 MB:

```bash
for v in $(docker volume ls -q); do
  docker run --rm -v "$v":/data -v "$PWD":/backup alpine \
    tar czf "/backup/$v.tar.gz" -C /data .
done
```

> **NB — stop the containers first**, especially Postgres and MinIO. A tar of a live
> database's data directory is a torn snapshot: it will restore cleanly, pass a smoke test,
> and corrupt at the first checkpoint. For Postgres, take a `pg_dumpall` **in addition to**
> the volume tar.

**Two copies of the small irreplaceable set.** The gitignored secrets, the credential files
and the kwallet export total a few hundred MB. Put them somewhere *other* than the external
drive as well — that drive is a single point of failure at precisely the moment it is your
only copy.

**GATE 3 — the step that always gets skipped. Do all seven.**

1. **`findmnt <backup-path>` shows the external device.**
   > **NB — this is the loudest warning in this document.** If the external was not mounted
   > when rsync ran, you wrote 18 GB into an empty mountpoint **on the NVMe you are about to
   > erase**. Every other check below will pass, because the files really are there. Verify
   > the *device*, not the path.
2. A second `rsync --dry-run` over the same paths transfers nothing.
3. **Actually restore something.** Extract one Docker volume tarball and one repo into a
   scratch directory and open a file. *A backup you have never restored from is a
   hypothesis.*
4. All Stage 2 gates still green.
5. The credential archive and the gitignored-secrets directory are on the external — list
   them by name.
6. CachyOS ISO written and checksum-verified, on a **second** USB stick. The live ISO is
   your recovery path; do not put it on the drive holding the backup.
7. **`umount` the external and physically unplug it.**
   > **NB** — Calamares' automatic partitioning is perfectly capable of selecting the wrong
   > disk, and the confirmation screen is easy to click through at 11pm. Physical
   > disconnection is the only mitigation that cannot be defeated by a tired human.

---

## Stage 4 — BIOS, then install

**BIOS** (F1 at the ThinkPad logo):

- Security → Secure Boot → **Disabled**. `linux-cachyos` is not signed by a key in the
  default UEFI db, and per-update re-signing with `sbctl` is not worth it for this threat
  model. If the installed system later refuses to boot, look for **Reset to Setup Mode /
  Clear Keys**.
  > **NB** — Secure Boot must be off *before* you boot the installer, not after. The
  > CachyOS ISO will boot happily with it on, and you would discover the problem at first
  > reboot into an unbootable system.
  > **NB** — the old guide said to keep Secure Boot on "for fwupd". That was wrong on
  > Fedora too: **fwupd does not require Secure Boot.** LVFS updates work with it off.
- Config → Power → Sleep State → **Linux** (S3). Worth ~2% overnight drain instead of ~15%.
- Config → Thunderbolt → BIOS Assist Mode → **Disabled**.
- Security → Memory Protection → Execution Prevention → **Enabled**.
- **F12** to boot the USB.

**Installer decisions that matter.** Each is one-shot:

1. **Repos: `cachyos-v3`. Never v4.** Verify the CPU first:
   ```bash
   /lib64/ld-linux-x86-64.so.2 --help | grep x86-64-v
   #   x86-64-v4                      <- listed but NOT marked: unsupported
   #   x86-64-v3 (supported, searched)
   #   x86-64-v2 (supported, searched)
   ```
   The absence of `(supported, searched)` next to v4 *is* the test — Whiskey Lake has no
   AVX-512.
   > **NB** — a v4 package on this CPU installs perfectly cleanly and then dies with
   > `Illegal instruction (core dumped)` at runtime, from arbitrary binaries. It reads
   > exactly like failing RAM. People memtest for a day over this.
2. **Erase the whole `nvme0n1`** (238.5 GB). No dual boot, no preserved partitions.
3. **Partition layout — simplify deliberately.** Current: 600M ESP + 2G ext4 `/boot` +
   235.9G btrfs. New: **1 GB ESP + a single btrfs root.** The separate `/boot` existed to
   support LUKS and there is no encryption here; and 600 MB is too small once a boot manager
   keeps kernels on the ESP — two kernels plus a fallback initramfs will fill it, and a full
   ESP surfaces months later as a failed kernel update.
4. **btrfs, subvolumes `@` → `/` and `@home` → `/home`, `compress=zstd:1`.**
   > **NB** — if the installer defaults to a higher zstd level, set it back. `zstd:1` is a
   > deliberate choice for a dev box: the win is reduced I/O, and levels above 1 spend CPU
   > you do not have on 4 cores for a marginal ratio. It is what the old machine ran.
5. **No swap partition. zram only.**
   > **NB — this is the most dangerous interaction in the whole repo.** The installer will
   > offer swap and it is the wrong answer. `vm.swappiness = 180` in
   > `system/sysctl.d/99-memory-tuning.conf` is correct *only* because swap is zram. Pointed
   > at an NVMe partition, that same value reproduces precisely the low-memory livelock the
   > guide's Phase 4 exists to prevent — `system/apply.sh` would make the machine **worse**
   > than stock. If `swapon --show` ever lists a disk partition, remove it before running
   > `system/apply.sh`.
6. **Bootloader: Limine + `limine-snapper-sync`.** `snapper` is the one check
   `scripts/doctor.sh` has always failed, and a fresh install is when the rollback net is
   free. Limine gives bootable snapshot entries with no bolt-on where GRUB needs
   `grub-btrfs`; Secure Boot being off removes the one argument that favoured GRUB.
   > **NB — the honest trade-off:** Limine is less battle-tested than GRUB and has a smaller
   > body of recovery documentation. Mitigate by installing **`linux-lts` alongside
   > `linux-cachyos`**. A fresh install with exactly one kernel and no fallback entry is how
   > you end up back on the live USB.
7. **Kernel: `linux-cachyos`** (BORE), plus `linux-lts` as the recovery fallback. Set
   expectations: on a 4C/8T Whiskey Lake laptop the scheduler difference is real but modest.
   Phase 4's memory work matters far more; do not let the kernel become the story.
8. **Desktop: the KDE Plasma edition.** It brings the workspace, display manager, Breeze,
   the portal and the core KDE apps. `packages/desktop.tsv` adds only what the edition does
   not ship — Brave Origin, Ghostty, the fonts, and the handful of apps you actually use.
   > **NB — do not pick "minimal / no desktop" here.** That was the right answer while this
   > repo targeted a bare compositor; it is the wrong answer now, and it leaves you at a TTY
   > assembling a session by hand for no benefit.
9. **Keep the username identical**, or every absolute path in every backup needs rewriting.

---

## Stage 5 — Restore, in this order

The ordering *is* the content.

1. **Verify the install** against the guide's Phase 1 table. Cheap now, expensive later.
2. **Firmware (`fwupdmgr refresh --force && fwupdmgr update`) — before any data is on the
   machine.** Firmware carries the highest bricking risk of anything in this runbook; run it
   while the worst case is "reinstall an empty OS".
3. `sudo pacman -Syu`, reboot.
4. **Phase 4 memory tuning — before restoring anything and before opening a browser.** The
   first thing that will stress this machine is the restore itself: an 18 GB rsync and a
   multi-gigabyte image re-pull. Do not do that on an untuned 16 GB box.
5. **Snapper config + a `clean install, tuned, no data` snapshot.** This is the rollback
   point that has never existed on this machine. Everything after it is recoverable.
6. `git clone` the dotfiles repo → `./bootstrap.sh` → `sudo ./system/apply.sh`.
   **Answer `plasma` to the chezmoi desktop prompt** — it is the default, but
   `promptStringOnce` caches whatever you give it and never asks again.
7. **Restore the credential files by hand** — `~/.npmrc`, `~/.nuget/NuGet.Config`,
   `~/.docker/config.json`, `~/.config/gh/`. The repo will not do this for you, by design.
   Then `./scripts/secrets-setup.sh` for a fresh SSH key and `gh auth login`, and add the new
   public key at github.com/settings/keys. There is no old key to revoke.
   Then `./scripts/git-credentials.sh` for the HTTPS side — a PAT for github.com and one for
   the private forge, stored in kwallet. Issue **new** tokens rather than carrying the old
   ones; the wallet does not survive the wipe either way.
8. **Re-clone every repo fresh from its remote.** Do not restore working trees: it proves
   the Stage 2 pushes were real, it avoids carrying `node_modules`/`obj`/`bin` across a
   glibc change, and it leaves you with clean trees. **Then** drop the gitignored
   `.env`-class files back in from the Stage 2 archive — that is the one thing a clone
   cannot give you.
9. **Data, selectively**: `~/Documents`, chosen `~/.config` and `~/.local` subtrees, the
   Brave profile, `~/.claude`. The exclusion list from Stage 3 is a *restore* policy, not
   just a backup policy.
10. **Docker last.** Install, `systemctl enable --now docker.socket` (socket activation means
    dockerd is not resident until something talks to it — worth ~0.3 GB on a 16 GB box),
    apply `daemon.json`, restore the 8 volume tarballs, re-pull from the image list, and
    `docker load` **only** the local-only images. Do not restore build cache. Bring the stack
    up one service at a time.
11. **Check where the browser actually lives in the cgroup tree.**
    ```bash
    for p in $(pgrep -f /opt/brave.com/brave-origin); do cut -d: -f3 /proc/$p/cgroup; done | sort | uniq -c
    ```
    Expect **two** cgroups, and expect most of Brave to be in the one KDE creates:
    ```
    app-brave\x2dorigin@<hex>.service       ~35 procs   the bulk of it
    app-org.chromium.Chromium-<PID>.scope     ~2 procs   Chromium's own
    ```
    **Do not trust the older note that said the opposite.** It claimed Chromium "migrates out
    of the unit KDE creates", 33 of 35 processes into its own scope. Re-measured 2026-09-04,
    that is backwards: GPU process, all three zygotes, the utility processes, crashpad and
    every renderer stay in the `.service`. Capping only the scope covered 5% of the processes
    and 19% of the memory while `doctor.sh` reported it green.
    Both are capped now — `browser.slice` plus a drop-in each
    (`app-brave\x2dorigin@.service.d/` for the service, which is a template instance, and
    `app-org.chromium.Chromium-.scope.d/` for the scope, via dash-truncation). See Phase 5.
    `doctor.sh` now checks **every** cgroup Brave's processes are in rather than filtering to
    scopes, so a split that changes again shows up as a failure rather than as silence.

    Expect `cgroups in the slice` to read `0/N` until the first Brave restart on the new
    machine — a live cgroup cannot be re-parented, and that is not a fault.
12. `./scripts/doctor.sh`, and fix what it reports.
13. **Re-measure and update the guide's baseline table.** Plasma session idle (was 0.58 GiB
    on Fedora — expect it to be close), Brave working set, and the zram ratio. This closes the loop the guide promises, and it is the only way the
    numbers in it stay true.

**Final rule, on its own line: do not reformat the external drive for 30 days.** You will
find the missing `.env` on day 9.

---

## What actually happened

*(Fill this in after the move: what broke, what the numbers came out as, which decisions
were wrong. This section is the reason to keep this file rather than delete it.)*

- **Date:**
- **Time taken:**
- **What broke:**
- **Decisions that turned out wrong:**
- **Measured after:** Plasma session idle · Brave working set · zram ratio · boot time
