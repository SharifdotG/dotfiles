#!/usr/bin/env bash
# Install firefox/user.js into every Firefox profile on this machine.
# Idempotent; shows a diff before writing. Run as your normal user, no sudo.
#
# This is a script rather than a chezmoi-managed file because the profile
# directory carries a random 8-char prefix (y3jl4unn.default-release), so there
# is no fixed path for chezmoi to target.
set -uo pipefail
cd "$(dirname "$0")/.."
. lib/log.sh

[ "$(id -u)" -ne 0 ] || die "run me as your normal user, not root"

SRC=firefox/user.js
[ -f "$SRC" ] || die "missing $SRC"

# Profile roots differ by packaging. Fedora's RPM patched Firefox to honour
# $XDG_CONFIG_HOME, so profiles lived under ~/.config/mozilla there; upstream and
# Arch do NOT, so ~/.mozilla is the real path on CachyOS. Check all three roots
# (plus Flatpak) rather than guessing - this is why the script survived the
# distro change untouched while doctor.sh's hardcoded path did not.
roots=(
  "${XDG_CONFIG_HOME:-$HOME/.config}/mozilla/firefox"
  "$HOME/.mozilla/firefox"
  "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox"
)

found=0
for root in "${roots[@]}"; do
  [ -d "$root" ] || continue
  # A directory is a profile iff it has a prefs.js or times.json - not just any
  # subdirectory, or we would write into Crash Reports/ and Pending Pings/.
  while IFS= read -r prof; do
    [ -f "$prof/prefs.js" ] || [ -f "$prof/times.json" ] || continue
    found=$((found + 1))
    dst="$prof/user.js"
    if [ -f "$dst" ] && cmp -s "$SRC" "$dst"; then
      ok "unchanged  ${prof/#$HOME/\~}"
      continue
    fi
    if [ -f "$dst" ]; then
      step "would change ${dst/#$HOME/\~}"
      diff -u "$dst" "$SRC" || true
    else
      step "would create ${dst/#$HOME/\~}"
    fi
    install -m 0644 "$SRC" "$dst" && ok "wrote      ${dst/#$HOME/\~}"
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d)
done

[ "$found" -gt 0 ] || die "no Firefox profiles found under: ${roots[*]}"
info "$found profile(s) updated."

# user.js is read at startup only. Say so plainly - a silent no-op here is
# exactly how someone concludes "the tweaks didn't work".
if pgrep -x firefox >/dev/null; then
  warn "Firefox is running - these prefs apply at its NEXT launch, not now."
  warn "Restart Firefox, then confirm in about:config."
fi

info "Verify with: scripts/doctor.sh"
