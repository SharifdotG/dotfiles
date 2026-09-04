#!/usr/bin/env bash
# Health check. Read-only: reports, never changes anything.
set -uo pipefail
cd "$(dirname "$0")/.."
. lib/log.sh
. lib/detect.sh
detect_all

pass=0; fail=0
# NB: the glyph and colour come from lib/log.sh, which drops both when stdout is
# not a terminal. This used to hardcode \033[1;32m unconditionally, so a piped
# or redirected doctor run carried raw escape codes into the log - the one thing
# lib/log.sh exists to prevent. `note` now comes from the library too, so both
# line up in the same columns.
chk() { # chk <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf '  %s%s%s %s %s\n' "$_C_GREEN" "$_G_OK" "$_C_RESET" "$(ui_leader "$1")" "$3"
    pass=$((pass+1))
  else
    printf '  %s%s%s %s %s %s(want: %s)%s\n' "$_C_RED$_C_BOLD" "$_G_BAD" "$_C_RESET" \
      "$(ui_leader "$1")" "$3" "$_C_DIM" "$2" "$_C_RESET"
    fail=$((fail+1))
  fi
}

# NB: THIS SCRIPT MUST NOT BE RUN WITH sudo, and the guard is here because an
# earlier version of the "root snapshots" note below literally told you to.
# Almost everything here is a USER-CONTEXT probe - ~/.zshrc, ~/.config/*,
# `zsh -ic`, fc-match, kreadconfig6, `systemctl --user`. Under sudo, HOME
# becomes /root and there is no user session bus, so ten-odd checks go red at
# once and the machine looks broken when it is fine. That is a far worse
# failure than the two notes that genuinely cannot see anything without root.
#
# So: run as yourself. The two root-only numbers degrade to a hint naming the
# exact command to get them, rather than dragging the whole report to root.
if [ "$(id -u)" -eq 0 ]; then
  printf '%s\n' \
    "doctor: do not run this with sudo." \
    "" \
    "  Nearly every check here reads YOUR home and YOUR session - ~/.zshrc," \
    "  ~/.config, zsh, fontconfig, kreadconfig6, systemctl --user. As root," \
    "  HOME=/root and there is no user bus, so they all fail for the wrong" \
    "  reason." \
    "" \
    "  Run:  scripts/doctor.sh" \
    "" \
    "  The only two numbers that need root are the coredump directory size" \
    "  and the snapshot count; the report tells you how to get each." >&2
  exit 2
fi

_uarch=$(/lib64/ld-linux-x86-64.so.2 --help 2>/dev/null |
         awk '/x86-64-v[0-9] \(supported/ {print $1}' | sort -r | head -1)
# NB: derived, not hardcoded. It was a literal 11, which was right until the
# desktop added two more sections and the last one printed "[13/11]" - the same
# small wrongness bootstrap.sh already avoids by counting rather than guessing.
UI_STEPS=12
[ "$PROFILE" = desktop ] && UI_STEPS=$(( UI_STEPS + 2 ))
banner "doctor" "read-only health check · reports, never changes anything"
info "System: $DISTRO / $DESKTOP / $SESSION_TYPE  (vm: $IS_VM, pkg column: $PKG_COL, ${_uarch:-?})"
info "Machine: profile=$PROFILE / cpu=$CPU_VENDOR / gpu=$GPU"

step "Platform"
# NB: a v4 package on a v3 CPU installs cleanly and dies with SIGILL at RUNTIME,
# which presents as random binaries crashing - it reads exactly like failing RAM.
# Check the repo tier against the CPU, not against what you think you selected.
chk "no v4 repo on a non-v4 CPU"  ok \
  "$(if grep -q '^\[cachyos-v4' /etc/pacman.conf 2>/dev/null && [ "$_uarch" != x86-64-v4 ]; then
       echo MISMATCH; else echo ok; fi)"
note "cachyos repo tier" "$(grep -oE '^\[cachyos(-v[34])?[a-z-]*\]' /etc/pacman.conf 2>/dev/null | tr -d '[]' | tr '\n' ' ')"

step "GPU & display stack"
# The whole point of this section: none of these failures ANNOUNCE themselves.
# A wrong VA-API driver name does not error, it just stops decoding. A missing
# Vulkan driver does not error, the loader substitutes llvmpipe and the machine
# renders on the CPU. Both look like "it got slow", never like a broken config.

# NB: chezmoi bakes `gpu` into ~/.config/chezmoi/chezmoi.toml at init and never
# re-reads the hardware, so swapping a card leaves the stored answer stale and
# LIBVA_DRIVER_NAME wrong forever. Compare the stored value against a live PCI
# read. This is the house rule applied to the profile mechanism itself.
_cmtoml="${XDG_CONFIG_HOME:-$HOME/.config}/chezmoi/chezmoi.toml"
_bakedgpu=$(sed -n 's/^[[:space:]]*gpu[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' \
            "$_cmtoml" 2>/dev/null | head -1)
if [ -z "$_bakedgpu" ]; then
  note "chezmoi .gpu" "<not set - run: chezmoi init --source \"$PWD\">"
else
  chk "chezmoi .gpu matches hardware" "$GPU" "$_bakedgpu"
fi

# What the APPS actually get. Not $LIBVA_DRIVER_NAME from this shell - that is
# inherited and would be empty on a TTY even when the setting is fine.
# environment.d is read by the systemd user manager, so ask the user manager.
_libva=$(systemctl --user show-environment 2>/dev/null |
         sed -n 's/^LIBVA_DRIVER_NAME=//p' | head -1)
case "$GPU" in
  intel) chk "LIBVA_DRIVER_NAME"  iHD       "${_libva:-<unset>}" ;;
  amd)   chk "LIBVA_DRIVER_NAME"  radeonsi  "${_libva:-<unset>}" ;;
  *)     note "LIBVA_DRIVER_NAME" "${_libva:-<unset>} (gpu=$GPU, nothing expected)" ;;
esac

# NB: and then prove the driver LOADS. Having the name set and having VA-API
# working are different things - the whole reason environment.d carries that NB.
if ! command -v vainfo >/dev/null 2>&1; then
  note "vainfo" "<not installed: pacman -S libva-utils>"
else
  _va=$(vainfo 2>/dev/null | sed -n 's/^vainfo: Driver version: //p' | head -1)
  chk "VA-API initialises"       yes "$([ -n "$_va" ] && echo yes || echo no)"
  note "  driver" "${_va:-<none - hardware video decode is OFF>}"
fi

# NB: llvmpipe is the silent-substitution case in its purest form. It is a
# perfectly working Vulkan implementation, it reports success, and it runs on
# the CPU. Assert the driver is NOT it rather than asserting a device exists.
if ! command -v vulkaninfo >/dev/null 2>&1; then
  note "vulkaninfo" "<not installed: pacman -S vulkan-tools>"
else
  _icd=$(vulkaninfo --summary 2>/dev/null |
         sed -n 's/^[[:space:]]*driverName[[:space:]]*=[[:space:]]*//p' |
         sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  chk "Vulkan driver is not llvmpipe" yes \
      "$(case "${_icd:-none}" in *llvmpipe*|none) echo no ;; *) echo yes ;; esac)"
  note "  ICD" "${_icd:-<none>}"
fi
note "GPU" "$(lspci -nn 2>/dev/null | sed -n 's/.*\(VGA compatible controller\|3D controller\)[^:]*: //p' | head -1)"

step "Memory pressure defences"
chk "vm.swappiness"              180      "$(sysctl -n vm.swappiness 2>/dev/null)"
# NB: not decoration. When the check above fails it is almost never sysctl's
# fault - CachyOS's /usr/lib/udev/rules.d/30-zram.rules sets swappiness=150 on
# every zram0 `change` event, which happens after `sysctl --system` at boot. So
# report whether our counter-rule is actually installed; that is the difference
# between "the config is wrong" and "the config is right and udev overruled it".
note "  swappiness udev override" "$([ -f /etc/udev/rules.d/99-zram-swappiness.rules ] &&
    echo installed || echo 'MISSING - run sudo ./system/apply.sh')"
chk "vm.page-cluster"            0        "$(sysctl -n vm.page-cluster 2>/dev/null)"
chk "kernel.sysrq"               1        "$(sysctl -n kernel.sysrq 2>/dev/null)"
chk "fs.inotify.max_user_watches" 524288  "$(sysctl -n fs.inotify.max_user_watches 2>/dev/null)"
# NB: is-active alone passes for a unit someone hand-started this boot. On Arch,
# where the default preset is `disable *` and nothing is on by default, enabled
# vs. active is the whole point - a machine that passes today and forgets after
# a reboot is exactly the failure this check exists to catch.
chk "systemd-oomd active"        active   "$(systemctl is-active systemd-oomd 2>/dev/null)"
chk "systemd-oomd enabled"       enabled  "$(systemctl is-enabled systemd-oomd 2>/dev/null || echo disabled)"
chk "earlyoom active"            active   "$(systemctl is-active earlyoom 2>/dev/null)"
chk "earlyoom enabled"           enabled  "$(systemctl is-enabled earlyoom 2>/dev/null || echo disabled)"
# NB: verify earlyoom's arguments from the KERNEL, not from the file we wrote.
# The whole reason the args live in an ExecStart= drop-in rather than
# /etc/default/earlyoom is that EnvironmentFile= silently overrides Environment=
# - so a config that looks perfect can be entirely ignored while the unit still
# reports "active". The live argv is the only honest source.
_eopid=$(systemctl show -p MainPID --value earlyoom 2>/dev/null)
_eoargs=$(tr '\0' ' ' < "/proc/${_eopid:-0}/cmdline" 2>/dev/null)
chk "earlyoom --avoid live"      yes "$(case "$_eoargs" in *--avoid*) echo yes;; *) echo no;; esac)"
chk "earlyoom protects plasmashell" yes "$(case "$_eoargs" in *plasmashell*) echo yes;; *) echo no;; esac)"
# NB: zram was only a note before, so a completely dead zram setup passed clean.
chk "zram is swap"               yes "$(swapon --show=NAME --noheadings 2>/dev/null | grep -q zram && echo yes || echo no)"
note "zram" "$(zramctl --noheadings --output NAME,DISKSIZE,DATA,TOTAL 2>/dev/null | tr -s ' ')"
note "zram ratio" "$(awk '{if($2>0) printf "%.2f:1", $1/$2}' /sys/block/zram0/mm_stat 2>/dev/null)"
# NB: match only *actual* kills. 'earlyoom.*sending' also matched earlyoom's
# startup banner, which it logs once per boot - so this reported "7 kills" on a
# machine that had never been OOM-killed. A real kill names the process.
note "OOM kills, last 7d" "$(journalctl --since '7 days ago' 2>/dev/null | grep -cE 'earlyoom.*sending SIG(TERM|KILL) to process|oomd.*Killed .*due to memory pressure|Killed process [0-9]')"

step "Disk growth caps"
chk "journald cap present"       yes "$([ -f /etc/systemd/journald.conf.d/99-size-cap.conf ] && echo yes || echo no)"
note "journal on disk" "$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[MG]' | head -1)"
chk "coredump cap present"       yes "$([ -f /etc/systemd/coredump.conf.d/99-size-cap.conf ] && echo yes || echo no)"
# NB: plain `du` FIRST. /var/lib/systemd/coredump is often world-readable and
# empty, in which case this needs no privilege at all - the old `sudo -n du`
# reported "<needs root>" on a machine where `du` alone answers "0" instantly.
# Ask for privilege only after the cheap path fails.
note "coredumps on disk" "$(du -sh /var/lib/systemd/coredump 2>/dev/null | cut -f1 ||
    sudo -n du -sh /var/lib/systemd/coredump 2>/dev/null | cut -f1 ||
    echo '<needs root: sudo du -sh /var/lib/systemd/coredump>')"
note "pacman cache" "$(du -sh /var/cache/pacman/pkg 2>/dev/null | cut -f1)"
note "orphan packages" "$(pacman -Qtdq 2>/dev/null | wc -l)"
# NB: an unmerged .pacnew for pacman.conf, sudoers or mkinitcpio.conf is how the
# machine breaks weeks later with no error at the time. This is a maintenance
# responsibility Fedora never imposed.
# NB: print the NAMES, not just a count. "6" tells you there is homework;
# it does not tell you that one of them is pacman.conf and the other five are
# mirrorlists, which is the difference between "merge this carefully" and
# "overwrite it". Merge with: sudo DIFFPROG=nvim pacdiff  (pacman-contrib)
_pacnew=$(find /etc -name '*.pacnew' 2>/dev/null | sort)
note "/etc .pacnew files" "$(echo "$_pacnew" | grep -c .)"
if [ -n "$_pacnew" ]; then
  echo "$_pacnew" | while read -r f; do note "  $(basename "$f" .pacnew)" "${f%.pacnew}"; done
  note "  merge with" "sudo pacdiff   (pacman-contrib)"
fi

step "Shell + CLI config"
# ONE interactive zsh for this whole section, not one per check. `zsh -ic` is
# not cheap - it sources OMZ, four plugins and compinit - and this used to spawn
# a second one just to time the first. Time the startup once and reuse that same
# shell to answer everything that needs a real interactive environment.
_zsh_start=$( { TIMEFORMAT=%R; time zsh -ic 'fd --version >/dev/null 2>&1 && echo FD_OK' ; } 2>&1 )
chk "fd on PATH"                 ok  "$(case "$_zsh_start" in *FD_OK*) echo ok;; *) echo broken;; esac)"
chk "starship palette active"    yes "$(grep -q '^palette' ~/.config/starship.toml 2>/dev/null && echo yes || echo no)"
chk "ZSH_THEME empty"            yes "$(grep -q '^ZSH_THEME=""' ~/.zshrc 2>/dev/null && echo yes || echo no)"
chk "bat config exists"          yes "$([ -f ~/.config/bat/config ] && echo yes || echo no)"
# NB: PATH must not grow on re-source. dot_zshrc prepends through path_prepend()
# for exactly this reason; a duplicate here means a bare `export PATH=` crept
# back in.
chk "no duplicate PATH entries"  ok  "$(zsh -ic 'print -r -- $PATH' 2>/dev/null |
    tr ':' '\n' | sort | uniq -d | grep -q . && echo "duplicates" || echo ok)"
# Report load and CPU clock alongside: startup time swings 5x between an idle
# machine (~0.09s) and load>6 with the CPU parked at 800 MHz (~0.45s). Without
# this context the number looks like a regression when it isn't.
note "zsh startup" "$(echo "$_zsh_start" | tail -1)s"
note "  load avg / CPU MHz" "$(cut -d' ' -f1-3 /proc/loadavg) / $(awk '/cpu MHz/{s+=$4;n++} END{printf "%.0f", s/n}' /proc/cpuinfo)"

step "Fonts"
# THIS SECTION EXISTS BECAUSE THE FONT WAS WRONG FOR WEEKS AND NOTHING SAID SO.
# Ghostty, VS Code, fontconfig and the KDE theme script all asked for "Cascadia
# Code NF". The installed package (ttf-cascadia-code-nerd) registers the family
# as "CaskaydiaCove Nerd Font" - Nerd Fonts renames Cascadia Code when it
# patches it. fontconfig does not fail on an unknown family, it SUBSTITUTES:
#     fc-match 'Cascadia Code NF'  ->  AdwaitaSans-Regular.ttf
# so the terminal ran on a proportional sans and every config file looked
# correct. There is no error to grep for anywhere - the only honest test is to
# ask fontconfig what a family actually resolves to.
_mono_family='CaskaydiaCove Nerd Font'
# NB: match on the FILE, not on fc-match's family output. Asking for a missing
# family and getting a different family back is precisely the bug; comparing
# the returned family to itself would pass on the substitute.
chk "mono font resolves"         yes "$(case "$(fc-match -f '%{file}' "$_mono_family" 2>/dev/null)" in
    *Caskaydia*) echo yes;; *) echo no;; esac)"
note "  '$_mono_family'" "$(fc-match "$_mono_family" 2>/dev/null | cut -d: -f1)"
# The generic families are what every app that does not name a font gets.
# fonts.conf prepends to both; if a prepend is not landing this is where it
# shows, and it is a different failure from the family above being missing.
chk "monospace -> Caskaydia"     yes "$(case "$(fc-match -f '%{file}' monospace 2>/dev/null)" in
    *Caskaydia*) echo yes;; *) echo no;; esac)"
chk "sans-serif -> Adwaita"      yes "$(case "$(fc-match -f '%{file}' sans-serif 2>/dev/null)" in
    *Adwaita*) echo yes;; *) echo no;; esac)"
# NB: kdeglobals is Plasma's copy of the same decision and drifts independently
# - System Settings can change it without touching fonts.conf. A mismatch here
# means the desktop and the terminal disagree about what "monospace" is.
if command -v kreadconfig6 >/dev/null 2>&1; then
  chk "KDE fixed font"           "$_mono_family" \
      "$(kreadconfig6 --file kdeglobals --group General --key fixed 2>/dev/null | cut -d, -f1)"
fi

step "Lock screen"
# The lock screen has two theming surfaces and both are checked, because the
# failure is invisible until you actually lock the machine.
#
# Colours are inherited: kscreenlocker_greet renders with the Plasma style from
# plasmarc, and the default style ships no `colors` file, which means "follow
# the system colour scheme". So the ColorScheme check IS the lock screen's
# colour check - there is no second key to read.
chk "colour scheme"              CatppuccinLatteBlue \
    "$(kreadconfig6 --file kdeglobals --group General --key ColorScheme 2>/dev/null)"
# The wallpaper is NOT inherited. Left unset the greeter falls back to Plasma's
# stock "Next", which is how the desktop ends up Catppuccin and the lock screen
# does not. Written by .chezmoiscripts/run_onchange_after_20-kde-theme.sh.
_lockwall=$(kreadconfig6 --file kscreenlockerrc \
    --group Greeter --group Wallpaper --group org.kde.image --group General \
    --key Image 2>/dev/null)
chk "lock wallpaper set"         yes "$(case "$_lockwall" in
    *Catppuccin*) echo yes;; '') echo unset;; *) echo "other";; esac)"
# NB: the key can name a file that is not there - the greeter then falls back
# silently, same visible result as unset. Check the path, not just the key.
chk "lock wallpaper on disk"     yes "$([ -n "$_lockwall" ] && [ -f "${_lockwall#file://}" ] && echo yes || echo no)"

step "Desktop session"
chk "compositor"                 kwin_wayland "$(pgrep -x kwin_wayland >/dev/null && echo kwin_wayland || echo none)"
chk "plasmashell running"        yes "$(pgrep -x plasmashell >/dev/null && echo yes || echo no)"
note "plasma session (PSS)" "$(for p in $(pgrep -f 'plasmashell|kwin_wayland|kded6|krunner|plasma-|xdg-desktop-por' 2>/dev/null); do
    awk '/^Pss:/{print $2}' "/proc/$p/smaps_rollup" 2>/dev/null; done |
    awk '{s+=$1} END {printf "%.2f GiB", s/1048576}')"

step "Idle-service reclaim"
# These exist again under Plasma, so they are checks rather than history. See
# docs/SETUP-GUIDE.md Layer 5 for what each one costs.
chk "akonadi processes"          0        "$(pgrep -c akonadi 2>/dev/null || true)"
# NB: `balooctl6 status` EXITS 1 when baloo is disabled, so under `set -o pipefail`
# a piped grep reports a false negative. Capture the output, then test it. And a
# MISSING balooctl6 must not read as "enabled" - that was a false failure when
# this repo briefly targeted a session with no KDE at all.
if ! command -v balooctl6 >/dev/null 2>&1; then
  ok "baloo not installed"
else
  _baloo=$(balooctl6 status 2>&1 || true)
  chk "baloo file indexer"       disabled "$(case "$_baloo" in *"currently disabled"*) echo disabled;; *) echo enabled;; esac)"
fi
# NB: `systemctl is-enabled` EXITS 1 for a masked unit even though it prints
# "masked", so `|| echo unknown` appended a second line and the compare could
# never match. Capture the output and ignore the status - same trap as baloo.
#
# NB: NOT-INSTALLED IS A PASS. This used to `chk ... masked "not-found"` and so
# reported a hard failure on a machine that is in the BEST possible state -
# PackageKit absent entirely, nothing to mask, 0 MB resident. scripts/reclaim.sh
# has always got this right ("packagekit not installed" -> ok); doctor did not,
# and a permanently-red check that everyone learns to ignore is worse than no
# check. Same shape as the balooctl6 guard above: absent tool, absent problem.
if ! pacman -Qq packagekit >/dev/null 2>&1; then
  ok "packagekit not installed"
else
  _pk=$(systemctl is-enabled packagekit 2>/dev/null)
  chk "packagekit"               masked   "${_pk:-unknown}"
fi
note "reclaim targets resident" "$(ps -eo rss,comm --no-headers | grep -iE 'akonadi|packagekitd|Discover|baloo' | grep -v grep | awk '{s+=$1} END {printf "%.0f MB", s/1024}')"

step "VS Code"
S="$HOME/.config/Code - Insiders/User/settings.json"
for k in files.watcherExclude search.exclude typescript.tsserver.maxTsServerMemory extensions.autoUpdate; do
  chk "$k" present "$(grep -qF "\"$k\"" "$S" 2>/dev/null && echo present || echo MISSING)"
done
note "extensions installed" "$(ls ~/.vscode-insiders/extensions 2>/dev/null | grep -vc '^\.')"
note "extensions on disk" "$(du -sh ~/.vscode-insiders/extensions 2>/dev/null | cut -f1)"

step "Browser (Brave Origin)"
chk "brave-origin installed"     yes "$(command -v brave-origin >/dev/null && echo yes || echo no)"
_bvpids=$(pgrep -f '/opt/brave\.com/brave-origin' 2>/dev/null)
if [ -z "$_bvpids" ]; then
  note "brave" "not running"
else
  # NB: CORRECTION, 2026-09-04, and the most important line in this section.
  # This used to enumerate Brave's cgroups and then filter them with
  # `grep '\.scope$'`. Brave does not run only as scopes. Plasma launches it as
  # app-brave\x2dorigin@<hex>.SERVICE, and 35 of its 37 processes stay there -
  # GPU, all three zygotes, the utility processes, crashpad and every renderer.
  # The filter dropped that cgroup, so "cap on every brave scope" reported ok
  # against the single 2-process scope that WAS capped, while 3.4 GiB of Brave
  # sat uncapped in app.slice. A green light on the exact check that was added
  # to prove the cap works.
  #
  # So: never filter this list by unit type. Whatever cgroup Brave's processes
  # are in is a cgroup that needs a ceiling, whether it is a scope, a service,
  # or something Chromium invents next.
  _bvcg=$(for p in $_bvpids; do cut -d: -f3 "/proc/$p/cgroup" 2>/dev/null; done | sort -u)
  # Widen from "processes whose argv matches the binary path" to "every process
  # in the cgroups those live in". That is what the caps actually apply to, and
  # it picks up the /usr/bin/brave-origin-stable wrapper shell that the path
  # match misses. Deriving it from the cgroups rather than a looser pgrep also
  # avoids matching an unrelated shell that merely mentions "brave-origin".
  _bvpids=$(for c in $_bvcg; do cat "/sys/fs/cgroup$c/cgroup.procs" 2>/dev/null; done |
      sort -un)
  note "processes" "$(echo "$_bvpids" | grep -c .)"
  note "cgroups in use" "$(for c in $_bvcg; do echo "${c##*/}"; done | tr '\n' ' ')"
  # NB: PSS, never RSS. RSS counts every shared page in full against every
  # process mapping it, so a 30-process Chromium double-counts its shared
  # runtime ~30 times. PSS divides each shared page by its sharer count.
  note "brave total (PSS)" "$(for p in $_bvpids; do
      awk '/^Pss:/{print $2}' "/proc/$p/smaps_rollup" 2>/dev/null; done |
      awk '{s+=$1} END {printf "%.2f GiB", s/1048576}')"
  # HOW BRAVE IS CAPPED, since the mechanism is not obvious:
  #   app-brave\x2dorigin@<hex>.service is a TEMPLATE instance, so the drop-in
  #     dir app-brave\x2dorigin@.service.d/ reaches it whatever the hex is.
  #   app-org.chromium.Chromium-<PID>.scope is not a template, but systemd's
  #     DASH-TRUNCATION drop-in search is a separate feature and reaches it:
  #     systemd.unit(5) - "for a unit name foo-bar-baz.service not only the
  #     regular drop-in directory foo-bar-baz.service.d/ is searched but also
  #     both foo-bar-.service.d/ and foo-.service.d/".
  # Both drop-ins live in home/private_dot_config/systemd/user/ with the full
  # derivation. Both set Slice=browser.slice, which is what makes the slice a
  # real aggregate ceiling rather than N separate 6G ceilings.
  #
  # Two separate checks, because they fail independently and for different
  # reasons:
  #   MemoryHigh reaches an ALREADY-RUNNING Brave on daemon-reload.
  #   Slice= binds only cgroups created AFTER the drop-in landed, because a live
  #   cgroup cannot be re-parented. So a Brave that was already running when
  #   this was installed passes the first and fails the second until it is
  #   restarted - expected, and exactly why the per-cgroup MemoryHigh exists
  #   instead of relying on the slice alone.
  chk "cap on every brave cgroup"  ok "$(
      _bad=0; _n=0
      for c in $_bvcg; do
        _n=$((_n+1))
        [ "$(systemctl --user show "${c##*/}" -p MemoryHigh --value 2>/dev/null)" = 6442450944 ] ||
          _bad=$((_bad+1))
      done
      if   [ "$_n"   -eq 0 ]; then echo "no cgroups found"
      elif [ "$_bad" -eq 0 ]; then echo ok
      else echo "$_bad/$_n uncapped"; fi)"
  chk "browser.slice ceiling"      6442450944 \
      "$(systemctl --user show browser.slice -p MemoryHigh --value 2>/dev/null)"
  # Not a chk: fails benignly until the next Brave restart, see the NB above.
  note "cgroups in the slice" "$(
      _in=0; _n=0
      for c in $_bvcg; do
        _n=$((_n+1))
        case "$c" in */browser.slice/*) _in=$((_in+1));; esac
      done
      if [ "$_n" -gt 0 ] && [ "$_in" -eq "$_n" ]; then echo "$_in/$_n"
      else echo "$_in/$_n (restart brave to re-parent the rest)"; fi)"
fi

# ── desktop machine only ─────────────────────────────────────────────────────
# NB: gated rather than guarded-per-check. On the laptop these are not "things
# that failed", they are things that do not exist, and a section full of
# permanently-grey notes is the kind of noise that teaches people to skim the
# report. UI_STEPS above accounts for the two extra steps.
if [ "$PROFILE" = desktop ]; then

step "Desktop hardware"
# NB: the MODULE PARAMETER, not /etc/modprobe.d. The file being present proves
# nothing: it only reaches amdgpu if mkinitcpio's modconf hook copied it into
# the initramfs, and if it did not, LACT opens, shows plausible numbers, and
# silently cannot change the fan curve.
if [ "$GPU" = amd ]; then
  _ppf=$(cat /sys/module/amdgpu/parameters/ppfeaturemask 2>/dev/null || echo '')
  chk "amdgpu ppfeaturemask" 0xffffffff \
      "$(if [ -n "$_ppf" ] && [ "$(printf '%d' "$_ppf" 2>/dev/null || echo 0)" -eq 4294967295 ]
         then echo 0xffffffff; else echo "${_ppf:-<unreadable>}"; fi)"
  # The knob LACT actually writes. Present only when the mask above took.
  chk "GPU power-management sysfs" present \
      "$(ls /sys/class/drm/card*/device/pp_od_clk_voltage >/dev/null 2>&1 &&
         echo present || echo MISSING)"
  # NB: capture, then default - do NOT append `|| echo not-found`. For a unit
  # that does not exist, `systemctl is-enabled` PRINTS "not-found" and EXITS 1,
  # so the || branch fires too and chk gets a two-line value it can never
  # match. Identical trap to the packagekit and baloo checks further down.
  _lactd=$(systemctl is-enabled lactd.service 2>/dev/null)
  chk "lactd enabled" enabled "${_lactd:-not-found}"
fi

# NB: loaded is NOT the same as bound. nct6687 inserts happily on a board
# without the chip and then reports nothing at all, so read SENSORS back rather
# than lsmod. A fan RPM is the only honest proof the driver found hardware.
if lsmod 2>/dev/null | grep -q '^nct6687'; then
  ok "nct6687 module loaded"
else
  chk "nct6687 module loaded" yes no
fi
_fans=$(sensors 2>/dev/null | grep -ciE '^fan[0-9]+:' || true)
chk "board reports fan RPM" yes "$([ "${_fans:-0}" -gt 0 ] && echo yes || echo no)"
note "  fans seen" "${_fans:-0}"
# Tctl is the AMD die sensor (k10temp). Fall back to whatever the first
# reported package/core temperature is, so this is never a blank line.
_temp=$(sensors 2>/dev/null |
        sed -n 's/^\(Tctl\|Tdie\|Package id 0\|Core 0\):[[:space:]]*+\([0-9.]*\).*/\2 C/p' |
        head -1)
note "CPU temp" "${_temp:-<no sensor - is lm_sensors configured?>}"

# NB: the 1 TB storage disk is kept as NTFS on purpose, and ntfs3 mounts a
# volume READ-ONLY rather than failing when Windows left it dirty (hibernation
# or Fast Startup). That is silent: writes just start bouncing. Discover the
# mounts at runtime so no UUID or label ever enters this public repo.
_ntfs=$(findmnt -rno TARGET,OPTIONS -t ntfs3,ntfs,fuseblk 2>/dev/null || true)
if [ -z "$_ntfs" ]; then
  note "NTFS mounts" "<none mounted>"
else
  while read -r _t _o; do
    [ -n "$_t" ] || continue
    chk "NTFS $_t writable" rw \
        "$(case ",$_o," in *,rw,*) echo rw ;; *) echo ro ;; esac)"
  done <<< "$_ntfs"
fi

step "Gaming & creative stack"
# NB: multilib is checked against the LIVE repo list, not against pacman.conf.
# A commented-out multilib does not error at bootstrap - the lib32 names simply
# get dropped by the "not in any repo" filter with one warning, and the failure
# surfaces weeks later as a game rendering on the CPU.
chk "multilib enabled" yes \
    "$(pacman-conf --repo-list 2>/dev/null | grep -qx multilib && echo yes || echo no)"

# The 32-bit half of the Vulkan stack. A 64-bit-only install runs Steam fine
# and then falls back to llvmpipe for every 32-bit title.
if [ "$GPU" = amd ]; then
  chk "32-bit RADV ICD" present \
      "$([ -e /usr/share/vulkan/icd.d/radeon_icd.i686.json ] && echo present || echo MISSING)"
  chk "32-bit RADV library" present \
      "$(ldconfig -p 2>/dev/null | grep -q 'libvulkan_radeon.so.*libc6,x86-32' &&
         echo present || echo MISSING)"
fi

chk "steam installed" yes "$(command -v steam >/dev/null && echo yes || echo no)"
chk "gamemode user unit" present \
    "$(systemctl --user list-unit-files gamemoded.service >/dev/null 2>&1 &&
       systemctl --user list-unit-files gamemoded.service 2>/dev/null |
       grep -q gamemoded && echo present || echo MISSING)"
# NB: NOT `gamemoded -s`. That query D-Bus-activates the daemon if it is not
# running, which would make this script change something - the one thing it
# promises never to do. Name the command instead; run it while a game is up.
note "  live check" "gamemoded -s   (run it with a game running)"

# NB: a Steam library on the storage disk is a trap worth catching. Steam does
# not support NTFS: Proton breaks on its case-insensitivity and missing symlink
# support, usually as a game that installs fine and then will not launch.
while read -r _t _o; do
  [ -n "$_t" ] || continue
  if [ -d "$_t/steamapps" ] || [ -d "$_t/SteamLibrary" ]; then
    chk "no Steam library on NTFS ($_t)" ok FOUND-ONE
  fi
done <<< "$(findmnt -rno TARGET,OPTIONS -t ntfs3,ntfs,fuseblk 2>/dev/null || true)"

# DaVinci Resolve lives or dies on this single line. AMD dropped Polaris from
# ROCm after 5.7 and the repos ship 7.x, which enumerates no device at all.
if ! command -v clinfo >/dev/null 2>&1; then
  note "OpenCL" "<clinfo not installed: pacman -S clinfo>"
else
  _cl=$(ROC_ENABLE_PRE_VEGA=1 clinfo -l 2>/dev/null | grep -c 'Device' || true)
  chk "OpenCL device visible" yes "$([ "${_cl:-0}" -gt 0 ] && echo yes || echo no)"
  note "  devices" "${_cl:-0} (Resolve needs at least 1 - see scripts/resolve-opencl.sh)"
fi
# NB: and check the PIN is still on. A pacman -Syu that quietly upgraded the
# runtime back to 7.x is exactly how this breaks again six months from now, so
# read IgnorePkg out of the LIVE parsed config rather than grepping the file.
if pacman -Qq rocm-opencl-runtime >/dev/null 2>&1; then
  note "rocm-opencl-runtime" "$(pacman -Q rocm-opencl-runtime 2>/dev/null | awk '{print $2}')"
  chk "ROCm held at the pinned version" yes \
      "$(pacman-conf IgnorePkg 2>/dev/null | grep -qx rocm-opencl-runtime && echo yes || echo no)"
fi

fi

step "Rollback safety"
chk "snapper installed"          yes "$(command -v snapper >/dev/null && echo yes || echo no)"
chk "snap-pac installed"         yes "$(pacman -Qq snap-pac >/dev/null 2>&1 && echo yes || echo no)"
# NB: `command -v snapper` passes on a box with the binary and zero configs,
# which is no rollback net at all. Count actual snapshots.
# NB: `grep -c` PRINTS 0 and EXITS 1 when nothing matches, so a naive
# `grep -c ... || echo '<needs root>'` runs both branches and prints two lines.
#
# NB: and the ${_snaps:-<needs root>} fallback below could never fire, which is
# how this reported a confident "0" on a machine with no passwordless sudo.
# `sudo -n` fails, the pipeline still succeeds, `grep -c` prints 0, and 0 is not
# empty - so the fallback was dead code and "no rollback net at all" and "I was
# not allowed to look" printed identically. Ask sudo first, then count.
# NB: check the CONFIG, not just the binary. `command -v snapper` passes on a
# box with the binary and zero configs, which is no rollback net at all - and
# unlike the snapshot count, /etc/snapper/configs/ is world-readable, so this
# is a real check rather than a note that gives up without privilege.
chk "snapper config present"     yes \
    "$(ls /etc/snapper/configs/ 2>/dev/null | grep -q . && echo yes || echo no)"
note "  configs" "$(ls /etc/snapper/configs/ 2>/dev/null | tr '\n' ' ')"
# The COUNT is the one thing here that genuinely needs privilege: snapper's
# ALLOW_USERS/ALLOW_GROUPS are empty by default, so a normal user gets "No
# permissions." - not an empty list, an error. Name the exact command rather
# than telling anyone to re-run this whole script as root; see the guard at the
# top of the file for why that advice was actively harmful.
if sudo -n true 2>/dev/null; then
  note "root snapshots" "$(sudo -n snapper -c root list 2>/dev/null | grep -cE '^[0-9]')"
else
  note "root snapshots" "<needs root: sudo snapper -c root list>"
fi

steps_end
bar "$pass" $(( pass + fail )) "checks passed"
# The exit status is the contract - the bar above is decoration on top of it.
[ "$fail" -eq 0 ]
