#!/usr/bin/env bash
# Install the load-bearing /etc drop-ins. Idempotent; shows a diff before writing.
# Run with: sudo ./system/apply.sh   [--dry-run]
set -euo pipefail
cd "$(dirname "$0")"
. ../lib/log.sh
. ../lib/detect.sh
detect_all

DRY=0; [ "${1:-}" = --dry-run ] && DRY=1
[ "$(id -u)" -eq 0 ] || die "run me with sudo"
# NB: DESKTOP is unreliable in here - sudo strips XDG_CURRENT_DESKTOP, so
# detect.sh falls back to pgrep. Do not branch on $DESKTOP in this file.
[ "$PKG_COL" = arch ] ||
  die "this repo targets CachyOS (or Arch); detected '$DISTRO' -> column '$PKG_COL'"

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

info "Journal + coredump size caps"
install_file journald.conf.d/99-size-cap.conf             /etc/systemd/journald.conf.d/99-size-cap.conf
install_file systemd/coredump.conf.d/99-size-cap.conf     /etc/systemd/coredump.conf.d/99-size-cap.conf

info "Docker daemon (log caps + builder GC)"
install_file docker/daemon.json                           /etc/docker/daemon.json


[ "$DRY" -eq 1 ] && { info "dry run - nothing written"; exit 0; }

info "Reloading"
sysctl --system >/dev/null && ok "sysctl reloaded"
systemctl daemon-reload            && ok "systemd reloaded"
systemctl restart systemd-journald && ok "journald restarted"

info "Enabling units Arch ships disabled"
# NB: Arch's default preset is `disable *` (/usr/lib/systemd/system-preset/).
# Fedora's presets were enabling all of these for free, so the drop-ins above
# were only ever corrective there. Here they are additive and inert until the
# units are actually switched on.
for u in systemd-oomd.service earlyoom.service fstrim.timer thermald.service \
         smartd.service irqbalance.service; do
  enable_unit "$u"
done
command -v paccache >/dev/null && enable_unit paccache.timer


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

info "Post-checks"
# NB: read the KERNEL back, not the file we just wrote. sysctl.d files from
# /etc, /run and /usr/lib are merged in FILENAME order across all three
# directories - only an identical basename in /etc masks a /usr/lib file. Ours
# sorts after CachyOS's by luck of the alphabet, not by design, so verify.
sw=$(sysctl -n vm.swappiness 2>/dev/null || echo '?')
[ "$sw" = 180 ] && ok "vm.swappiness = 180" ||
  warn "vm.swappiness is $sw, expected 180 - check 'systemd-analyze cat-config sysctl.d'"

info "Done. Verify with: scripts/doctor.sh"
