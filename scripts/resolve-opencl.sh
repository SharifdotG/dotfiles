#!/usr/bin/env bash
# Pin the ROCm OpenCL runtime to 5.7.1 so DaVinci Resolve can see a Polaris GPU.
#
#   scripts/resolve-opencl.sh   [--dry-run] [--undo] [--status]
#
# WHY THIS EXISTS
#
# Resolve needs an OpenCL device. AMD removed Polaris/gfx803 from ROCm after
# 5.7, and the repos now ship 7.x, which enumerates NO device on an RX 570 -
# `clinfo -l` lists nothing and Resolve either refuses to start or hangs on the
# splash screen. 5.7.1 is the last release that still works, with
# ROC_ENABLE_PRE_VEGA=1 set (~/.local/bin/resolve does that part).
#
# This is a genuinely fragile workaround and this script does not pretend
# otherwise: it downgrades packages out of the Arch Linux Archive, holds them
# there with IgnorePkg, and then PROVES the result with clinfo rather than
# reporting success because the commands exited 0.
#
# NB: holding packages back is not free. rocm-opencl-runtime will stop
# receiving security and correctness fixes for as long as the pin is on, and a
# future mesa or glibc can break a 5.7.1 binary that nothing is rebuilding.
# --undo removes the pin. See docs/DESKTOP.md.
set -uo pipefail
cd "$(dirname "$0")/.."
. lib/log.sh
. lib/detect.sh
detect_all

# The pinned set. One transaction, because they depend on each other and
# installing them one at a time fails on the first dependency check.
PIN_VERSION=5.7.1
PKGS=(rocm-core comgr rocm-opencl-runtime rocm-cmake)
MARK_BEGIN="# >>> dotfiles: ROCm pin for DaVinci Resolve on Polaris >>>"
MARK_END="# <<< dotfiles: ROCm pin <<<"
PACCONF=/etc/pacman.conf

DRY=0 UNDO=0 STATUS=0
for a in "$@"; do case "$a" in
  --dry-run) DRY=1 ;;
  --undo)    UNDO=1 ;;
  --status)  STATUS=1 ;;
  -h|--help) awk 'NR>1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
  *) die "unknown flag: $a" ;;
esac; done

run() { if [ "$DRY" -eq 1 ]; then printf '    would run: %s\n' "$*"; else "$@"; fi; }

# ── preflight ────────────────────────────────────────────────────────────────
[ "$(id -u)" -ne 0 ] || die "do not run me as root; I call sudo only where needed"

UI_STEPS=4
banner "resolve-opencl" "pin ROCm to $PIN_VERSION · Polaris needs it · verified with clinfo"

# NB: refuse on anything but an AMD GPU, and refuse LOUDLY. Running this on the
# Intel laptop would downgrade a working stack to an ancient one that cannot
# help it, for a GPU it does not have. The check is the live PCI read from
# lib/detect.sh, not a profile name.
[ "$GPU" = amd ] ||
  die "this machine's GPU is '$GPU', not amd - refusing.
       This pin exists only for Polaris (RX 570/580, gfx803). On any other GPU
       it downgrades a working OpenCL stack for no reason. Override the
       detection with DOTFILES_GPU=amd only if you are certain."

report_state() {
  local v ign
  v=$(pacman -Q rocm-opencl-runtime 2>/dev/null | awk '{print $2}')
  note "rocm-opencl-runtime" "${v:-<not installed>}"
  ign=$(pacman-conf IgnorePkg 2>/dev/null | tr '\n' ' ')
  note "IgnorePkg (live)" "${ign:-<none>}"
  if command -v clinfo >/dev/null 2>&1; then
    local n
    n=$(ROC_ENABLE_PRE_VEGA=1 clinfo -l 2>/dev/null | grep -c 'Device')
    note "OpenCL devices" "${n:-0}"
    [ "${n:-0}" -gt 0 ] && ROC_ENABLE_PRE_VEGA=1 clinfo -l 2>/dev/null | sed 's/^/      /'
  else
    note "clinfo" "<not installed: sudo pacman -S clinfo>"
  fi
}

if [ "$STATUS" -eq 1 ]; then
  step "current state"
  report_state
  steps_end
  exit 0
fi

# ── undo ─────────────────────────────────────────────────────────────────────
if [ "$UNDO" -eq 1 ]; then
  step "removing the pin"
  if ! grep -qF "$MARK_BEGIN" "$PACCONF" 2>/dev/null; then
    ok "no pin block in $PACCONF - nothing to remove"
  else
    run sudo sed -i "/^${MARK_BEGIN}\$/,/^${MARK_END}\$/d" "$PACCONF" &&
      ok "removed the IgnorePkg block"
  fi
  info "the DOWNGRADED packages are still installed. To go back to current:"
  info "  sudo pacman -Syu ${PKGS[*]}"
  warn "Resolve will stop seeing the GPU once you do that - that is the trade."
  steps_end
  exit 0
fi

# ── 1. where we are now ──────────────────────────────────────────────────────
step "before"
report_state

# ── 2. fetch the pinned packages ─────────────────────────────────────────────
step "fetch $PIN_VERSION from the Arch Linux Archive"
command -v curl >/dev/null || die "curl is required"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles/rocm-$PIN_VERSION"
mkdir -p "$CACHE"

# NB: the exact filename is DISCOVERED from the archive index, never
# constructed. Package release numbers differ between packages (5.7.1-1 vs
# 5.7.1-2) and some of these carry a pacman EPOCH in the repo version - comgr
# is 2:7.2.4 today - which does not appear in the archive filename at all.
# Guessing the filename produces a 404 that reads like the archive is down.
FILES=()
for pkg in "${PKGS[@]}"; do
  first=${pkg:0:1}
  fname=$(curl -fsS --max-time 30 "https://archive.archlinux.org/packages/$first/$pkg/" 2>/dev/null |
          grep -oE "$pkg-$PIN_VERSION-[0-9]+-x86_64\.pkg\.tar\.zst" |
          sort -u | tail -1)
  [ -n "$fname" ] ||
    die "no $pkg-$PIN_VERSION-* in the Arch Linux Archive.
       Check https://archive.archlinux.org/packages/$first/$pkg/ by hand - if
       the version is gone, this workaround is over and Resolve needs either
       Studio on a supported GPU or a different editor."
  FILES+=("$CACHE/$fname")
  if [ -s "$CACHE/$fname" ]; then
    ok "cached    $fname"
  else
    info "download  $fname"
    run curl -fsS --max-time 300 -o "$CACHE/$fname" \
      "https://archive.archlinux.org/packages/$first/$pkg/$fname" ||
      die "download failed: $fname"
  fi
done

# ── 3. install and hold ──────────────────────────────────────────────────────
step "install and hold"
warn "This DOWNGRADES ${#PKGS[@]} packages and holds them with IgnorePkg."
warn "snapper takes a pre/post snapshot around it (snap-pac), so it is revertible."
if [ "$DRY" -eq 0 ]; then
  printf '  Proceed? [y/N] '
  read -r reply
  case "$reply" in [yY]*) ;; *) die "aborted - nothing changed" ;; esac
fi

# One transaction. Separate `pacman -U` calls fail on the first dependency
# check because these four only satisfy each other at matching versions.
run sudo pacman -U --noconfirm "${FILES[@]}" ||
  die "pacman -U failed - nothing has been pinned. The packages are cached in
       $CACHE if you want to retry by hand."

# NB: the IgnorePkg line must go INSIDE [options]. Appending to the end of
# pacman.conf lands it in whatever repo section happens to be last, where
# pacman parses it as a repo-level directive and silently does not apply it -
# so `pacman -Syu` would quietly undo this whole script on the next update and
# nothing would say why. Insert after the [options] header instead.
if grep -qF "$MARK_BEGIN" "$PACCONF" 2>/dev/null; then
  ok "pin block already in $PACCONF"
else
  info "adding the IgnorePkg block to [options] in $PACCONF"
  tmp=$(mktemp)
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" -v p="${PKGS[*]}" '
    { print }
    /^\[options\]$/ && !done {
      print b
      print "# Written by scripts/resolve-opencl.sh. DaVinci Resolve needs an OpenCL"
      print "# device and AMD dropped Polaris/gfx803 after ROCm 5.7; anything newer"
      print "# enumerates nothing on an RX 570. Remove with: scripts/resolve-opencl.sh --undo"
      print "IgnorePkg = " p
      print e
      done = 1
    }' "$PACCONF" > "$tmp"
  if [ "$DRY" -eq 1 ]; then
    info "would insert into [options]:"
    sed -n "/^${MARK_BEGIN}\$/,/^${MARK_END}\$/p" "$tmp" | sed 's/^/      /'
  else
    sudo install -m 0644 "$tmp" "$PACCONF" && ok "wrote the pin block"
  fi
  rm -f "$tmp"
fi

# ── 4. prove it ──────────────────────────────────────────────────────────────
step "verify"
if [ "$DRY" -eq 1 ]; then
  info "dry run - nothing was changed, so there is nothing to verify"
  steps_end
  exit 0
fi

# NB: read the LIVE parsed config, not the file just written. pacman.conf can
# be shadowed by an Include, and a directive in the wrong section parses
# without error and does nothing.
if pacman-conf IgnorePkg 2>/dev/null | grep -qx rocm-opencl-runtime; then
  ok "pacman is honouring the hold"
else
  warn "pacman-conf does not list rocm-opencl-runtime in IgnorePkg.
       The block was written but is not in effect - check for an Include in
       $PACCONF that overrides [options]."
fi

report_state

# The exit status is the contract. "Installed without errors" is not the same
# as "Resolve can start", and only the second one matters here.
if ! command -v clinfo >/dev/null 2>&1; then
  warn "clinfo is not installed, so this cannot confirm the GPU is visible.
       sudo pacman -S clinfo && $0 --status"
  steps_end
  exit 1
fi
if [ "$(ROC_ENABLE_PRE_VEGA=1 clinfo -l 2>/dev/null | grep -c 'Device')" -gt 0 ]; then
  steps_end
  ok "OpenCL device visible - launch Resolve with ~/.local/bin/resolve"
  exit 0
else
  steps_end
  warn "NO OpenCL device. Resolve will not start.
       The downgrade completed but did not achieve the goal, which usually
       means a dependency outside this set (hsa-rocr, rocm-llvm) is still at
       7.x and shadowing it. Check:
         ROC_ENABLE_PRE_VEGA=1 clinfo
         pacman -Q | grep -E 'rocm|comgr|hsa'
       Roll back with snapper if you want the old state:  snapper -c root list"
  exit 1
fi
