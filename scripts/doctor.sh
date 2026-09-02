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
chk "earlyoom protects niri"     yes "$(case "$_eoargs" in *niri*) echo yes;; *) echo no;; esac)"
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
chk "compositor"                 niri "$(pgrep -x niri >/dev/null && echo niri || echo none)"
chk "noctalia running"           yes  "$(pgrep -x noctalia >/dev/null && echo yes || echo no)"
chk "xwayland-satellite"         yes  "$(pgrep -f xwayland-satell >/dev/null && echo yes || echo no)"
chk "niri config present"        yes  "$([ -f ~/.config/niri/config.kdl ] && echo yes || echo no)"
# NB: Noctalia's GUI writes ~/.local/state/noctalia/settings.toml, which loads
# LAST and beats the hand-written config.toml this repo manages. It self-prunes
# to only the keys that diverge, so a non-empty file is a precise "you have
# unpromoted GUI changes" signal - not noise.
_nset="$HOME/.local/state/noctalia/settings.toml"
if [ -s "$_nset" ]; then
  warn "noctalia settings.toml overrides config.toml: $(grep -cE '^[a-z_]+ *=' "$_nset" 2>/dev/null) key(s)"
  note "  promote them" "noctalia config export | diff - ~/.config/noctalia/config.toml"
else
  ok "  no unpromoted Noctalia GUI overrides"
fi

step "VS Code"
S="$HOME/.config/Code - Insiders/User/settings.json"
for k in files.watcherExclude search.exclude typescript.tsserver.maxTsServerMemory extensions.autoUpdate; do
  chk "$k" present "$(grep -qF "\"$k\"" "$S" 2>/dev/null && echo present || echo MISSING)"
done
note "extensions installed" "$(ls ~/.vscode-insiders/extensions 2>/dev/null | grep -vc '^\.')"
note "extensions on disk" "$(du -sh ~/.vscode-insiders/extensions 2>/dev/null | cut -f1)"

step "Firefox"
# NB: count ALL profiles, and treat prefs.js OR times.json as the marker - a
# profile created but never launched has times.json and no prefs.js, so keying
# on prefs.js alone undercounts and this check fails on a correctly-tuned box.
# The roots differ by distro: Fedora's RPM honoured $XDG_CONFIG_HOME, upstream
# and Arch do not, so ~/.mozilla is the real path here. Check all three.
_ffroots=("${XDG_CONFIG_HOME:-$HOME/.config}/mozilla/firefox" "$HOME/.mozilla/firefox" \
          "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox")
_ffprofiles=$(find "${_ffroots[@]}" -mindepth 1 -maxdepth 1 -type d \
            \( -exec test -e '{}/prefs.js' \; -o -exec test -e '{}/times.json' \; \) \
            -print 2>/dev/null | wc -l)
_ffuserjs=$(find "${_ffroots[@]}" -mindepth 1 -maxdepth 1 -type d \
            -exec test -e '{}/user.js' \; -print 2>/dev/null | wc -l)
chk "profiles carrying user.js"  "$_ffprofiles" "$_ffuserjs"

# NB: check the KERNEL, not the unit file. A drop-in systemd parsed but never
# bound to a running instance still looks fine in `systemctl show`.
_ffpid=$(pgrep -x firefox | head -1)
_ffcg=$(cut -d: -f3 "/proc/${_ffpid:-0}/cgroup" 2>/dev/null)
_ffhigh=$(cat "/sys/fs/cgroup${_ffcg}/memory.high" 2>/dev/null)
case "$_ffhigh" in
  ''|max) chk "memory.high cap (kernel)" set "${_ffhigh:-firefox not running}" ;;
  *)      chk "memory.high cap (kernel)" set set
          note "  cap" "$((_ffhigh / 1073741824)) GiB"
          note "  throttle events" "$(awk '/^high /{print $2}' "/sys/fs/cgroup${_ffcg}/memory.events" 2>/dev/null)" ;;
esac
# NB: this note is the difference between a diagnosable failure and a mystery.
# Under Plasma, Firefox landed in app.slice/app-org.mozilla.firefox@<hex>.service
# because KDE launched .desktop apps as transient units. niri does not - its own
# unit sets Slice=session.slice, so apps it spawns inherit niri's cgroup and the
# MemoryHigh drop-in matches nothing, silently. Seeing the actual cgroup path
# here tells you immediately whether uwsm/the wrapper is doing its job.
note "firefox cgroup" "${_ffcg:-<not running>}"

_ffp=$(pgrep -fc 'firefox.*-contentproc' 2>/dev/null)   # pgrep -c: prints 0 AND exits 1
note "content processes" "${_ffp:-0}"

# NB: never sum `ps` RSS for a multi-process browser. RSS counts every shared
# page in full against every process mapping it, so a 25-process Firefox
# double-counts libxul ~25 times - this reported 8.3 GB where the system monitor
# said 5.6 GB. PSS divides each shared page by its sharer count.
# NB: derive the binary path; it used to be hardcoded to /usr/lib64/firefox,
# which silently reported 0.00 GiB anywhere that uses /usr/lib.
_ffexe=$(readlink -f "/proc/${_ffpid:-0}/exe" 2>/dev/null)
note "firefox total (PSS)" "$(if [ -n "$_ffexe" ]; then
    for p in $(pgrep -f "$_ffexe"); do
      awk '/^Pss:/{print $2}' "/proc/$p/smaps_rollup" 2>/dev/null; done |
    awk '{s+=$1} END {printf "%.2f GiB", s/1048576}'; else echo n/a; fi)"

# Extensions with <all_urls> inject a content script into every content process,
# so their cost scales with tab count, not with how often you use them.
note "extensions (all-sites/total)" "$(python3 - <<'EOF' 2>/dev/null || echo n/a
import json,glob,os
tot=all_=0
roots=[os.path.expanduser(p) for p in (
    '~/.config/mozilla/firefox/*/extensions.json',
    '~/.mozilla/firefox/*/extensions.json',
    '~/.var/app/org.mozilla.firefox/.mozilla/firefox/*/extensions.json')]
for pat in roots:
  for f in glob.glob(pat):
    try: d=json.load(open(f))
    except Exception: continue
    for a in d.get('addons',[]):
        if a.get('type')!='extension' or not a.get('active'): continue
        if a.get('location') not in ('app-profile','app-system-profile'): continue
        tot+=1
        o=a.get('userPermissions',{}).get('origins',[]) or []
        if any(x in ('<all_urls>','*://*/*','http://*/*','https://*/*') for x in o): all_+=1
print(f'{all_}/{tot}')
EOF
)"

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
