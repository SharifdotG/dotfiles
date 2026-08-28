# shellcheck shell=bash
# Minimal logging. No colours when not a tty, so logs pipe cleanly.
if [ -t 1 ]; then
  _C_RESET=$'\033[0m'; _C_INFO=$'\033[1;34m'; _C_OK=$'\033[1;32m'
  _C_WARN=$'\033[1;33m'; _C_ERR=$'\033[1;31m'; _C_DIM=$'\033[2m'
else
  _C_RESET=; _C_INFO=; _C_OK=; _C_WARN=; _C_ERR=; _C_DIM=
fi
info() { printf '%s==>%s %s\n'  "$_C_INFO" "$_C_RESET" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$_C_OK"   "$_C_RESET" "$*"; }
warn() { printf '%swarn%s %s\n' "$_C_WARN" "$_C_RESET" "$*" >&2; }
die()  { printf '%serr %s %s\n' "$_C_ERR"  "$_C_RESET" "$*" >&2; exit 1; }
step() { printf '\n%s--- %s%s\n' "$_C_DIM" "$*" "$_C_RESET"; }
