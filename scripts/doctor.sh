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

info "System: $DISTRO / $DESKTOP / $SESSION_TYPE  (vm: $IS_VM, pkg column: $PKG_COL)"

step "Memory pressure defences"
chk "vm.swappiness"              180      "$(sysctl -n vm.swappiness 2>/dev/null)"
chk "vm.page-cluster"            0        "$(sysctl -n vm.page-cluster 2>/dev/null)"
chk "kernel.sysrq"               1        "$(sysctl -n kernel.sysrq 2>/dev/null)"
chk "fs.inotify.max_user_watches" 524288  "$(sysctl -n fs.inotify.max_user_watches 2>/dev/null)"
chk "systemd-oomd"               active   "$(systemctl is-active systemd-oomd 2>/dev/null)"
chk "earlyoom"                   active   "$(systemctl is-active earlyoom 2>/dev/null)"
note "zram" "$(zramctl --noheadings --output NAME,DISKSIZE,DATA,TOTAL 2>/dev/null | tr -s ' ')"
note "OOM kills, last 7d" "$(journalctl --since '7 days ago' 2>/dev/null | grep -cE 'earlyoom.*sending|oomd.*Killed|Killed process')"

step "Idle-service reclaim"
chk "akonadi processes"          0        "$(pgrep -c akonadi 2>/dev/null || true)"
# NB: `balooctl6 status` EXITS 1 when baloo is disabled, so under `set -o pipefail`
# a piped grep reports a false negative. Capture the output, then test it.
_baloo=$(balooctl6 status 2>&1 || true)
chk "baloo file indexer"         disabled "$(case "$_baloo" in *"currently disabled"*) echo disabled;; *) echo enabled;; esac)"
chk "packagekit"                 masked   "$(systemctl is-enabled packagekit 2>/dev/null || echo unknown)"
note "reclaim targets resident" "$(ps -eo rss,comm --no-headers | grep -iE 'akonadi|packagekitd|Discover|baloo' | grep -v grep | awk '{s+=$1} END {printf "%.0f MB", s/1024}')"

step "Journal"
chk "journald cap present"       yes      "$([ -f /etc/systemd/journald.conf.d/99-size-cap.conf ] && echo yes || echo no)"
note "journal on disk" "$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[MG]' | head -1)"

step "Shell + CLI config"
chk "fd works (alias removed)"   ok       "$(zsh -ic 'fd --version' 2>/dev/null | grep -q '^fd ' && echo ok || echo broken)"
chk "starship palette active"    yes      "$(grep -q '^palette' ~/.config/starship.toml 2>/dev/null && echo yes || echo no)"
chk "ZSH_THEME empty"            yes      "$(grep -q '^ZSH_THEME=""' ~/.zshrc 2>/dev/null && echo yes || echo no)"
chk "bat config exists"          yes      "$([ -f ~/.config/bat/config ] && echo yes || echo no)"
note "zsh startup" "$( { TIMEFORMAT=%R; time zsh -ic exit; } 2>&1 | tail -1 )s"

step "VS Code"
S="$HOME/.config/Code - Insiders/User/settings.json"
for k in files.watcherExclude search.exclude typescript.tsserver.maxTsServerMemory extensions.autoUpdate; do
  chk "$k" present "$(grep -qF "\"$k\"" "$S" 2>/dev/null && echo present || echo MISSING)"
done
note "extensions installed" "$(ls ~/.vscode-insiders/extensions 2>/dev/null | grep -vc '^\.')"
note "extensions on disk" "$(du -sh ~/.vscode-insiders/extensions 2>/dev/null | cut -f1)"

step "Firefox"
P=$(ls -d ~/.config/mozilla/firefox/*.default-release 2>/dev/null | head -1)
chk "user.js present"            yes      "$([ -f "$P/user.js" ] && echo yes || echo no)"
note "content processes" "$(pgrep -fc 'firefox.*-contentproc' 2>/dev/null || echo 0)"
note "firefox family RSS" "$(ps -eo rss,comm --no-headers | grep -E 'Isolated|Web Content|firefox|WebExtensions|Privileged|RDD' | awk '{s+=$1} END {printf "%.0f MB", s/1024}')"

step "Rollback safety"
chk "snapper installed"          yes      "$(command -v snapper >/dev/null && echo yes || echo no)"

printf '\n  %d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
