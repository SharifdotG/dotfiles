#!/usr/bin/env bash
# Install the load-bearing /etc drop-ins. Idempotent; shows a diff before writing.
# Run with: sudo ./system/apply.sh   [--dry-run]
set -euo pipefail
cd "$(dirname "$0")"
. ../lib/log.sh

DRY=0; [ "${1:-}" = --dry-run ] && DRY=1
[ "$(id -u)" -eq 0 ] || die "run me with sudo"

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

info "Memory / anti-freeze tuning"
install_file sysctl.d/99-memory-tuning.conf              /etc/sysctl.d/99-memory-tuning.conf
install_file systemd/zram-generator.conf                 /etc/systemd/zram-generator.conf
install_file systemd/oomd.conf.d/99-aggressive.conf      /etc/systemd/oomd.conf.d/99-aggressive.conf
install_file systemd/system/user@.service.d/99-oomd.conf /etc/systemd/system/user@.service.d/99-oomd.conf
install_file systemd/user/slice.d/99-oomd-user-slice.conf /etc/systemd/user/slice.d/99-oomd-user-slice.conf
install_file default/earlyoom                            /etc/default/earlyoom

info "Journal size cap"
install_file journald.conf.d/99-size-cap.conf            /etc/systemd/journald.conf.d/99-size-cap.conf

info "Docker daemon (log caps + builder GC)"
install_file docker/daemon.json                          /etc/docker/daemon.json

[ "$DRY" -eq 1 ] && { info "dry run - nothing written"; exit 0; }

info "Reloading"
sysctl --system >/dev/null && ok "sysctl reloaded"
systemctl daemon-reload            && ok "systemd reloaded"
systemctl restart systemd-journald && ok "journald restarted"
systemctl is-active --quiet docker && { systemctl restart docker; ok "docker restarted"; }

info "Done. Verify with: scripts/doctor.sh"
