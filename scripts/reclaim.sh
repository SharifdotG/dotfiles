#!/usr/bin/env bash
# Reclaim disk. Reports before acting, and prompts before anything destructive.
# Run as your normal user; it calls sudo for the steps that need it.
#
# NB: this script changed IDENTITY in the move off Fedora KDE, not just its
# commands. There it reclaimed RAM - Baloo indexing node_modules, Akonadi's 16
# processes and MySQL database for zero mail accounts, PackageKit's resident
# 200-300 MB. None of that exists on CachyOS + niri; it is prevented rather than
# reclaimed (see docs/SETUP-GUIDE.md Phase 4, Layer 5). What Arch has instead is
# a DISK problem Fedora never had: pacman keeps every version of every package
# it has ever installed, forever. So the before/after metric is now free disk,
# not resident memory.
set -uo pipefail
cd "$(dirname "$0")/.."
. lib/log.sh

[ "$(id -u)" -ne 0 ] || die "run me as your normal user, not root (I call sudo myself)"

avail() { df --output=avail -BM / | tail -1 | tr -dc '0-9'; }
before=$(avail)
info "Free on /: ${before} MB"

# ── 1. pacman package cache ──────────────────────────────────────────────────
# The single biggest reclaim on Arch, and the one with no Fedora analogue: dnf
# defaults to keepcache=False, pacman keeps everything. Routinely 5-20 GB.
step "pacman package cache"
if command -v paccache >/dev/null; then
  info "cache size: $(du -sh /var/cache/pacman/pkg 2>/dev/null | cut -f1)"
  read -r -p "Keep the 2 most recent versions and drop the rest? [y/N] " a
  case "${a:-n}" in
    [yY]*) sudo paccache -rk2 && sudo paccache -ruk0 && ok "cache trimmed" ;;
    *)     ok "left alone" ;;
  esac
  # The ongoing cap; system/apply.sh enables the timer.
  systemctl is-enabled --quiet paccache.timer 2>/dev/null &&
    ok "paccache.timer enabled (ongoing cap)" ||
    warn "paccache.timer not enabled - run sudo ./system/apply.sh"
else
  warn "paccache not found - install pacman-contrib"
fi

# ── 2. orphaned packages ─────────────────────────────────────────────────────
# Dependencies whose parent is gone. Nothing removes these automatically.
step "orphaned packages"
if command -v pacman >/dev/null; then
  # NB: `pacman -Rns -` with EMPTY stdin errors "no targets specified" and exits
  # 1. Guard on the count before piping anything into it.
  mapfile -t orphans < <(pacman -Qtdq 2>/dev/null)
  if [ "${#orphans[@]}" -eq 0 ]; then
    ok "no orphans"
  else
    printf '    %s\n' "${orphans[@]}"
    read -r -p "Remove ${#orphans[@]} orphaned package(s)? [y/N] " a
    case "${a:-n}" in
      [yY]*) printf '%s\n' "${orphans[@]}" | sudo pacman -Rns - && ok "orphans removed" ;;
      *)     ok "left alone" ;;
    esac
  fi
fi

# ── 3. old coredumps ─────────────────────────────────────────────────────────
# The Arch analogue of the abrtd disabling this script used to do. Ongoing
# policy is the size cap in system/systemd/coredump.conf.d/; this clears what
# accumulated before it was applied.
step "coredumps"
cd_size=$(sudo du -sh /var/lib/systemd/coredump 2>/dev/null | cut -f1)
if [ -n "$cd_size" ] && [ "$cd_size" != "0" ]; then
  info "/var/lib/systemd/coredump: $cd_size"
  read -r -p "Delete all stored coredumps? [y/N] " a
  case "${a:-n}" in
    [yY]*) sudo rm -rf /var/lib/systemd/coredump/* && ok "coredumps cleared" ;;
    *)     ok "left alone" ;;
  esac
else
  ok "no coredumps stored"
fi

# ── 4. docker layers ─────────────────────────────────────────────────────────
# daemon.json's builder.gc caps the BUILD cache. Dangling images and stopped
# containers are not covered by it.
step "docker"
if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  docker system df 2>/dev/null | sed 's/^/    /'
  read -r -p "Prune dangling images, stopped containers and build cache? [y/N] " a
  case "${a:-n}" in
    # NB: never -a, and never --volumes. `-a` removes every image not backed by
    # a RUNNING container, i.e. most of what you use weekly. `--volumes` deletes
    # named volumes whose container is merely stopped - which on this machine is
    # the Postgres, MinIO and Keycloak data.
    [yY]*) docker system prune -f && docker builder prune -f && ok "docker pruned" ;;
    *)     ok "left alone" ;;
  esac
else
  ok "docker not running - skipped"
fi

# ── 5. idle services still worth stopping ────────────────────────────────────
# Small on CachyOS + niri. Report and prompt; never remove silently.
#
# NB: do NOT touch ananicy-cpp or scx_loader / scx-scheds. CachyOS ships those
# deliberately - they are the auto-nice daemon and the sched_ext scheduler that
# make the machine feel responsive under load. Disabling them is a regression,
# not a reclaim.
step "idle services"
for svc in cups.service cups.socket avahi-daemon.service bluetooth.service; do
  if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
    info "  $svc is enabled (disable it yourself if you never use it)"
  fi
done
ok "reported only - nothing changed"

after=$(avail)
step "result"
info "Free on /: ${before} MB -> ${after} MB  (reclaimed $((after - before)) MB)"
info "Verify with: scripts/doctor.sh"
