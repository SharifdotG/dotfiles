#!/usr/bin/env bash
# One-time reclaim of idle background services. Re-verifies before removing anything.
# Run as your normal user; it calls sudo for the steps that need it.
set -uo pipefail
cd "$(dirname "$0")/.."
. lib/log.sh

[ "$(id -u)" -ne 0 ] || die "run me as your normal user, not root (I call sudo myself)"

before=$(ps -eo rss,comm --no-headers | grep -iE 'akonadi|packagekitd|Discover|baloo' | grep -v grep |
         awk '{s+=$1} END {printf "%.0f", s/1024}')
info "Reclaim targets currently resident: ${before:-0} MB"

# ── 1. Baloo (file indexer) ──────────────────────────────────────────────────
# Indexes every node_modules tree it can find: sustained CPU, RAM and SSD writes
# for zero benefit when you search with rg/fzf.
step "Baloo file indexer"
_baloo=$(balooctl6 status 2>&1 || true)   # exits 1 when disabled; capture, don't pipe
if command -v balooctl6 >/dev/null && [ "${_baloo#*currently disabled}" = "$_baloo" ]; then
  balooctl6 disable && balooctl6 purge && ok "baloo disabled + index purged"
else
  ok "baloo already disabled"
fi

# ── 2. KDE PIM / Akonadi ─────────────────────────────────────────────────────
# Fedora KDE ships kmail/korganizer/kaddressbook by default. If you don't use
# them, Akonadi still runs ~16 processes and a MySQL database for nothing.
step "KDE PIM (Akonadi)"
accounts=$(grep -c '^\[Instance ' "$HOME/.config/akonadi/agentsrc" 2>/dev/null || echo 0)
mails=$(find "$HOME/.local/share/local-mail" -type f 2>/dev/null | wc -l)
info "configured Akonadi agents: $accounts   stored mail files: $mails"

if [ "$accounts" -gt 0 ] || [ "$mails" -gt 0 ]; then
  warn "KDE PIM appears to be IN USE - refusing to remove it."
  warn "Stop here and remove it by hand if you really mean to."
else
  ok "verified unused (no agents, no mail)"
  command -v akonadictl >/dev/null && akonadictl stop >/dev/null 2>&1
  sleep 2
  info "This removes ~95 packages. Take a snapper snapshot first if you have one."
  read -r -p "Remove kmail korganizer kaddressbook akonadi-server? [y/N] " a
  if [ "${a,,}" = y ]; then
    sudo dnf remove -y kmail korganizer kaddressbook akonadi-server &&
      rm -rf "$HOME/.local/share/akonadi" && ok "KDE PIM removed"
  else
    ok "skipped removal - Akonadi is stopped for this session only"
  fi
fi

# ── 3. PackageKit / Discover notifier ────────────────────────────────────────
# Discover's backend. Wakes periodically and holds 200-300 MB. You update with dnf.
# Trade-off: Discover can no longer install RPMs. Flatpaks still work.
step "PackageKit"
if systemctl is-enabled packagekit 2>/dev/null | grep -q masked; then
  ok "already masked"
else
  read -r -p "Mask PackageKit? Discover loses RPM installs; flatpak still works. [y/N] " a
  [ "${a,,}" = y ] && sudo systemctl mask --now packagekit && ok "packagekit masked"
fi

# ── 4. ABRT crash reporting ──────────────────────────────────────────────────
step "ABRT crash reporting"
sudo systemctl disable --now abrtd abrt-journal-core abrt-oops 2>/dev/null && ok "abrt disabled" \
  || ok "abrt already off"

sleep 2
after=$(ps -eo rss,comm --no-headers | grep -iE 'akonadi|packagekitd|Discover|baloo' | grep -v grep |
        awk '{s+=$1} END {printf "%.0f", s/1024}')
info "Reclaim targets now resident: ${after:-0} MB  (was ${before:-0} MB)"
free -h
