#!/usr/bin/env bash
# Install the load-bearing /etc drop-ins. Idempotent; shows a diff before writing.
# Run with: sudo ./system/apply.sh   [--dry-run]
set -euo pipefail
cd "$(dirname "$0")"
. ../lib/log.sh
. ../lib/detect.sh
. ../lib/sensors.sh
detect_all

# NB: no UI_STEPS here. This script's two `step` calls are inside
# install_file(), once per file in --dry-run, not top-level phases - numbering
# them would count files and print [3/2].
banner "system" "/etc drop-ins · idempotent · shows a diff before writing"

DRY=0; [ "${1:-}" = --dry-run ] && DRY=1
[ "$DRY" -eq 1 ] || [ "$(id -u)" -eq 0 ] || die "run me with sudo"
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

# Set by any step that failed in a way this run must not swallow. Checked once,
# at the very end, so the failure is loud AND the rest of the run still happens -
# a boot-path failure should not also cost you the twelve drop-ins after it.
#
# NB: scoped deliberately. Only the initramfs step sets this, because that is
# the only remaining step whose failure can leave the machine booting something
# other than what this script just configured. The udev and zram warnings are
# recoverable and stay warnings; that is a decision, not an oversight.
FAILED=0

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
  # NB: `die` on failure, not a bare `install`. Under `set -e` a failed install
  # aborts the whole run printing NOTHING - no warn, no error, no steps_end -
  # after an arbitrary number of earlier drop-ins have already been written.
  # A half-applied /etc that exits 1 in silence is the worst of both outcomes.
  local _out
  _out=$(install -D -m "$mode" "$src" "$dst" 2>&1) ||
    die "could not write $dst: ${_out:-no output from install}"
  CHANGED=1
  ok "wrote      $dst"
}

# THE ONLY route into /etc/modprobe.d. Anything that reaches the kernel as a
# module parameter goes through here, and here refuses unless HW_TUNING is on.
#
# NB: THIS HAS NO CALLER TODAY, and that is not dead code to be tidied away - it
# is a tripwire. `system/modprobe.d/` is empty on purpose (see the note further
# down about ppfeaturemask). The next person who wants to set a module parameter
# will look for the way to do it, find this, and have to make the decision
# deliberately instead of adding one more `install_file` line that looks exactly
# like the twelve harmless ones above it. That was how the GPU broke: the
# dangerous change was indistinguishable from the safe ones at the call site.
install_modprobe_file() { # install_modprobe_file <src> <dst>
  if [ "$HW_TUNING" != on ]; then
    info "skipping $2 - kernel/module tweaks are opt-in and OFF by default.
       Enable with: echo on | sudo tee /etc/dotfiles-hw-tuning
       Read docs/DESKTOP.md first - this is the mechanism that hung the GPU."
    return 0
  fi
  install_file "$1" "$2"
  # A module parameter only reaches a driver that loads from the initramfs once
  # the initramfs has been rebuilt. Setting this is not optional.
  INITRAMFS_STALE=1
  return 0
}

# Take a file this repo used to own back OFF the machine.
#
# NB: this is not symmetry for its own sake. Dropping a file from the repo stops
# it being INSTALLED; it does nothing about the machines that already have it,
# and pacman does not own /etc drop-ins either - so without this, a setting this
# repo has disowned outlives the decision to disown it, forever, on exactly the
# machines that were kept up to date.
#
# NB: removal is never gated on HW_TUNING. A gate that can block un-breaking a
# machine is worse than no gate.
remove_file() { # remove_file <path> [why]
  if [ ! -e "$1" ]; then return 0; fi
  step "would remove $1"
  if [ -n "${2:-}" ]; then info "  $2"; fi
  if [ "$DRY" -eq 1 ]; then return 0; fi
  rm -f "$1"
  # A modprobe.d file is COPIED INTO the initramfs by mkinitcpio's modconf hook,
  # so deleting it from /etc is only half the removal - see the initramfs block.
  case "$1" in /etc/modprobe.d/*) INITRAMFS_STALE=1 ;; esac
  ok "removed    $1"
  return 0
}

# NB: `return 0` unconditionally, and this is the ONE place in this file where
# that guard is actually load-bearing.
#
# CORRECTION, 2026-09-05. The note that used to be here said a bare
# `cmd && ok || warn` at the TOP LEVEL aborts the run under `set -e`. It does
# not, and three comments in this file repeated the claim. `set -e` is suspended
# for every command of an && / || list except the last, and a list whose first
# member fails is not a trigger at all:
#
#     bash -c 'set -e; [ x = y ] && X=1; echo survived'   -> survived
#
# What IS fatal is a FUNCTION whose last command evaluates false - the function
# returns non-zero, and a bare call to it at the top level is then an unhandled
# failure:
#
#     bash -c 'set -e; f(){ [ a = b ] && echo hi; }; f; echo after'   -> (exits)
#
# That is exactly this function's shape, so `return 0` stays. Do not "tidy" the
# `if` statements elsewhere in this file back into && chains on the strength of
# the old comment - they are fine either way, but the reasoning was wrong.
# Run a command; if it fails, say so WITH the reason it gave.
#
# NB: this replaces `cmd >/dev/null 2>&1 && ok "..." || warn "..."`, which this
# file used six times. That shape throws away stderr - the only place the
# command explains itself - and three of the six had no failure branch at all,
# so a failed `sysctl --system` or `daemon-reload` printed absolutely nothing
# and left a missing line in a report nobody reads line by line. Worse, the
# swappiness post-check further down would then blame the udev rule for a value
# that is wrong because the reload never happened.
run_step() {
  local label="$1"; shift
  local _out
  if _out=$("$@" 2>&1); then
    ok "$label"
  else
    warn "$label FAILED: ${_out:-no output}"
  fi
  return 0
}

enable_unit() {
  local _out
  if systemctl is-enabled --quiet "$1" 2>/dev/null; then
    ok "already enabled $1"
  else
    # NB: keep stderr. "Unit not found", "unit is masked" and "enabled, but
    # failed to start" need three different actions from you and used to print
    # one indistinguishable line.
    if _out=$(systemctl enable --now "$1" 2>&1); then
      ok "enabled $1"
    else
      warn "could not enable $1: ${_out:-no output}"
    fi
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
# NB: keyed on the hardware axes, not on PROFILE alone. The sensor chip is a
# desktop-board fact.
#
# WHAT USED TO BE HERE, AND WHY IT IS GONE. This block also wrote
# /etc/modprobe.d/99-amdgpu-ppfeaturemask.conf - `options amdgpu
# ppfeaturemask=0xffffffff` - to unlock the power-management interface for LACT.
# On 2026-09-05 that value finally reached the initramfs, and from the next boot
# the desktop hung and reset its GPU every ten seconds: amdgpu's default
# lockup_timeout, in a loop, on every boot, because the drop-in is baked into
# the initramfs and so survives a restart.
#
# 0xffffffff is not "the default plus OverDrive". It forces EVERY PowerPlay bit
# on, including PP_GFX_DCS_MASK (0x80000), which the driver deliberately leaves
# off by default on Polaris. The removed file argued "there is no benefit to
# being surgical here on a card you own"; the benefit is that the driver's
# defaults encode which bits are safe on which silicon, and overriding all of
# them discards that knowledge wholesale.
#
# Nothing is lost that this repo needs: LACT's fan curve goes through the
# standard hwmon interface and works on the stock mask. Only OverDrive
# clock/voltage tuning needs the bit, and that is not worth a GPU reset loop.
#
# If it is ever wanted back, all three of these are required and none is
# optional: gate it on HW_TUNING (see lib/detect.sh), set the driver default
# plus PP_OVERDRIVE_MASK (0xfff7ffff) rather than every bit, and regenerate the
# initramfs - amdgpu loads from there, so a modprobe.d option is inert until it
# does, which is exactly why this was silently dormant for so long before it
# went off.

# Take the old drop-in back off any machine that still carries it.
#
# NB: deliberately NOT inside `if [ "$GPU" = amd ]`. Removing a file this repo
# no longer owns is unconditionally correct, and hanging it off GPU detection
# would mean a machine where detection returns `mixed` (see lib/detect.sh) keeps
# the setting that caused the freeze loop. Cleanup must not depend on the
# detection working.
#
# NB: this is also the emergency fix for the machine that is already broken -
# `sudo ./system/apply.sh` removes the drop-in, regenerates the initramfs, and
# the next boot is stock. It costs nothing on a machine that never had it.
INITRAMFS_STALE=0
remove_file /etc/modprobe.d/99-amdgpu-ppfeaturemask.conf \
  "this repo no longer sets amdgpu.ppfeaturemask - 0xffffffff hung Polaris in a GPU reset loop"

# Which Nuvoton chip is on the board is PROBED, never inferred from the DMI
# board name - see lib/sensors.sh for what that guess cost. Root only, and never
# under --dry-run, because inserting a module is a change to the machine.
#
# NB: only `warn` inside here. It writes to stderr; info/ok write to stdout and
# would be captured as part of this function's return value.
probe_board_sensor() {
  local m out
  for m in $BOARD_SENSOR_MODS; do
    board_sensor_available "$m" || continue
    if ! out=$(modprobe "$m" 2>&1); then
      warn "modprobe $m failed: ${out:-no output}"
      continue
    fi
    if board_sensor_bound >/dev/null 2>&1; then echo "$m"; return 0; fi
    # Inserted, found no chip. Take it back out rather than leave a driver
    # loaded that reports nothing and will be loaded again at every boot.
    modprobe -r "$m" >/dev/null 2>&1 || true
  done
  return 1
}

BOARD_SENSOR_MOD=''
if [ "$PROFILE" = desktop ]; then
  info "Board sensors (Nuvoton Super-I/O)"
  # Already bound - from a previous boot's drop-in, or an autoload. That is the
  # answer; do not re-probe hardware that has already told you what it is.
  BOARD_SENSOR_MOD=$(board_sensor_bound 2>/dev/null || true)
  if [ -n "$BOARD_SENSOR_MOD" ]; then
    ok "$BOARD_SENSOR_MOD is bound - the chip is present"
  elif [ "$DRY" -eq 1 ]; then
    info "  nothing bound yet; a real run would try: $BOARD_SENSOR_MODS"
  else
    BOARD_SENSOR_MOD=$(probe_board_sensor || true)
  fi

  if [ -n "$BOARD_SENSOR_MOD" ]; then
    # The drop-in makes it load at boot; systemd-modules-load.service reads
    # /etc/modules-load.d once, at boot, and nothing re-reads it.
    install_file modules-load.d/99-"$BOARD_SENSOR_MOD".conf \
                 /etc/modules-load.d/99-"$BOARD_SENSOR_MOD".conf
    # Exactly one of the two may be installed. Whichever we did not choose is
    # stale - and two Super-I/O drivers loading at boot is the port-contention
    # case this whole probe exists to avoid.
    for _other in $BOARD_SENSOR_MODS; do
      [ "$_other" = "$BOARD_SENSOR_MOD" ] && continue
      if [ "$DRY" -eq 0 ] && [ -f "/etc/modules-load.d/99-$_other.conf" ]; then
        rm -f "/etc/modules-load.d/99-$_other.conf" 2>/dev/null || true
        ok "removed stale /etc/modules-load.d/99-$_other.conf"
      fi
    done
    unset _other
    if board_sensor_has_fan; then
      ok "board reports a fan RPM"
    else
      warn "$BOARD_SENSOR_MOD bound but publishes no fan input - 'sensors' is the
       honest check. The drop-in is installed either way; a chip that binds and
       reports nothing is a driver question, not a configuration one."
    fi
  elif [ "$DRY" -eq 0 ]; then
    # NB: install NOTHING. This is the branch the old board-name guess did not
    # have: it asserted nct6687 for every board it did not recognise, so a
    # machine with no Nuvoton chip got a modules-load.d entry regardless.
    info "no Nuvoton board sensor found - installing no drop-in.
       k10temp (CPU) and amdgpu (GPU) still report temperatures.
       To investigate by hand: sudo sensors-detect"
  fi
fi

[ "$DRY" -eq 1 ] && { info "dry run - nothing written"; exit 0; }

info "Reloading"
run_step "sysctl reloaded"    sysctl --system
# NB: udevadm control --reload only makes udev re-read the RULES. It does not
# re-evaluate them against existing devices - that is what the zram trigger
# further down does, via the restart.
run_step "udev rules reloaded" udevadm control --reload
run_step "systemd reloaded"    systemctl daemon-reload
run_step "journald restarted"  systemctl restart systemd-journald

# NB: no modprobe step here any more. The sensor module needs no separate load:
# the probe further up INSERTED it in order to find out whether it binds, so by
# the time control reaches here it is either loaded or was never the right
# module. /etc/modules-load.d is what makes it come back at the next boot -
# systemd-modules-load.service reads that directory once, at boot, and nothing
# re-reads it, which is why the insertion has to happen during the run.

# ── initramfs ────────────────────────────────────────────────────────────────
# NB: READ THE TRIGGER. This fires only when remove_file deleted something from
# /etc/modprobe.d, and this repo INSTALLS no /etc/modprobe.d file at all - so on
# a clean machine INITRAMFS_STALE can never become 1 and mkinitcpio is never
# invoked. A first bootstrap does not touch the boot path. That is structural,
# not a condition someone has to keep getting right.
#
# It exists for exactly one transition: a machine still carrying the
# ppfeaturemask drop-in. Deleting that file from /etc is NOT enough on its own -
# amdgpu loads from the initramfs and reads the copy mkinitcpio's modconf hook
# baked in there, so without this the script would report the tweak removed and
# leave the machine hanging every ten seconds anyway.
#
# The previous version was the inverse of all of this: its staleness test
# compared a hex string from sysfs against a decimal literal, so it was
# permanently true and regenerated the initramfs on every single run - which is
# what eventually pushed ppfeaturemask into a booted image.
if [ "$INITRAMFS_STALE" -eq 1 ]; then
  info "Regenerating the initramfs (a repo-owned /etc/modprobe.d file was removed)"
  # On CachyOS with Limine, limine-mkinitcpio is what makes the BOOTLOADER
  # consume the new image; plain `mkinitcpio -P` regenerates it and Limine can
  # go on booting the old copy. That distinction is not cosmetic - it is why the
  # bad mask stayed dormant for a while and then suddenly took effect.
  if command -v limine-mkinitcpio >/dev/null 2>&1; then
    _mk=(limine-mkinitcpio)
  else
    _mk=(mkinitcpio -P)
  fi
  # NB: NOT `>/dev/null 2>&1`. Hiding this is how a failure to build a bootable
  # initramfs becomes one yellow line about a GPU power knob. Missing firmware,
  # a broken hook or a full /boot all surface here or nowhere.
  if _mkout=$("${_mk[@]}" 2>&1); then
    ok "initramfs regenerated (${_mk[0]})"
  else
    FAILED=1
    warn "${_mk[0]} FAILED. The removed module option is STILL inside the
       initramfs and WILL be applied at the next boot. Do not reboot until this
       is fixed. Full output:"
    printf '%s\n' "$_mkout" | sed 's/^/      /' >&2
  fi
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
# zram-generator.conf but cannot re-compress or resize a device that is already
# swapped on: the reset returns EBUSY and the restart then dies writing
# comp_algorithm. CachyOS starts zram at boot from its own vendor config, so a
# live, in-use zram0 is the NORMAL state here, not an edge case.
#
# NB: and on CachyOS the restart is usually POINTLESS, which is the first thing
# to establish rather than the last. /usr/lib/systemd/zram-generator.conf ships
# the same four settings this repo does - zstd, size=ram, priority 100, swap - so
# the live device is already exactly what we are about to ask for. Restarting it
# can then only fail; it cannot improve anything. Compare first, and do nothing
# when there is nothing to do.
#
# NB: `grep zram >/dev/null`, NEVER `grep -q zram`, in these pipelines. This
# script runs under `set -o pipefail`, and `grep -q` exits at the first match,
# which can SIGPIPE `swapon` and make the whole pipeline return 141 - so the test
# reads FALSE on a machine where zram is plainly active, and the swapoff below
# is skipped. scripts/doctor.sh documents this exact trap; apply.sh was
# committing it.
zram_live_matches() { # zram_live_matches <wanted-algorithm>
  local cur_alg
  [ -r /sys/block/zram0/comp_algorithm ] || return 1
  # The ACTIVE algorithm is the one the kernel puts in [brackets]; the rest of
  # that file is the list of what is merely available.
  cur_alg=$(sed -n 's/.*\[\([a-zA-Z0-9-]*\)\].*/\1/p' /sys/block/zram0/comp_algorithm 2>/dev/null)
  [ "$cur_alg" = "$1" ] || return 1
  swapon --show=NAME --noheadings 2>/dev/null | grep zram >/dev/null || return 1
  return 0
}

_zram_want=$(sed -n 's/^[[:space:]]*compression-algorithm[[:space:]]*=[[:space:]]*//p' \
             systemd/zram-generator.conf 2>/dev/null | head -1)
_zram_want="${_zram_want:-zstd}"

if zram_live_matches "$_zram_want"; then
  ok "zram already matches this config ($_zram_want, $(swapon --show=SIZE --noheadings 2>/dev/null | head -1)) - not restarting"
else
  # swapoff genuinely can fail: it has to read every swapped page back into RAM,
  # so it returns ENOMEM when they no longer fit. Do NOT hide that. The restart
  # would then be guaranteed to fail with EBUSY, and the old message blamed
  # `zramctl`, which sends you to look at the wrong thing entirely.
  if swapon --show=NAME --noheadings 2>/dev/null | grep zram >/dev/null; then
    if _out=$(swapoff /dev/zram0 2>&1); then
      ok "zram swap released"
    else
      warn "swapoff /dev/zram0 failed: ${_out:-no output}"
    fi
  fi
  if swapon --show=NAME --noheadings 2>/dev/null | grep zram >/dev/null; then
    # Still in use. Restarting now cannot succeed, and trying leaves a FAILED
    # unit and possibly a machine with no swap at all - strictly worse than
    # stopping here. The file on disk is correct either way.
    warn "zram0 is still in use, so it cannot be reconfigured while running.
       NOT fatal, and nothing is half-applied: /etc/systemd/zram-generator.conf
       is written and the new settings take effect at the next boot."
  else
    run_step "zram reconfigured" systemctl restart systemd-zram-setup@zram0.service
    # NB: having taken swap DOWN, confirm it came back. A failed restart here
    # leaves the machine with no swap, which is the one outcome worse than
    # never having touched it, and it is silent otherwise.
    if ! swapon --show=NAME --noheadings 2>/dev/null | grep zram >/dev/null; then
      FAILED=1
      warn "zram swap is NOT active after the restart - this machine currently
       has no swap. Recover with:
         sudo swapoff /dev/zram0 2>/dev/null; sudo zramctl --reset /dev/zram0
         sudo systemctl reset-failed systemd-zram-setup@zram0.service
         sudo systemctl restart systemd-zram-setup@zram0.service
       A reboot also fixes it - the generator configures the device cleanly at
       boot, before anything is swapped onto it."
    fi
  fi
fi
# The restart above fires the zram0 `change` event that both 30-zram.rules and
# our 99- rule react to, so swappiness is settled by the post-check below. If
# zram did NOT restart, nothing re-evaluated the rules against the live device -
# force it, or the post-check reports 150 on a machine that is actually fine
# after a reboot.
#
# NB: these two keep `|| true` on purpose - a trigger that finds nothing to do
# is not a fault - but they no longer discard stderr silently, because when the
# TRIGGER is what failed the swappiness post-check below blames the udev rule
# for it, which sends you to the wrong file entirely.
run_step "zram udev rules re-evaluated" udevadm trigger --action=change /sys/block/zram0
udevadm settle --timeout=5 >/dev/null 2>&1 || true

if systemctl is-active --quiet docker; then
  # NB: `run_step`, not `systemctl restart docker; ok "..."`. That semicolon
  # made this the one line in the file that could kill the run under `set -e` -
  # and it sat directly above the vendor-defaults report and BOTH post-checks,
  # so a failed docker restart silently skipped the swappiness verification
  # this script's own comments call the honest source of truth.
  run_step "docker restarted" systemctl restart docker
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
# NB: `if` rather than `[ ... ] && info`, which is fine but not for the reason
# this comment used to give. It claimed a top-level test-and-command with a
# FALSE test aborts under `set -e`. It does not - `-e` is suspended for every
# command of an && list except the last, and a list whose first member fails is
# not a trigger. See the corrected note above enable_unit() for the shape that
# genuinely is fatal (a function whose last command evaluates false), which is
# the one thing `return 0` there is actually buying.
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

# NB: the amdgpu ppfeaturemask post-check that used to sit here is gone with the
# drop-in it verified. It ended in `want 0xffffffff - REBOOT to apply`, which
# after the removal would have spent every run telling you to restore the exact
# setting that caused the GPU reset loop. A check that outlives the thing it
# checks does not decay into silence; it decays into confident wrong advice.
#
# The live mask is still worth SEEING, so scripts/doctor.sh reports it - as a
# note, not an assertion. Whatever the driver picks is now the correct answer by
# definition, and there is no repo-side value to compare it against.
if [ "$GPU" = amd ]; then
  note "amdgpu ppfeaturemask" \
       "$(cat /sys/module/amdgpu/parameters/ppfeaturemask 2>/dev/null || echo '<unreadable>') (driver default; this repo no longer sets it)"
fi

steps_end
# NB: a real exit status, which this script did not have before. Everything
# above is written to keep going after a failure so one bad step does not cost
# you the rest of the run - but "kept going" is not "succeeded", and a caller
# (or a person skimming) needs to be able to tell.
if [ "$FAILED" -ne 0 ]; then
  die "one or more steps FAILED - see the warnings above. Nothing was rolled back."
fi
info "Done. Verify with: scripts/doctor.sh"
