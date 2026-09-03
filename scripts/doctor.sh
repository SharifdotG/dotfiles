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
chk "fd on PATH"                 ok  "$(zsh -ic 'fd --version' 2>/dev/null | grep -q '^fd ' && echo ok || echo broken)"
chk "starship palette active"    yes "$(grep -q '^palette' ~/.config/starship.toml 2>/dev/null && echo yes || echo no)"
chk "ZSH_THEME empty"            yes "$(grep -q '^ZSH_THEME=""' ~/.zshrc 2>/dev/null && echo yes || echo no)"
chk "bat config exists"          yes "$([ -f ~/.config/bat/config ] && echo yes || echo no)"
# Report load and CPU clock alongside: startup time swings 5x between an idle
# machine (~0.09s) and load>6 with the CPU parked at 800 MHz (~0.45s). Without
# this context the number looks like a regression when it isn't.
note "zsh startup" "$( { TIMEFORMAT=%R; time zsh -ic exit; } 2>&1 | tail -1 )s"
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
_bvpids=$(pgrep -f '/opt/brave.com/brave-origin' 2>/dev/null)
if [ -z "$_bvpids" ]; then
  note "brave" "not running"
else
  note "processes" "$(echo "$_bvpids" | wc -l)"
  # NB: PSS, never RSS. RSS counts every shared page in full against every
  # process mapping it, so a 30-process Chromium double-counts its shared
  # runtime ~30 times. PSS divides each shared page by its sharer count.
  note "brave total (PSS)" "$(for p in $_bvpids; do
      awk '/^Pss:/{print $2}' "/proc/$p/smaps_rollup" 2>/dev/null; done |
      awk '{s+=$1} END {printf "%.2f GiB", s/1048576}')"
  # NB: this is the check that replaced Firefox's `memory.high` check, and the
  # reason it is a NOTE rather than a pass/fail is worth recording.
  #
  # Firefox got a hard 6 GiB ceiling from a drop-in on the transient unit KDE
  # created for it (app-firefox@<hex>.service). That mechanism does NOT port to
  # Chromium: Brave self-registers its OWN transient scope named
  # app-org.chromium.Chromium-<PID>.scope and migrates the bulk of its
  # processes into it. Measured here: 32 processes in the self-created scope
  # versus 2 left in the unit KDE made. A template drop-in cannot target a
  # PID-suffixed scope name, so there is currently NO per-app cap on the
  # browser - and pretending otherwise would be worse than having none.
  #
  # If Brave ever needs a ceiling, the mechanism is a SLICE, because cgroup
  # limits are hierarchical and a child cannot exceed its parent. That needs
  # verifying against where Chromium places its scope before it is trusted.
  note "cgroups in use" "$(for p in $_bvpids; do cut -d: -f3 "/proc/$p/cgroup" 2>/dev/null; done |
      sed 's|.*/||' | sort -u | tr '\n' ' ')"
  note "  (no MemoryHigh cap)" "Chromium self-scopes; see the NB in this script"
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
