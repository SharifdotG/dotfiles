#!/usr/bin/env bash
# Install the load-bearing /etc drop-ins. Idempotent; shows a diff before writing.
# Run with: sudo ./system/apply.sh   [--dry-run]
set -euo pipefail
cd "$(dirname "$0")"
. ../lib/log.sh
. ../lib/detect.sh
detect_all

# NB: no UI_STEPS here. This script's two `step` calls are inside
# install_file(), once per file in --dry-run, not top-level phases - numbering
# them would count files and print [3/2].
banner "system" "/etc drop-ins · idempotent · shows a diff before writing"

DRY=0; [ "${1:-}" = --dry-run ] && DRY=1
[ "$(id -u)" -eq 0 ] || die "run me with sudo"
# NB: DESKTOP is unreliable in here - sudo strips XDG_CURRENT_DESKTOP, so
# detect.sh falls back to pgrep. Do not branch on $DESKTOP in this file.
#
# NB: PROFILE, CPU_VENDOR and GPU are safe to branch on and this file does.
# They are the reason lib/detect.sh reads sysfs and /etc rather than anything
# under $HOME: sudo sets HOME=/root, so ~/.config/chezmoi - where chezmoi keeps
# the same answers - is unreachable from here. Overriding for a dry run needs
# the assignment in front of sudo's command, because env_reset drops it:
#     sudo DOTFILES_PROFILE=desktop ./system/apply.sh --dry-run
info "profile=$PROFILE / cpu=$CPU_VENDOR / gpu=$GPU"
[ "$PKG_COL" = arch ] ||
  die "this repo targets CachyOS (or Arch); detected '$DISTRO' -> column '$PKG_COL'"

# Set by install_file whenever it writes. Read by the initramfs step below,
# because `mkinitcpio -P` is 30+ seconds and running it on every apply would
# make the idempotent re-run - the normal update path - feel broken.
CHANGED=0

install_file() {
  local src="$1" dst="$2" mode="${3:-0644}"
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    ok "unchanged  $dst"; return
  fi
  if [ -f "$dst" ]; then
    step "would change $dst"; diff -u "$dst" "$src" || true
  else
    step "would create $dst"
  fi
  if [ "$DRY" -eq 1 ]; then return; fi
  install -D -m "$mode" "$src" "$dst"
  CHANGED=1
  ok "wrote      $dst"
}

# NB: `return 0` unconditionally. This script runs under `set -e` - unlike every
# other script in this repo - so a `cmd && ok || warn` chain whose final branch
# is false aborts the run. Containing the pattern inside a function that always
# succeeds is what keeps that from happening.
enable_unit() {
  if systemctl is-enabled --quiet "$1" 2>/dev/null; then
    ok "already enabled $1"
  else
    systemctl enable --now "$1" >/dev/null 2>&1 && ok "enabled $1" || warn "could not enable $1"
  fi
  return 0
}

info "Memory / anti-freeze tuning"
install_file sysctl.d/99-memory-tuning.conf               /etc/sysctl.d/99-memory-tuning.conf
install_file systemd/zram-generator.conf                  /etc/systemd/zram-generator.conf
install_file systemd/oomd.conf.d/99-aggressive.conf       /etc/systemd/oomd.conf.d/99-aggressive.conf
install_file systemd/system/user@.service.d/99-oomd.conf  /etc/systemd/system/user@.service.d/99-oomd.conf
install_file systemd/user/slice.d/99-oomd-user-slice.conf /etc/systemd/user/slice.d/99-oomd-user-slice.conf
install_file systemd/system/earlyoom.service.d/99-args.conf \
             /etc/systemd/system/earlyoom.service.d/99-args.conf
# NB: a UDEV rule, not a sysctl one, and it is not redundant with the sysctl.d
# file above. CachyOS's /usr/lib/udev/rules.d/30-zram.rules resets
# vm.swappiness to 150 on every zram0 `change` event - which happens at boot
# AFTER `sysctl --system`, and again a few lines below when this script
# restarts systemd-zram-setup@zram0. The full derivation is in the file.
install_file udev/rules.d/99-zram-swappiness.rules \
             /etc/udev/rules.d/99-zram-swappiness.rules

info "Journal + coredump size caps"
install_file journald.conf.d/99-size-cap.conf             /etc/systemd/journald.conf.d/99-size-cap.conf
install_file systemd/coredump.conf.d/99-size-cap.conf     /etc/systemd/coredump.conf.d/99-size-cap.conf

info "Docker daemon (log caps + builder GC)"
install_file docker/daemon.json                           /etc/docker/daemon.json

# ── hardware-specific ────────────────────────────────────────────────────────
# NB: keyed on the hardware axes, not on PROFILE alone. ppfeaturemask is an
# amdgpu fact - it would be inert on an Intel GPU and actively confusing to
# find in /etc. The sensor module is a desktop-board fact.
INITRAMFS_STALE=0
if [ "$GPU" = amd ]; then
  info "AMD GPU (unlock power management for LACT)"
  CHANGED=0
  install_file modprobe.d/99-amdgpu-ppfeaturemask.conf \
               /etc/modprobe.d/99-amdgpu-ppfeaturemask.conf
  # `if`, not `[ ... ] && ...`. Same reason as the note further down: this
  # script runs under `set -e` and a bare test-and-command is exactly the shape
  # that has bitten it before.
  if [ "$CHANGED" -eq 1 ]; then INITRAMFS_STALE=1; fi
fi
# NB: gated on PROFILE **and** on the module actually existing, because this is
# the one fact in this repo that is neither a CPU fact nor a chassis fact - it is
# a MOTHERBOARD fact (the Nuvoton Super-I/O on MSI B450/B550), and it is being
# carried on two unrelated axes: packages/cpu-amd.tsv ships the driver by
# CPU_VENDOR, this drop-in is installed by PROFILE. That lands correctly on the
# machines this repo has, and wrongly on both combinations it does not:
#
#   Intel desktop -> PROFILE=desktop installs a drop-in naming a module that
#                    cpu-intel.tsv never installed, and systemd-modules-load.service
#                    then FAILS on every single boot.
#   AMD laptop    -> cpu-amd.tsv builds a DKMS driver for a chip that is not there.
#
# The PROFILE test closes the second. `modinfo` closes the first, and is the
# honest question anyway: "is this module installed", not "does this machine look
# like the one I was written for". Loading it on a board without the chip is
# harmless (it inserts and reports nothing - see the note in scripts/doctor.sh);
# naming a module that does not exist is not.
#
# NB: modinfo only searches the RUNNING kernel's tree. Straight after a kernel
# update the DKMS module exists for the new kernel and not the booted one, so ask
# the module tree directly before concluding it is absent - otherwise this
# silently stops installing the drop-in on exactly the reboot where you are
# already suspicious of the sensors.
have_nct6687() {
  modinfo nct6687 >/dev/null 2>&1 && return 0
  [ -n "$(find /lib/modules -name 'nct6687.ko*' -print -quit 2>/dev/null)" ]
}
if [ "$PROFILE" = desktop ]; then
  if have_nct6687; then
    info "Board sensors (Nuvoton, MSI B450/B550)"
    install_file modules-load.d/99-nct6687.conf \
                 /etc/modules-load.d/99-nct6687.conf
  else
    info "skipping nct6687 drop-in - module not installed (cpu=$CPU_VENDOR).
       A modules-load.d entry for a module that does not exist fails
       systemd-modules-load.service at every boot."
  fi
fi

[ "$DRY" -eq 1 ] && { info "dry run - nothing written"; exit 0; }

info "Reloading"
sysctl --system >/dev/null && ok "sysctl reloaded"
# NB: udevadm control --reload only makes udev re-read the RULES. It does not
# re-evaluate them against existing devices - that is what the zram trigger
# further down does, via the restart.
udevadm control --reload >/dev/null 2>&1 && ok "udev rules reloaded" ||
  warn "udevadm control --reload failed"
systemctl daemon-reload            && ok "systemd reloaded"
systemctl restart systemd-journald && ok "journald restarted"

# NB: nothing above loads the sensor module. /etc/modules-load.d is read ONCE,
# by systemd-modules-load.service at boot, and no reload re-reads it - so
# installing the drop-in a few lines up left nct6687 absent until the next
# reboot, and doctor.sh reported a red "nct6687 module loaded: no" on a machine
# that was correctly configured and just had not been restarted.
#
# Worth contrasting with ppfeaturemask, which genuinely cannot be fixed here:
# that is a module PARAMETER for a driver that is already loaded and driving the
# display, so it waits for the initramfs and a reboot. This one is only an
# INSERTION, and an insertion can happen now.
#
# NB: guarded on the drop-in existing rather than on $PROFILE, so it stays true
# to what was actually installed above - including the case where the module was
# not built and the drop-in was deliberately skipped.
if [ -f /etc/modules-load.d/99-nct6687.conf ] && ! lsmod | grep -q '^nct6687'; then
  modprobe nct6687 2>/dev/null && ok "nct6687 loaded" ||
    warn "modprobe nct6687 failed - check 'dkms status' (it may not be built for $(uname -r))"
fi

# NB: only when a modprobe.d file actually changed. mkinitcpio -P is ~30s and
# this script's whole contract is that re-running it is cheap and boring.
if [ "$INITRAMFS_STALE" -eq 1 ]; then
  info "Regenerating the initramfs"
  # WHY: modprobe options only reach a module that loads from the initramfs if
  # the file is IN the initramfs. amdgpu loads there (the kms hook), and
  # mkinitcpio's modconf hook copies /etc/modprobe.d/*.conf in - so the option
  # is inert until this runs.
  mkinitcpio -P >/dev/null 2>&1 && ok "initramfs regenerated" ||
    warn "mkinitcpio -P failed - amdgpu will not pick up ppfeaturemask"
fi

info "Enabling units Arch ships disabled"
# NB: Arch's default preset is `disable *` (/usr/lib/systemd/system-preset/).
# Fedora's presets were enabling all of these for free, so the drop-ins above
# were only ever corrective there. Here they are additive and inert until the
# units are actually switched on.
for u in systemd-oomd.service earlyoom.service fstrim.timer \
         smartd.service irqbalance.service; do
  enable_unit "$u"
done
command -v paccache >/dev/null && enable_unit paccache.timer

# NB: thermald used to be in the list above, unconditionally. It is Intel-only
# and refuses to start on AMD, so on the desktop every single run of this
# script printed "could not enable thermald.service" and nothing in doctor.sh
# ever looked - a warning that appears on every run is a warning nobody reads.
# Gate it on the CPU instead, and say out loud when it is skipped.
if [ "$CPU_VENDOR" = intel ]; then
  enable_unit thermald.service
else
  info "skipping thermald.service - Intel only, this CPU is $CPU_VENDOR"
fi

# LACT's daemon is what applies a saved fan curve at boot; without it the GUI
# works and nothing persists across a reboot.
if [ "$GPU" = amd ] && systemctl list-unit-files lactd.service >/dev/null 2>&1; then
  enable_unit lactd.service
fi


info "zram"
# NB: the zram device comes from a GENERATOR, so daemon-reload re-reads
# zram-generator.conf but cannot resize a device that is already swapped on -
# restart then fails with "Device or resource busy". CachyOS starts zram at boot
# from its own vendor config, so hitting that is the NORMAL path here, not an
# edge case.
if swapon --show=NAME --noheadings 2>/dev/null | grep -q zram; then
  swapoff /dev/zram0 2>/dev/null || true
fi
systemctl restart systemd-zram-setup@zram0.service 2>/dev/null &&
  ok "zram reconfigured" || warn "zram restart failed - check 'zramctl'"
# The restart above fires the zram0 `change` event that both 30-zram.rules and
# our 99- rule react to, so swappiness is settled by the post-check below. If
# zram did NOT restart, nothing re-evaluated the rules against the live device -
# force it, or the post-check reports 150 on a machine that is actually fine
# after a reboot.
udevadm trigger --action=change /sys/block/zram0 >/dev/null 2>&1 || true
udevadm settle --timeout=5 >/dev/null 2>&1 || true

if systemctl is-active --quiet docker; then
  systemctl restart docker; ok "docker restarted"
else
  info "docker not running - nothing to restart"
fi

info "Vendor defaults being shadowed"
# CachyOS ships its own tuning. Ours wins, but say so out loud rather than
# letting someone discover it from a value that does not match the file.
for v in /usr/lib/systemd/zram-generator.conf /usr/lib/sysctl.d/*cachyos*.conf; do
  if [ -e "$v" ]; then info "  shadowing $v"; fi
done
# Not shadowed - overridden after the fact, which is a different relationship
# and worth naming differently. 30-zram.rules still runs; our 99- rule just has
# the last word on vm.swappiness.
# NB: `if`, not `[ ... ] && info`. Under `set -e` a bare test-and-command whose
# test is FALSE is a failing command at the top level and aborts the whole
# script - the same trap enable_unit() exists to contain.
if [ -e /usr/lib/udev/rules.d/30-zram.rules ]; then
  info "  overriding vm.swappiness from /usr/lib/udev/rules.d/30-zram.rules"
fi

info "Post-checks"
# NB: read the KERNEL back, not the file we just wrote. sysctl.d files from
# /etc, /run and /usr/lib are merged in FILENAME order across all three
# directories - only an identical basename in /etc masks a /usr/lib file. Ours
# sorts after CachyOS's by luck of the alphabet, not by design, so verify.
# NB: and read it back AFTER the udev trigger above, not before. This check was
# already here and was already correct to distrust the file - what it could not
# say was WHERE a wrong value comes from, so it sent you to cat-config for a
# clobber that sysctl.d has nothing to do with. 150 means udev won.
sw=$(sysctl -n vm.swappiness 2>/dev/null || echo '?')
[ "$sw" = 180 ] && ok "vm.swappiness = 180" ||
  warn "vm.swappiness is $sw, expected 180 - if it is 150 the zram udev rule won:
       check /etc/udev/rules.d/99-zram-swappiness.rules is installed, then
       'udevadm trigger --action=change /sys/block/zram0'.
       Otherwise: 'systemd-analyze cat-config sysctl.d'"

# NB: read the MODULE PARAMETER back, not the file just written - same rule as
# the swappiness check above, and for a nastier reason. A wrong ppfeaturemask
# does not error: the sysfs nodes LACT needs are simply absent, so LACT opens,
# shows correct-looking numbers, and silently cannot change any of them.
if [ "$GPU" = amd ]; then
  ppf=$(cat /sys/module/amdgpu/parameters/ppfeaturemask 2>/dev/null || echo '')
  if [ -z "$ppf" ]; then
    warn "amdgpu module parameter not readable - is the amdgpu driver loaded?"
  elif [ "$(printf '%d' "$ppf" 2>/dev/null || echo 0)" -eq 4294967295 ]; then
    ok "amdgpu ppfeaturemask = $ppf (power management unlocked)"
  else
    # Expected on the run that FIRST installs the file: the running kernel
    # still has the old value and only a reboot picks up the new initramfs.
    info "amdgpu ppfeaturemask is $ppf, want 0xffffffff - REBOOT to apply.
       If it is still wrong after a reboot, /etc/modprobe.d never reached the
       initramfs: check that HOOKS in /etc/mkinitcpio.conf contains 'modconf',
       or set amdgpu.ppfeaturemask=0xffffffff on the kernel command line."
  fi
fi

steps_end
info "Done. Verify with: scripts/doctor.sh"
