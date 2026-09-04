#!/usr/bin/env bash
# CachyOS: repository tier, pacman settings and the AUR helper - everything that
# must be right BEFORE packages install.
#
# Note the inversion vs. the Fedora prep.sh this replaced: that script ADDED
# repositories (RPM Fusion, docker-ce, the VS Code repo). The CachyOS ISO has
# already configured its repos, so this script's job is to VERIFY the installer
# made the right choices and to tune pacman - not to add anything.
set -uo pipefail
cd "$(dirname "$0")/../.."
. lib/log.sh

step "microarchitecture tier"
# NB: this is the check that cannot be skipped. CachyOS ships parallel repos
# built for x86-64-v3 and v4. A v4 package on a v3 CPU installs perfectly
# cleanly and then dies with SIGILL the first time you run it - the failure is
# at RUNTIME, not at install time, and it presents as random binaries crashing,
# which reads exactly like failing RAM. People memtest for a day over this.
#
# ld.so is authoritative because it is what glibc itself consults: it prints
# every tier and marks only the supported ones "(supported, searched)".
# Measured on the T490s (i5-8365U, Whiskey Lake): v2 and v3 are marked, v4 is
# listed but NOT marked, because Whiskey Lake has no AVX-512.
LEVEL=$(/lib64/ld-linux-x86-64.so.2 --help 2>/dev/null |
        awk '/x86-64-v[0-9] \(supported/ {print $1}' | sort -r | head -1)
[ -n "$LEVEL" ] || LEVEL=unknown
info "CPU supports: $LEVEL"

if grep -q '^\[cachyos-v4' /etc/pacman.conf 2>/dev/null && [ "$LEVEL" != x86-64-v4 ]; then
  die "pacman.conf enables a v4 repo but this CPU is $LEVEL - remove it before installing anything"
fi
if [ "$LEVEL" = x86-64-v3 ] && ! grep -q '^\[cachyos-v3\]' /etc/pacman.conf 2>/dev/null; then
  warn "this CPU supports v3 but no [cachyos-v3] repo is enabled"
  warn "you are on the generic x86-64 build; run 'sudo cachyos-rate-mirrors' to switch"
else
  ok "repo tier matches the CPU"
fi

step "pacman settings"
# NB: these belong under [options]. Appending to the end of the file - the way
# the old dnf.conf loop did - would land them inside whichever repo section
# happens to be last, where pacman ignores them silently.
for kv in 'ParallelDownloads = 10' 'Color' 'VerbosePkgLists'; do
  k=${kv%% *}
  if grep -qE "^[[:space:]]*$k" /etc/pacman.conf 2>/dev/null; then
    ok "$k already set"
  else
    sudo sed -i "/^\[options\]/a $kv" /etc/pacman.conf && ok "set $kv"
  fi
done

step "AUR helper"
# Must be here rather than in packages/core.tsv: the AUR step in bootstrap.sh
# runs immediately after the package step, so paru has to exist by the time the
# manifests are read.
if command -v paru >/dev/null; then
  ok "paru present"
elif pacman -Si paru >/dev/null 2>&1; then
  sudo pacman -S --needed --noconfirm paru && ok "paru installed"
else
  # NB: no curl|sh and no git-clone-and-makepkg fallback. If the cachyos repo
  # is missing then the repo configuration is broken, and that is the bug to
  # fix - bootstrapping a helper from source would just hide it.
  die "no paru, and no cachyos repo to install it from; check /etc/pacman.conf"
fi

step "makepkg build directory"
# NB: on a systemd default install /tmp is a tmpfs, so an AUR build happens in
# RAM. On 16 GB, building something large (Electron, a Rust workspace) that way
# is precisely the freeze that docs/SETUP-GUIDE.md Phase 4 exists to prevent.
if grep -qE '^\s*BUILDDIR=' /etc/makepkg.conf 2>/dev/null; then
  ok "BUILDDIR already set"
else
  echo 'BUILDDIR=/var/tmp/makepkg' | sudo tee -a /etc/makepkg.conf >/dev/null &&
    ok "BUILDDIR=/var/tmp/makepkg (keeps AUR builds off the tmpfs)"
fi

steps_end
ok "CachyOS prep complete"
