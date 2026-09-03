#!/usr/bin/env bash
# Health check. Read-only: reports, never changes anything.
set -uo pipefail
cd "$(dirname "$0")/.."
. lib/log.sh
. lib/detect.sh
detect_all

pass=0; fail=0
chk() { # chk <label> <expected> <actual>
  if [ "$2" = "$3" ]; then printf '  \033[1;32m✓\033[0m %-42s %s\n' "$1" "$3"; pass=$((pass+1))
  else printf '  \033[1;31m✗\033[0m %-42s %s (want: %s)\n' "$1" "$3" "$2"; fail=$((fail+1)); fi
}
note() { printf '    %-42s %s\n' "$1" "$2"; }

_uarch=$(/lib64/ld-linux-x86-64.so.2 --help 2>/dev/null |
         awk '/x86-64-v[0-9] \(supported/ {print $1}' | sort -r | head -1)
info "System: $DISTRO / $DESKTOP / $SESSION_TYPE  (vm: $IS_VM, pkg column: $PKG_COL, ${_uarch:-?})"

step "Platform"
# NB: a v4 package on a v3 CPU installs cleanly and dies with SIGILL at RUNTIME,
# which presents as random binaries crashing - it reads exactly like failing RAM.
# Check the repo tier against the CPU, not against what you think you selected.
chk "no v4 repo on a non-v4 CPU"  ok \
  "$(if grep -q '^\[cachyos-v4' /etc/pacman.conf 2>/dev/null && [ "$_uarch" != x86-64-v4 ]; then
       echo MISMATCH; else echo ok; fi)"
note "cachyos repo tier" "$(grep -oE '^\[cachyos(-v[34])?[a-z-]*\]' /etc/pacman.conf 2>/dev/null | tr -d '[]' | tr '\n' ' ')"

step "Memory pressure defences"
chk "vm.swappiness"              180      "$(sysctl -n vm.swappiness 2>/dev/null)"
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
note "coredumps on disk" "$(sudo -n du -sh /var/lib/systemd/coredump 2>/dev/null | cut -f1 || echo '<needs root>')"
note "pacman cache" "$(du -sh /var/cache/pacman/pkg 2>/dev/null | cut -f1)"
note "orphan packages" "$(pacman -Qtdq 2>/dev/null | wc -l)"
# NB: an unmerged .pacnew for pacman.conf, sudoers or mkinitcpio.conf is how the
# machine breaks weeks later with no error at the time. This is a maintenance
# responsibility Fedora never imposed.
note "/etc .pacnew files" "$(find /etc -name '*.pacnew' 2>/dev/null | wc -l)"

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
_pk=$(systemctl is-enabled packagekit 2>/dev/null)
chk "packagekit"                 masked   "${_pk:-not installed}"
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

step "Rollback safety"
chk "snapper installed"          yes "$(command -v snapper >/dev/null && echo yes || echo no)"
chk "snap-pac installed"         yes "$(pacman -Qq snap-pac >/dev/null 2>&1 && echo yes || echo no)"
# NB: `command -v snapper` passes on a box with the binary and zero configs,
# which is no rollback net at all. Count actual snapshots.
# NB: `grep -c` PRINTS 0 and EXITS 1 when nothing matches, so a naive
# `grep -c ... || echo '<needs root>'` runs both branches and prints two lines.
_snaps=$(sudo -n snapper -c root list 2>/dev/null | grep -cE '^[0-9]')
note "root snapshots" "${_snaps:-<needs root>}"

printf '\n  %d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
