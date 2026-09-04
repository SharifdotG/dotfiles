# shellcheck shell=bash
# Presentation layer. Every script in this repo draws through this file.
#
# THE RULE THIS FILE EXISTS TO ENFORCE: pretty when a human is watching, plain
# when anything else is. `bootstrap.sh | tee install.log`, a chezmoi script whose
# output chezmoi captures, a CI runner, `TERM=dumb` on a rescue console - all of
# them get the same clean ASCII this file has always emitted. The decoration is
# additive and never changes what is said, only how it looks.
#
# NO ARTIFICIAL DELAYS, ANYWHERE. There is no "sleep 0.3 so the animation is
# visible", no typewriter effect on the banner, no fake progress. A spinner turns
# only while a real command is running and stops the instant it exits; a progress
# bar advances only on real work completed. A script that pauses to look busy is
# slower and less trustworthy than one that doesn't, and this repo exists because
# the machine is short on time and memory, not long on both.
#
# Override with DOTFILES_UI=rich|plain (auto by default). NO_COLOR is honoured.

# ── capability detection ─────────────────────────────────────────────────────
# Rich needs all of: a real terminal, a terminal that is not "dumb", no NO_COLOR,
# and no explicit opt-out. Anything missing drops the whole layer, not part of it
# - half-styled output is worse than none.
_UI_RICH=0
case "${DOTFILES_UI:-auto}" in
  rich)  _UI_RICH=1 ;;
  plain) _UI_RICH=0 ;;
  *) [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ -z "${NO_COLOR:-}" ] && _UI_RICH=1 ;;
esac

# Glyphs need a UTF-8 locale. A fresh Arch TTY before locale-gen is exactly the
# machine this repo bootstraps, and it draws U+2713 as a question mark.
#
# NB: this is decided by the LOCALE ALONE, deliberately not gated on _UI_RICH.
# Piping to a file is not a reason to lose ✓/✗ - the file is still UTF-8, and
# doctor.sh's log has always used those two glyphs. Colour is what a pipe cannot
# take; glyphs are not.
_UI_UNI=0
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *[Uu][Tt][Ff]*) _UI_UNI=1 ;; esac

if [ "$_UI_RICH" -eq 1 ]; then
  # Catppuccin Latte, the same palette as ghostty/bat/btop/starship on this
  # machine - the terminal is already this colour, so the output belongs in it.
  # Truecolour where the terminal says so, the nearest ANSI 16 otherwise.
  if [ "${COLORTERM:-}" = truecolor ] || [ "${COLORTERM:-}" = 24bit ]; then
    _C_BLUE=$'\033[38;2;30;102;245m'   ; _C_GREEN=$'\033[38;2;64;160;43m'
    _C_YELLOW=$'\033[38;2;223;142;29m' ; _C_RED=$'\033[38;2;210;15;57m'
    _C_MAUVE=$'\033[38;2;136;57;239m'  ; _C_TEAL=$'\033[38;2;23;146;153m'
    _C_TEXT=$'\033[38;2;76;79;105m'    ; _C_DIM=$'\033[38;2;156;160;176m'
  else
    _C_BLUE=$'\033[34m'   ; _C_GREEN=$'\033[32m'
    _C_YELLOW=$'\033[33m' ; _C_RED=$'\033[31m'
    _C_MAUVE=$'\033[35m'  ; _C_TEAL=$'\033[36m'
    _C_TEXT=$'\033[39m'   ; _C_DIM=$'\033[2m'
  fi
  _C_BOLD=$'\033[1m'; _C_RESET=$'\033[0m'
else
  _C_BLUE=; _C_GREEN=; _C_YELLOW=; _C_RED=; _C_MAUVE=; _C_TEAL=
  _C_TEXT=; _C_DIM=; _C_BOLD=; _C_RESET=
fi

if [ "$_UI_UNI" -eq 1 ]; then
  _G_OK='✓'; _G_BAD='✗'; _G_WARN='▲'; _G_STEP='▸'; _G_DOT='·'
  _G_LINE='─'; _G_FULL='█'; _G_EMPTY='░'
  _G_SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
else
  _G_OK='ok'; _G_BAD='XX'; _G_WARN='!!'; _G_STEP='>'; _G_DOT='.'
  _G_LINE='-'; _G_FULL='#'; _G_EMPTY='.'
  _G_SPIN=('|' '/' '-' '\')
fi

# Recomputed per call: a terminal can be resized mid-run, and $COLUMNS is not
# exported into a script's environment by every shell.
ui_cols() {
  local c=""
  [ "$_UI_RICH" -eq 1 ] && c=$(tput cols 2>/dev/null)
  [ -n "$c" ] || c="${COLUMNS:-80}"
  [ "$c" -gt 100 ] 2>/dev/null && c=100
  [ "$c" -ge 40 ] 2>/dev/null || c=80
  printf '%s' "$c"
}

_ui_repeat() { # _ui_repeat <string> <count>
  local i out=""
  for ((i = 0; i < $2; i++)); do out="$out$1"; done
  printf '%s' "$out"
}

# ── the primitives every script already uses ─────────────────────────────────
# Plain-mode output is byte-identical to what this file emitted before the
# presentation layer existed, so anything grepping a piped log still matches.
info() {
  if [ "$_UI_RICH" -eq 1 ]; then printf '%s==>%s %s\n' "$_C_BLUE$_C_BOLD" "$_C_RESET" "$*"
  else printf '==> %s\n' "$*"; fi
  return 0
}
ok() {
  if [ "$_UI_RICH" -eq 1 ]; then printf '  %s%s%s %s\n' "$_C_GREEN" "$_G_OK" "$_C_RESET" "$*"
  else printf '  ok %s\n' "$*"; fi
  return 0
}
warn() {
  if [ "$_UI_RICH" -eq 1 ]; then printf '  %s%s%s %s\n' "$_C_YELLOW" "$_G_WARN" "$_C_RESET" "$*" >&2
  else printf 'warn %s\n' "$*" >&2; fi
  return 0
}
die() {
  if [ "$_UI_RICH" -eq 1 ]; then printf '  %s%s%s %s\n' "$_C_RED$_C_BOLD" "$_G_BAD" "$_C_RESET" "$*" >&2
  else printf 'err  %s\n' "$*" >&2; fi
  exit 1
}

# Aligned key/value with a dim leader. The leader is what makes a long list
# readable at a glance; it is also why this is a function and not a printf.
# Shared so `note` here and `chk` in doctor.sh line up in the same columns.
ui_leader() { # ui_leader <label> -> "label ······" (or a padded label when plain)
  local w pad label="$1"
  w=$(( $(ui_cols) - 8 )); [ "$w" -gt 46 ] && w=46
  if [ "$_UI_RICH" -eq 1 ]; then
    pad=$(( w - ${#label} - 1 )); [ "$pad" -lt 1 ] && pad=1
    printf '%s %s%s%s' "$label" "$_C_DIM" "$(_ui_repeat "$_G_DOT" "$pad")" "$_C_RESET"
  else
    printf '%-46s' "$label"
  fi
  return 0
}
note() { # note <label> <value>
  printf '    %s %s\n' "$(ui_leader "$1")" "${2-}"
  return 0
}

rule() {
  [ "$_UI_RICH" -eq 1 ] || return 0
  printf '%s%s%s\n' "$_C_DIM" "$(_ui_repeat "$_G_LINE" "$(ui_cols)")" "$_C_RESET"
  return 0
}

# ── steps ────────────────────────────────────────────────────────────────────
# Each step closes the previous one and reports how long it took. Set UI_STEPS to
# the number of steps a script has and the header numbers itself.
_UI_STEP_N=0
_UI_STEP_T0=""
_ui_now() { # seconds, sub-second where bash provides it
  if [ -n "${EPOCHREALTIME:-}" ]; then printf '%s' "${EPOCHREALTIME/,/.}"
  else printf '%s' "$SECONDS"; fi
}
_ui_since() { # _ui_since <t0> -> "1.2s"
  local t0="$1" now; now=$(_ui_now)
  awk -v a="$t0" -v b="$now" 'BEGIN { d = b - a; if (d < 0) d = 0;
    if (d < 60) printf "%.1fs", d; else printf "%dm%02ds", int(d/60), int(d%60) }'
}
# Only report a duration worth reporting. A "took 0.0s" line under every fast
# phase is noise, and on this repo most phases are fast; the number matters for
# the package install and the DB read, which are the ones that are slow.
_UI_STEP_MIN=0.5
_ui_close_step() {
  [ -n "$_UI_STEP_T0" ] || return 0
  if [ "$_UI_RICH" -eq 1 ] &&
     awk -v a="$_UI_STEP_T0" -v b="$(_ui_now)" -v m="$_UI_STEP_MIN" \
         'BEGIN { exit !(b - a >= m) }'; then
    printf '    %s%s took %s%s\n' "$_C_DIM" "$_G_DOT" "$(_ui_since "$_UI_STEP_T0")" "$_C_RESET"
  fi
  _UI_STEP_T0=""
  return 0
}
step() {
  _ui_close_step
  _UI_STEP_N=$((_UI_STEP_N + 1))
  _UI_STEP_T0=$(_ui_now)
  if [ "$_UI_RICH" -eq 1 ]; then
    local n=""
    [ -n "${UI_STEPS:-}" ] && n="$_C_DIM[$_UI_STEP_N/$UI_STEPS]$_C_RESET "
    printf '\n%s%s%s %s%s%s%s\n' "$_C_MAUVE$_C_BOLD" "$_G_STEP" "$_C_RESET" "$n" "$_C_BOLD" "$*" "$_C_RESET"
  else
    printf '\n--- %s\n' "$*"
  fi
  return 0
}
steps_end() { _ui_close_step; return 0; }

# ── banner ───────────────────────────────────────────────────────────────────
banner() { # banner <title> [subtitle]
  local cols; cols=$(ui_cols)
  if [ "$_UI_RICH" -eq 1 ]; then
    printf '\n%s%s%s%s\n' "$_C_MAUVE" "$_C_BOLD" "$1" "$_C_RESET"
    [ -n "${2-}" ] && printf '%s%s%s\n' "$_C_DIM" "$2" "$_C_RESET"
    printf '%s%s%s\n' "$_C_DIM" "$(_ui_repeat "$_G_LINE" "$cols")" "$_C_RESET"
  else
    printf '\n%s\n' "$1"
    [ -n "${2-}" ] && printf '%s\n' "$2"
    printf '%s\n' "$(_ui_repeat '-' 60)"
  fi
  return 0
}

# NB: there is no progress-bar helper here, and that is deliberate. The only
# genuinely long operations in this repo are `pacman -Syu` and `paru`, and both
# already draw their own progress; everything else finishes in well under a
# second. A bar over three items, or one that advances on a timer rather than on
# work, is the "looks busy" theatre the header of this file rules out. If a real
# multi-item loop ever appears, add one then - against real counts.

# ── spinner ──────────────────────────────────────────────────────────────────
# spin <label> <command...>  - runs the command, animates while it runs, returns
# its exit status. On failure the captured output is printed; on success it is
# discarded, which is the whole point of hiding it behind a spinner.
#
# ONLY FOR NON-INTERACTIVE COMMANDS. The output is captured, so anything that
# prompts - sudo, pacman's conflict questions, paru's PKGBUILD pager, `chezmoi
# init` - would block invisibly forever. Those must stay unwrapped and stream to
# the terminal, and in this repo they do.
_ui_cursor_shown=1
_ui_show_cursor() { [ "$_ui_cursor_shown" -eq 1 ] || printf '\033[?25h'; _ui_cursor_shown=1; return 0; }
spin() {
  local label="$1"; shift
  if [ "$_UI_RICH" -ne 1 ]; then
    "$@" >/dev/null 2>&1
    local rc=$?
    [ "$rc" -eq 0 ] && ok "$label" || warn "$label (failed)"
    return "$rc"
  fi
  local out; out=$(mktemp) || { "$@"; return $?; }
  # </dev/null so the child can never eat the caller's stdin - a `read` after a
  # spun command that swallowed the terminal is a genuinely baffling bug.
  "$@" >"$out" 2>&1 </dev/null &
  local pid=$! i=0 rc
  printf '\033[?25l'; _ui_cursor_shown=0
  trap '_ui_show_cursor' EXIT INT TERM
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r\033[2K  %s%s%s %s' "$_C_TEAL" "${_G_SPIN[i++ % ${#_G_SPIN[@]}]}" "$_C_RESET" "$label"
    # NB: sleep, NOT `read -t` on fd 0. A read here would consume the CALLER's
    # stdin - so a script that spins a command and then prompts the user would
    # silently lose the answer. This is a frame rate, not a delay: the loop ends
    # the moment the child does.
    sleep 0.08
  done
  wait "$pid"; rc=$?
  _ui_show_cursor; trap - EXIT INT TERM
  printf '\r\033[2K'
  if [ "$rc" -eq 0 ]; then ok "$label"
  else warn "$label (exit $rc)"; sed 's/^/      /' "$out" >&2; fi
  rm -f "$out"
  return "$rc"
}

# ── summary bar ──────────────────────────────────────────────────────────────
bar() { # bar <good> <total> <label>
  local good="$1" total="$2" label="$3" width=30 filled colour
  [ "$total" -gt 0 ] 2>/dev/null || return 0
  filled=$(( good * width / total ))
  if [ "$_UI_RICH" -ne 1 ]; then
    printf '\n  %d/%d %s\n\n' "$good" "$total" "$label"
    return 0
  fi
  if   [ "$good" -eq "$total" ]; then colour="$_C_GREEN"
  elif [ $(( good * 100 / total )) -ge 80 ]; then colour="$_C_YELLOW"
  else colour="$_C_RED"; fi
  printf '\n  %s%s%s%s%s  %s%d/%d%s %s\n\n' \
    "$colour" "$(_ui_repeat "$_G_FULL" "$filled")" \
    "$_C_DIM" "$(_ui_repeat "$_G_EMPTY" $(( width - filled )))" "$_C_RESET" \
    "$_C_BOLD" "$good" "$total" "$_C_RESET" "$label"
  return 0
}
