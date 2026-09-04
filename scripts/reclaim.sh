#!/usr/bin/env bash
# Reclaim disk. Reports before acting, and prompts before anything destructive.
# Run as your normal user; it calls sudo for the steps that need it.
#
# This reclaims BOTH, and the distinction matters:
#
#   RAM  - Baloo indexing every node_modules tree, Akonadi's 16 processes and
#          MySQL database for zero mail accounts, PackageKit's resident
#          200-300 MB. These come back with KDE, so they are live targets.
#   DISK - a problem Fedora never had: pacman keeps every version of every
#          package it has ever installed, forever. Routinely 5-20 GB.
#
# Both are reported before and after.
set -uo pipefail
cd "$(dirname "$0")/.."
. lib/log.sh

[ "$(id -u)" -ne 0 ] || die "run me as your normal user, not root (I call sudo myself)"

avail() { df --output=avail -BM / | tail -1 | tr -dc '0-9'; }
resident() { ps -eo rss,comm --no-headers | grep -iE 'akonadi|packagekitd|Discover|baloo' |
             grep -v grep | awk '{s+=$1} END {printf "%.0f", s/1024}'; }
before_disk=$(avail); before_ram=$(resident)
info "Free on /: ${before_disk} MB   |   reclaim targets resident: ${before_ram:-0} MB"

# ── 0. KDE idle services ─────────────────────────────────────────────────────
step "Baloo file indexer"
# Indexes every node_modules tree it can find: sustained CPU, RAM and SSD writes
# for zero benefit when you search with rg/fzf.
if ! command -v balooctl6 >/dev/null; then
  ok "baloo not installed"
else
  _baloo=$(balooctl6 status 2>&1 || true)   # exits 1 when disabled; capture, don't pipe
  case "$_baloo" in
    *"currently disabled"*) ok "baloo already disabled" ;;
    *) balooctl6 disable && balooctl6 purge && ok "baloo disabled + index purged" ;;
  esac
fi

step "KDE PIM / Akonadi"
# Measured on the old machine: 507 MB across 16 processes plus a 125 MB MySQL
# database, for zero configured mail accounts. The single biggest RAM reclaim
# available on a KDE desktop.
#
# NB: check for actual DATA before removing anything. Someone who really does
# read mail here would lose it, and "I don't use kmail" is not the same as
# "kmail has nothing in it".
if ! pacman -Qq kmail >/dev/null 2>&1 && ! pgrep -x akonadi_control >/dev/null; then
  ok "KDE PIM not installed"
elif [ -s "$HOME/.config/akonadi/agentsrc" ] || [ -d "$HOME/.local/share/local-mail" ]; then
  warn "Akonadi has configured accounts or local mail - NOT touching it"
  info "  ~/.config/akonadi/agentsrc and ~/.local/share/local-mail exist"
else
  command -v akonadictl >/dev/null && akonadictl stop 2>/dev/null
  read -r -p "Remove kmail/korganizer/kaddressbook/akonadi? [y/N] " a
  case "${a:-n}" in
    [yY]*) sudo pacman -Rns --noconfirm kmail korganizer kaddressbook akonadi 2>/dev/null &&
             ok "KDE PIM removed" || warn "some PIM packages were not installed" ;;
    *)     ok "left alone" ;;
  esac
fi

step "PackageKit"
# Discover's backend. Wakes periodically and holds 200-300 MB. You update with
# pacman, so it earns nothing here.
# NB: Discover on Arch uses PackageKit only if it is installed; masking it does
# not break flatpak support in Discover.
if ! pacman -Qq packagekit >/dev/null 2>&1; then
  ok "packagekit not installed"
elif [ "$(systemctl is-enabled packagekit 2>/dev/null)" = masked ]; then
  ok "packagekit already masked"
else
  read -r -p "Mask PackageKit? Discover loses native package installs. [y/N] " a
  case "${a:-n}" in
    [yY]*) sudo systemctl mask --now packagekit && ok "packagekit masked" ;;
    *)     ok "left alone" ;;
  esac
fi

# ── 0b. preinstalled KDE apps you have never opened ──────────────────────────
# The KDE edition ships a full application suite. Most of it is small on disk and
# costs nothing at rest - these are not daemons - so the honest reason to remove
# them is menu clutter and update churn, not RAM. Do not expect this to move the
# memory needle; Layer 5's Akonadi/Baloo/PackageKit section is where that is.
#
# NB: this deliberately does NOT hardcode "remove these 40 packages". Two reasons:
#   1. CachyOS's default set is not Fedora's, so a fixed list would try to remove
#      things that were never installed and miss things that were.
#   2. "Nobody uses this" is a claim about YOU, not about the package. So the
#      script checks for a config or state directory first and refuses to offer
#      anything you have actually opened.
#
# NB: NEVER put these in the candidate list. They look like clutter and are
# load-bearing:
#   kde-gtk-config              themes every GTK app from the Plasma colour scheme
#   plasma-browser-integration  media keys, downloads, KRunner tab search
#   xdg-desktop-portal-kde      file pickers and screen sharing for everything
#   kwallet / ksshaskpass       secrets, and the ssh-agent askpass
#   plasma-nm / plasma-pa       network and audio applets
#   powerdevil / kscreen        power management and display configuration
#   plasma-thunderbolt          the T490s has Thunderbolt 3; this authorises devices
#   plasma-disks                the GUI for smartmontools, which is in reliability.tsv
step "preinstalled KDE apps"
_cands="kmahjongg kmines kpat katomic kblocks kbounce kbreakout kdiamond kfourinline
        kgoldrunner kigo killbots kjumpingcube klickety klines knavalbattle knetwalk
        knights kolf kollision konquest kreversi kshisen ksirk ksnakeduel kspaceduel
        ksquares ksudoku ktuberling kubrick lskat palapeli picmi bomber bovo granatier
        elisa dragon juk kamoso kamera kolourpaint kruler kteatime kcharselect
        kfind kmouth kbackup skanpages kwrite kdialog kdebugsettings keditbookmarks
        krdc krfb kdenetwork-filesharing akregator kontact neochat
        khelpcenter kinfocenter plasma-welcome plasma-vault kjournald partitionmanager"

_remove=""; _kept=""
for pkg in $_cands; do
  pacman -Qq "$pkg" >/dev/null 2>&1 || continue           # not installed
  # Has it ever been opened? KDE writes <name>rc on first run; some apps use a
  # directory instead.
  # NB: `[ -e A ] || [ -e B ]`, NOT `ls -d A B`. `ls` exits non-zero when ANY
  # argument is missing, so an app with a config but no share dir would be
  # reported as never-opened - misclassifying a used app as safe to delete.
  # Wrong direction for a destructive action.
  if [ -e "$HOME/.config/${pkg}rc" ] ||
     [ -e "$HOME/.config/$pkg" ] ||
     [ -e "$HOME/.local/share/$pkg" ]; then
    _kept="$_kept $pkg"
  else
    _remove="$_remove $pkg"
  fi
done

if [ -z "$_remove" ]; then
  ok "nothing to remove - none of the candidates are installed"
else
  info "never opened (no config or state):"
  printf '%s ' $_remove | fold -sw 72 -s | sed 's/^/    /'; echo
  info "  $(printf '%s\n' $_remove | wc -l) package(s)"
  if [ -n "$_kept" ]; then
    info "skipping - these have a config, so you have opened them:"
    printf '%s ' $_kept | fold -sw 72 -s | sed 's/^/    /'; echo
  fi
  # NB: show what pacman would actually do before asking. -Rns pulls unused
  # dependencies too, and on a meta-package-based install that can reach further
  # than the list you just read.
  info "dry run:"
  sudo pacman -Rns --print $_remove 2>&1 | tail -n +1 | head -20 | sed 's/^/    /'
  read -r -p "Remove them? [y/N] " a
  case "${a:-n}" in
    [yY]*) sudo pacman -Rns --noconfirm $_remove && ok "removed" || warn "some removals failed" ;;
    *)     ok "left alone" ;;
  esac
  # NB: removing any member of plasma-meta removes plasma-meta itself, because
  # the meta-package depends on it. That is harmless in itself - a meta-package
  # only exists to pull dependencies - but it does mean future `pacman -Syu` will
  # no longer add newly-introduced Plasma components automatically. If you want
  # that behaviour back, reinstall plasma-meta and let it pull what it wants.
  pacman -Qq plasma-meta >/dev/null 2>&1 ||
    info "plasma-meta is no longer installed - see the note in this script"
fi

step "CachyOS defaults this repo does not use"
# A DIFFERENT list from the one above, and deliberately not merged with it.
#
# The KDE apps above are judged by "has it ever been opened?" - a heuristic,
# because they are ordinary applications someone might want. These are not:
# every one is either superseded by something this repo installs on purpose, or
# is configuration for a program that is not installed at all. So they are named
# outright, with the reason, and there is no heuristic to get wrong.
#
# NB: NONE of these come from packages/*.tsv - they arrive on the CachyOS ISO.
# That is why removal lives here and not in a manifest: bootstrap.sh never
# installed them, so bootstrap.sh cannot uninstall them either. The one
# exception is yazi, which WAS in packages/core.tsv and has been removed from
# it - otherwise the next bootstrap would put it straight back.
_cachy_cands="
  alacritty:Ghostty is the terminal (packages/desktop.tsv)
  cachyos-alacritty-config:config for the terminal above; orphaned without it
  cachyos-emerald-kde-theme-git:Catppuccin is the theme
  cachyos-nord-kde-theme-git:Catppuccin is the theme
  cachyos-iridescent-kde:Catppuccin is the theme - and this one is installed BROKEN, at /usr/share/plasma/look-and-feel/look-and-feel/Iridescent-round, one directory too deep for Plasma to ever list it
  cachyos-wallpapers:the wallpaper is Catppuccin Latte, committed in home/private_dot_local/share/wallpapers
  cachyos-fish-config:fish is not installed; this is config for a shell that is not here
  yazi:removed from packages/core.tsv; Dolphin is the file manager
"
_cremove=""
while IFS= read -r line; do
  pkg=${line%%:*}; pkg=$(printf '%s' "$pkg" | tr -d ' ')
  [ -n "$pkg" ] || continue
  pacman -Qq "$pkg" >/dev/null 2>&1 || continue
  _cremove="$_cremove $pkg"
  printf '    %-32s %s\n' "$pkg" "${line#*:}"
done <<EOS
$_cachy_cands
EOS

if [ -z "$_cremove" ]; then
  ok "none of them are installed"
else
  # NB: konsole is NOT on the list, on purpose. It is an optional dependency of
  # both Dolphin and Kate for their embedded terminal panel (F4), so removing it
  # degrades two apps this repo does keep - and `pacman -Rns` will not warn,
  # because an OPTIONAL dependency is not a dependency.
  info "keeping konsole - Dolphin and Kate use it for the F4 terminal panel"
  info "dry run:"
  sudo pacman -Rns --print $_cremove 2>&1 | head -20 | sed 's/^/    /'
  read -r -p "Remove them? [y/N] " a
  case "${a:-n}" in
    [yY]*) sudo pacman -Rns --noconfirm $_cremove && ok "removed" || warn "some removals failed" ;;
    *)     ok "left alone" ;;
  esac
fi

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
# Report and prompt; never remove silently. The big KDE targets are handled in
# section 0 above - these are the leftovers.
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

after_disk=$(avail); after_ram=$(resident)
step "result"
info "Free on /:  ${before_disk} MB -> ${after_disk} MB  (reclaimed $((after_disk - before_disk)) MB)"
info "Resident:   ${before_ram:-0} MB -> ${after_ram:-0} MB  (freed $(( ${before_ram:-0} - ${after_ram:-0} )) MB)"
info "Verify with: scripts/doctor.sh"
steps_end
