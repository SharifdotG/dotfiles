#!/usr/bin/env bash
# Health check. Read-only: reports, never changes anything.
set -uo pipefail
cd "$(dirname "$0")/.."
. lib/log.sh
. lib/detect.sh
. lib/pkg.sh
. lib/sensors.sh
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
# 14 since the unwanted-packages section landed.
UI_STEPS=14
[ "$PROFILE" = desktop ] && UI_STEPS=$(( UI_STEPS + 2 ))
banner "doctor" "read-only health check · reports, never changes anything"
info "System: $DISTRO / $DESKTOP / $SESSION_TYPE  (vm: $IS_VM, pkg column: $PKG_COL, ${_uarch:-?})"
info "Machine: profile=$PROFILE / cpu=$CPU_VENDOR / gpu=$GPU / hw-tuning=$HW_TUNING"

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

# NB: chezmoi bakes `profile` AND `gpu` into ~/.config/chezmoi/chezmoi.toml at
# init and never re-reads the hardware, so a config carried over from the other
# machine - or restored from a backup, see docs/BACKUP.md - keeps the OLD answer
# forever. Compare BOTH stored values against a live read. This is the house
# rule applied to the profile mechanism itself.
#
# NB: `gpu` going stale is silent - LIBVA_DRIVER_NAME is then wrong and VA-API
# just stops. `profile` going stale is WORSE, because it makes the machine
# disagree with ITSELF: bootstrap.sh asks lib/detect.sh and installs gaming.tsv
# and creative.tsv, while home/.chezmoiignore asks chezmoi's stored copy and
# SKIPS .config/MangoHud and .config/gamemode.ini. The result is gamemode and
# MangoHud installed with no configuration at all - and MangoHud's config is the
# llvmpipe tripwire, so the one thing that would have shown you the GPU had been
# silently substituted is the thing that goes missing. Only `gpu` was checked
# here for a while, which is why this NB is longer than the code.
#
# NB: re-running `chezmoi init --promptString profile=...` does NOT repair a
# WRONG value - promptStringOnce returns the stored value whenever the key
# exists, and --promptString only pre-populates prompts that are actually asked.
# bootstrap.sh rewrites the key in place for that reason; see the note there.
_cmtoml="${XDG_CONFIG_HOME:-$HOME/.config}/chezmoi/chezmoi.toml"
_baked() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\(.*\)\"[[:space:]]*\$/\1/p" \
    "$_cmtoml" 2>/dev/null | head -1
}
_bakedprofile=$(_baked profile)
_bakedgpu=$(_baked gpu)
if [ -z "$_bakedprofile" ]; then
  note "chezmoi .profile" "<not set - run: chezmoi init --source \"$PWD\">"
else
  chk "chezmoi .profile matches hardware" "$PROFILE" "$_bakedprofile"
fi
if [ -z "$_bakedgpu" ]; then
  note "chezmoi .gpu" "<not set - run: chezmoi init --source \"$PWD\">"
else
  chk "chezmoi .gpu matches hardware" "$GPU" "$_bakedgpu"
fi

# NB: the THIRD baked value, and the one that breaks loudest while being checked
# least. sourceDir is written once at `chezmoi init` and never revisited, so
# MOVING the repo leaves every bare chezmoi command - apply, diff, status, add,
# re-add, update - pointing at a directory that no longer exists. bootstrap.sh
# hides it completely, because it always passes --source "$REPO"; the breakage
# surfaces only the first time you run chezmoi by hand, which is the moment you
# are least willing to suspect the tool. .chezmoi.toml.tmpl predicted this in
# the comment above the key ("Move the repo and re-run chezmoi init --source
# <new path>") and then nothing ever checked it - which is the same shape as
# `profile` being unchecked above. Found live, on this laptop, by running
# `chezmoi status` after the repo moved out of ~/Documents/Code.
#
# NB: doctor.sh cd's to the repo root on line 4, so $PWD IS the repo and
# $PWD/home is the expected value exactly (sourceDir stores the post-.chezmoiroot
# path). Compare rather than merely testing -d, so a config pointing at a
# DIFFERENT but existing checkout is still caught.
_bakedsrc=$(_baked sourceDir)
if [ -z "$_bakedsrc" ]; then
  note "chezmoi sourceDir" "<not set - run: chezmoi init --source \"$PWD\">"
else
  chk "chezmoi sourceDir is this repo" "$PWD/home" "$_bakedsrc"
  [ "$_bakedsrc" = "$PWD/home" ] ||
    note "  fix" "chezmoi init --source \"$PWD\"$([ -d "$_bakedsrc" ] || echo '   (stored path does not exist)')"
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

# NB: a note, not a chk, and deliberately so - the scale is a preference, not a
# defect. Nothing else in this repo ever reads it back, and it is printed here
# because Plasma multiplies every point size AND the cursor size by it, so it is
# the difference between "10 pt" as written and what actually lands on glass.
#
# CORRECTION, 2026-09-05. This used to say three templates "silently depend" on
# the scale, branching on .profile with a 1.25-vs-1.00 split - ghostty at
# font-size 10 vs 12, the kde-theme script at 10/24 vs 12/32, and fontconfig.
# That is no longer true and it was already half wrong when written:
#   - ghostty and kde-theme were reverted to one flat set of values on both
#     machines (Plasma's own defaults: 10/9/10 pt, 24 px cursor). Equal PHYSICAL
#     size across the two machines was the thing the split bought, and it turned
#     out not to be wanted - see the long note in the kde-theme script.
#   - fontconfig branches on .profile but both arms emit the SAME rasterisation
#     values; only the explanatory comment differs. It never depended on the
#     scale at all.
# So changing the scale in System Settings no longer makes any template wrong -
# it just makes everything bigger or smaller together, which is the honest knob
# for that and is now what the kde-theme script tells you to reach for.
#
# NB: kwinoutputconfig.json, not kdeglobals - under Wayland the scale is per
# OUTPUT and kdeglobals carries nothing. Multiple values mean mixed-DPI outputs.
_scale=$(grep -o '"scale"[[:space:]]*:[[:space:]]*[0-9.]*' \
         "${XDG_CONFIG_HOME:-$HOME/.config}/kwinoutputconfig.json" 2>/dev/null |
         sed 's/.*:[[:space:]]*//' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')
case "$PROFILE" in
  laptop)  _want=1.25 ;;
  desktop) _want=1 ;;
  *)       _want='?' ;;
esac
# NB: "usual", not "assumed". No template reads this any more (see the
# correction above); it is the value each machine has been set to, printed so a
# scale that changed by accident is visible rather than inferred from "the
# desktop looks off today".
note "Plasma scale" "${_scale:-<unknown>} (usual for profile=$PROFILE: $_want)"

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
chk "zram is swap"               yes "$(swapon --show=NAME --noheadings 2>/dev/null | grep zram >/dev/null && echo yes || echo no)"
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

step "Unwanted packages"
# packages/unwanted.tsv is only half a contract if nothing ever checks the other
# side of it. bootstrap.sh removes these; this is what catches them coming BACK -
# pulled in as a dependency of something new, or reinstalled by hand during some
# debugging session and then forgotten. Neither leaves a trace anywhere else.
_unwanted=$(for u in $(pkg_resolve arch packages/unwanted.tsv); do
    pacman -Qq "$u" >/dev/null 2>&1 && printf '%s ' "$u"
  done)
if [ -z "$_unwanted" ]; then
  chk "unwanted packages absent"  yes yes
else
  # Names, not a count. The fix is `./bootstrap.sh`, and knowing WHICH package
  # came back is what tells you whether that is even the right answer.
  chk "unwanted packages absent"  yes "installed: ${_unwanted% }"
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
    tr ':' '\n' | sort | uniq -d | grep . >/dev/null && echo "duplicates" || echo ok)"
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

# NB: THE CHECK THAT WAS MISSING, AND THE ONE THAT MATTERS MOST HERE.
# Everything above asks WHICH font answers a name. None of it asks HOW that
# font is rasterised - and on 2026-09-05 this machine was found rendering with
# hinting and subpixel antialiasing switched OFF, while every config file in the
# repo said hintslight + rgb, and this script reported 40/40.
#
# Cause: Plasma's Fonts settings module (kcm_fonts.so) re-serialises
# ~/.config/fontconfig/fonts.conf and APPENDS its own <match target="font">
# block rather than replacing one. There were 33 of them where chezmoi writes 1,
# and target="font" edits all fire in document order, so Plasma's had the last
# word. `chezmoi status` showed the drift; nothing read it.
#
# So: read the values fontconfig actually RESOLVES, never the file.
#   hintstyle 0=none 1=slight 2=medium 3=full   rgba 0=unknown 1=rgb 2=bgr
#                                               3=vrgb 4=vbgr 5=none
_rast=$(fc-match -f '%{hintstyle} %{hinting} %{rgba} %{antialias}' sans-serif 2>/dev/null)
chk "font rasterisation (effective)" "1 True 1 True" "${_rast:-<unreadable>}"
# The count is the tell, and it names the culprit when the line above goes red.
# NB: anchored to a line that is ONLY the opening tag. The obvious
# `grep -c 'match target="font"'` also counts the string where it appears inside
# this repo's own explanatory comments in that file - which made this check
# report 3 immediately after a clean apply that had written exactly 1. A check
# that counts its own documentation is worse than no check.
_fcblocks=$(grep -cE '^[[:space:]]*<match target="font">[[:space:]]*$' \
            "${XDG_CONFIG_HOME:-$HOME/.config}/fontconfig/fonts.conf" 2>/dev/null || echo 0)
chk "fontconfig font blocks"     1 "${_fcblocks:-0}"
note "  if that is not 1" "System Settings > Fonts appended to it; 'chezmoi apply' restores it"

# NB: escape the hyphen. fc-match parses its argument as a font PATTERN, in
# which an unescaped "-" starts the size/style section - so `fc-match
# ui-monospace` asks for the family "ui", matches nothing, substitutes a
# proportional sans, and looks exactly like a broken alias. It is not. Verified
# with FC_DEBUG=4, which prints the request pattern as family: "ui".
chk "ui-monospace -> Caskaydia"  yes "$(case "$(fc-match -f '%{file}' 'ui\-monospace' 2>/dev/null)" in
    *Caskaydia*) echo yes;; *) echo no;; esac)"

# GitHub asks for these two by name. Absent, its CSS falls through its own stack
# to Noto Sans and Liberation Mono. Check the FILE, not the family: a missing
# family does not error, it substitutes - the CaskaydiaCove lesson above.
for _f in "Mona Sans:Mona" "Monaspace Neon:Monaspace"; do
  chk "${_f%%:*} resolves"       yes "$(case "$(fc-match -f '%{file}' "${_f%%:*}" 2>/dev/null)" in
      *"${_f##*:}"*) echo yes;; *) echo no;; esac)"
done

step "Desktop theme"
# NB: everything here reads the LIVE key, never the script that wrote it. The
# specific failure this guards against: applying a Global Theme writes that
# package's contents/defaults into ~/.config/kdedefaults/, and Catppuccin's
# carries an Aurorae decoration and its own cursors - the two pieces
# deliberately NOT wanted. The theme script re-asserts them in ~/.config/
# afterwards, which outranks kdedefaults. If that re-assert ever stops running,
# nothing errors: the window borders and the pointer just quietly change.
_lnf_dir="${XDG_DATA_HOME:-$HOME/.local/share}/plasma/look-and-feel"
chk "global theme installed"     yes \
    "$([ -f "$_lnf_dir/Catppuccin-Latte-Blue/metadata.json" ] && echo yes || echo no)"
# Plasma records the selected package in ~/.config/kdedefaults/package.
_lnfsel=$(cat "${XDG_CONFIG_HOME:-$HOME/.config}/kdedefaults/package" 2>/dev/null)
chk "global theme selected"      Catppuccin-Latte-Blue "${_lnfsel:-<unset>}"

if command -v kreadconfig6 >/dev/null 2>&1; then
  # The exclusions. Aurorae here means the re-assert did not run.
  chk "decoration (Breeze, not Aurorae)" org.kde.breeze \
      "$(kreadconfig6 --file kwinrc --group org.kde.kdecoration2 --key library 2>/dev/null)"
  chk "cursor theme"             "WhiteSur-cursors" \
      "$(kreadconfig6 --file kcminputrc --group Mouse --key cursorTheme 2>/dev/null)"
  chk "icon theme"               "breeze" \
      "$(kreadconfig6 --file kdeglobals --group Icons --key Theme 2>/dev/null)"
  chk "splash theme"             "Catppuccin-Latte-Blue-splash" \
      "$(kreadconfig6 --file ksplashrc --group KSplash --key Theme 2>/dev/null)"
fi
# NB: and check the splash package is COMPLETE, not just named. Upstream's
# tarball ships the splash directory WITHOUT Splash.qml - it is copied in from
# generated/splash-qml/ by their installer, and four chezmoi externals reassemble
# it here. A package missing it installs, appears in the theme list, and renders
# nothing: the exact silent-substitution shape this file exists for.
chk "splash package complete"    yes \
    "$([ -f "$_lnf_dir/Catppuccin-Latte-Blue-splash/contents/splash/Splash.qml" ] &&
       [ -f "$_lnf_dir/Catppuccin-Latte-Blue-splash/contents/splash/images/Logo.png" ] &&
       echo yes || echo no)"
# Icon themes are keyed off the DIRECTORY name, so a renamed upstream release
# breaks the theme silently - Plasma falls back per icon rather than erroring.
# That risk is exactly why the icon theme is Breeze now and not a third-party
# one: this check should be unfailable, and if it ever fails a KDE base package
# is missing rather than an AUR theme having renamed itself.
chk "icon theme on disk"         yes \
    "$([ -f /usr/share/icons/breeze/index.theme ] ||
       [ -f "${XDG_DATA_HOME:-$HOME/.local/share}/icons/breeze/index.theme" ] &&
       echo yes || echo no)"

# The panel launcher's Catppuccin icon. Two separate things can be wrong and
# only one of them is visible: the FILE can be missing (chezmoi never applied,
# or the hicolor path changed), or the file can be there and the widget still
# pointing at the Plasma default because the scripting API call never ran - the
# script only reaches it inside a live session. Check both.
_launcher_png="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/512x512/apps/catppuccin-latte.png"
chk "launcher icon on disk"      yes \
    "$([ -f "$_launcher_png" ] && echo yes || echo no)"
# NB: read it out of appletsrc rather than asking plasmashell, so this works on
# a TTY too - doctor.sh must not need a live session to tell you the truth.
#
# NB: matching on the icon NAME rather than walking to the launcher's applet
# group. The group is [Containments][N][Applets][M][Configuration][General] with
# both numbers machine-local, and the awk to walk there reliably was longer than
# the check it guarded. "catppuccin-latte" is written by nothing else in this
# repo or on this machine, so its presence in appletsrc means the kde-theme
# script's scripting-API call landed. If you ever use that icon name for a
# second widget, this check stops being precise - nothing else will notice.
_appletsrc="${XDG_CONFIG_HOME:-$HOME/.config}/plasma-org.kde.plasma.desktop-appletsrc"
chk "launcher icon set"          yes \
    "$(grep -q '^icon=catppuccin-latte$' "$_appletsrc" 2>/dev/null && echo yes || echo no)"

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
  # NB: WHAT THIS ASSERTS CHANGED, 2026-09-05, and the inversion is the point.
  # It used to assert ppfeaturemask == 0xffffffff, which system/apply.sh wrote
  # via /etc/modprobe.d. 0xffffffff is not "OverDrive on", it is EVERY PowerPlay
  # bit on, including PP_GFX_DCS_MASK (0x80000), which the driver leaves off by
  # default on Polaris. The RX 570 froze for ten seconds, reset, and froze again
  # in a loop - 10000 ms is amdgpu's default lockup_timeout, so the PERIOD was
  # the diagnosis. The repo sets nothing now, so there is no repo-side value to
  # compare against and asserting one would be permanently red by construction.
  #
  # What doctor asserts instead is that nothing has put it BACK, from any of the
  # places it can come from. That is a fact this repo can still be right about.
  _ppf=$(cat /sys/module/amdgpu/parameters/ppfeaturemask 2>/dev/null || echo '')
  note "amdgpu ppfeaturemask" \
       "${_ppf:-<unreadable - is amdgpu loaded?>} (driver default; this repo sets nothing)"
  _ppf_src=$(
    grep -rlsE '^[[:space:]]*options[[:space:]]+amdgpu\b.*ppfeaturemask' \
      /etc/modprobe.d /run/modprobe.d /usr/lib/modprobe.d 2>/dev/null
    case " $(cat /proc/cmdline 2>/dev/null) " in
      *" amdgpu.ppfeaturemask="*) echo /proc/cmdline ;;
    esac
  )
  _ppf_src=$(printf '%s' "$_ppf_src" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  chk "no amdgpu ppfeaturemask override" none "${_ppf_src:-none}"
  # Two ways this goes wrong and they need OPPOSITE fixes, so say which.
  if [ -n "$_ppf_src" ]; then
    note "  why" "something is forcing the mask. On Polaris 0xffffffff hangs the GPU."
    note "  fix" "remove it, then 'sudo ./system/apply.sh' (it regenerates the initramfs), then reboot"
  elif [ "$(num "${_ppf:-0}")" -eq 4294967295 ]; then
    # Nothing on disk sets it, yet the kernel has it. There is exactly one way
    # that happens: the initramfs still carries the drop-in that was deleted
    # from /etc. amdgpu loads from the initramfs and reads THAT copy.
    note "  drift" "no config sets this but the live value is 0xffffffff - STALE INITRAMFS"
    note "  fix" "$(command -v limine-mkinitcpio >/dev/null 2>&1 &&
                    echo 'sudo limine-mkinitcpio' || echo 'sudo mkinitcpio -P'), then reboot"
  fi
  # NB: pwm1, not pp_od_clk_voltage - one `chk` retired, one added, so the
  # pass/fail denominator does not move (see the note further down about a
  # denominator that changes with the result).
  #
  # pp_od_clk_voltage is the OVERDRIVE interface and exists only when
  # PP_OVERDRIVE_MASK is set, which this repo deliberately no longer does - so
  # asserting it would be asserting the bug. pwm1 is the FAN interface, it
  # exists on stock amdgpu, and it is what LACT actually writes when it applies
  # a fan curve. It is therefore the honest test of "does lactd still do the
  # thing it is installed for".
  _pwm=$(ls /sys/class/drm/card*/device/hwmon/hwmon*/pwm1 >/dev/null 2>&1 &&
         echo present || echo MISSING)
  chk "GPU fan control (hwmon pwm1)" present "$_pwm"
  note "  OverDrive (pp_od_clk_voltage)" \
    "$(ls /sys/class/drm/card*/device/pp_od_clk_voltage >/dev/null 2>&1 &&
       echo 'present - something set ppfeaturemask, see above' ||
       echo 'absent - expected; this repo does not unlock OverDrive')"
  # NB: capture, then default - do NOT append `|| echo not-found`. For a unit
  # that does not exist, `systemctl is-enabled` PRINTS "not-found" and EXITS 1,
  # so the || branch fires too and chk gets a two-line value it can never
  # match. Identical trap to the packagekit and baloo checks further down.
  _lactd=$(systemctl is-enabled lactd.service 2>/dev/null)
  chk "lactd enabled" enabled "${_lactd:-not-found}"
fi

# NB: no board_name regex here any more, and no `lsmod`.
#
# This used to mirror a guess in system/apply.sh - `[[ $board_name =~ [bB]450 ]]`
# picks nct6775, everything else is declared nct6687 - except that this copy had
# an extra `|| lsmod | grep '^nct6775'` disjunct the other one did not, so the
# two files could reach DIFFERENT answers on the same machine while a comment
# right here claimed they mirrored each other. Both now ask lib/sensors.sh the
# same question, and the question is "which driver is BOUND", which lsmod cannot
# answer: a module can insert and bind nothing at all.
_sens_mod=$(board_sensor_bound 2>/dev/null || true)

if [ -z "$_sens_mod" ] &&
   ! { board_sensor_available nct6775 || board_sensor_available nct6687; }; then
  note "board sensors" \
       "<no nct6775/nct6687 driver installed for $(uname -r) - no board-sensor support>"
else
  # NB: loaded is NOT the same as bound. The driver inserts and then reports
  # sensors only if hardware was found. A fan RPM is the only honest proof.
  #
  # NB: `chk` on BOTH outcomes, never `ok` on the success path. `ok` prints a
  # green line but increments nothing, so this check used to enter the
  # pass/fail denominator ONLY when it failed - the total at the foot of the
  # report was 1 smaller on a healthy desktop than on a broken one. A
  # denominator that moves with the result is precisely the quiet dishonesty
  # this whole script exists to catch.
  chk "board sensor driver bound" yes "$([ -n "$_sens_mod" ] && echo yes || echo no)"
  if [ -n "$_sens_mod" ]; then
    note "  driver" "$_sens_mod"
  elif [ -f /etc/modules-load.d/99-nct6775.conf ] || [ -f /etc/modules-load.d/99-nct6687.conf ]; then
    note "  why" "a drop-in is installed but nothing bound - 'sudo modprobe nct6775', or 'dkms status' for nct6687"
  else
    note "  why" "system/apply.sh probes for the chip and installs nothing when none binds.
                  If this board does have a Nuvoton chip: 'dmesg | grep -i nct' -
                  the usual answer is 'bound by ACPI', which needs
                  acpi_enforce_resources=lax on the kernel command line (not set by this repo)."
  fi
  # NB: counted from hwmon sysfs, scoped to the board driver's own device - see
  # board_sensor_fan_count in lib/sensors.sh for why it is not a `sensors` text
  # scrape any more (the block is headed by the CHIP name, nct6797, while the
  # module is nct6775) and for why amdgpu's own fan1 must stay out of the count.
  _fans=$(board_sensor_fan_count)
  chk "board reports fan RPM" yes "$([ "${_fans:-0}" -gt 0 ] && echo yes || echo no)"
  note "  fans seen (board driver only)" "${_fans:-0}${_sens_mod:+ - chip $(board_sensor_chip 2>/dev/null || echo '?')}"
fi
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
    "$(pacman-conf --repo-list 2>/dev/null | grep -x multilib >/dev/null && echo yes || echo no)"

# The 32-bit half of the Vulkan stack. A 64-bit-only install runs Steam fine
# and then falls back to llvmpipe for every 32-bit title.
#
# NB: both of these were UNPASSABLE, which is why this comment is long. They
# were written against Mesa packaging that no longer exists and never revisited,
# so the desktop reported two red lines for a stack that was installed and
# working:
#
#   radeon_icd.i686.json - there is no per-architecture ICD manifest any more.
#     Mesa 26 ships ONE arch-neutral /usr/share/vulkan/icd.d/radeon_icd.json
#     whose library_path is the bare soname "libvulkan_radeon.so", and the
#     32-bit loader resolves that out of /usr/lib32 by itself. The lib32 package
#     ships the .so and no manifest at all - `pacman -Ql lib32-vulkan-intel` on
#     the laptop is four files and none of them is JSON. The old filename cannot
#     exist here no matter what is installed.
#
#   libc6,x86-32 - not how this distro's ldconfig labels a 32-bit library. It
#     prints "(libc6,x86-64)" for 64-bit and a bare "(libc6)" for 32-bit; the
#     string "libc6,x86-32" appears zero times in the entire cache. That is a
#     Debian multiarch label and was never going to match on Arch.
#
# A check that cannot pass is worse than no check: it teaches you to read its
# failure as noise, which is exactly what will happen to the REAL llvmpipe
# fallback when it finally fires. Both now assert something the loader needs.
if [ "$GPU" = amd ]; then
  # The manifest - and specifically that its library_path is RELATIVE. An
  # absolute /usr/lib/... in there resolves to the 64-bit driver for a 32-bit
  # process, which fails the way this whole section is about: no error, just
  # llvmpipe. Globbed, so an older per-arch name still satisfies it.
  _icd=$(ls /usr/share/vulkan/icd.d/radeon_icd*.json 2>/dev/null | head -1)
  chk "RADV ICD manifest (arch-neutral)" ok \
      "$(if [ -z "$_icd" ]; then echo MISSING
         elif grep -q '"library_path"[[:space:]]*:[[:space:]]*"[^/]*"' "$_icd"; then echo ok
         else echo absolute-path; fi)"
  # The 32-bit driver itself, read out of the LINKER CACHE rather than off the
  # filesystem: the loader dlopen()s the bare soname from the manifest above, so
  # ld.so's answer is the one that decides whether a 32-bit title gets RADV.
  # NB: do NOT use `grep -q` in this pipeline. Under `set -o pipefail`, grep -q exits
  # on the first match and sends SIGPIPE (141) to ldconfig, which fails the pipeline.
  chk "32-bit RADV library" present \
      "$(ldconfig -p 2>/dev/null |
         grep 'libvulkan_radeon\.so (libc6) => /usr/lib32/' >/dev/null &&
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

# NB: there is deliberately no OpenCL or ROCm check here any more. Both existed
# only for DaVinci Resolve, which is gone - see packages/creative.tsv for why.
# Kdenlive decodes through VA-API, and that IS checked, once, in the shared
# "GPU & display stack" step above rather than a second time here.
chk "kdenlive installed" yes "$(command -v kdenlive >/dev/null && echo yes || echo no)"
chk "heroic installed" yes \
    "$(command -v heroic >/dev/null 2>&1 && echo yes ||
       { pacman -Qq heroic-games-launcher-bin >/dev/null 2>&1 && echo yes || echo no; })"

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
    "$(ls /etc/snapper/configs/ 2>/dev/null | grep . >/dev/null && echo yes || echo no)"
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
