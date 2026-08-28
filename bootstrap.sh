#!/usr/bin/env bash
# Configure a machine from this repo.
#
#   git clone <this repo> ~/dotfiles && ~/dotfiles/bootstrap.sh
#
# Idempotent: safe to re-run, and re-running is the normal update path.
set -uo pipefail
cd "$(dirname "$0")"
REPO="$PWD"
. lib/log.sh
. lib/detect.sh
. lib/pkg.sh

DRY=0 NO_PKGS=0 FORCE=0
for a in "$@"; do case "$a" in
  --dry-run)     DRY=1 ;;
  --no-packages) NO_PKGS=1 ;;
  --force)       FORCE=1 ;;
  -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
  *) die "unknown flag: $a" ;;
esac; done

STAMPS="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/stamps"
mkdir -p "$STAMPS"
# A step re-runs only when its inputs change (or --force).
stamp_ok()   { [ "$FORCE" -eq 0 ] && [ -f "$STAMPS/$1" ] && [ "$(cat "$STAMPS/$1")" = "$2" ]; }
stamp_set()  { [ "$DRY" -eq 1 ] || printf '%s' "$2" > "$STAMPS/$1"; }
hash_of()    { cat "$@" 2>/dev/null | sha256sum | cut -c1-16; }
run()        { if [ "$DRY" -eq 1 ]; then printf '    would run: %s\n' "$*"; else "$@"; fi; }

# ── preflight ────────────────────────────────────────────────────────────────
[ "$(id -u)" -ne 0 ] || die "do not run me as root; I call sudo only where needed"
command -v git >/dev/null || die "git is required"
detect_all
info "$DISTRO / desktop=$DESKTOP / session=$SESSION_TYPE / vm=$IS_VM"
[ "$DRY" -eq 1 ] && warn "DRY RUN - nothing will be changed"

# ── 1. distro prep (repos) ───────────────────────────────────────────────────
if [ -x "os/$DISTRO/prep.sh" ]; then
  step "distro prep ($DISTRO)"
  h=$(hash_of "os/$DISTRO/prep.sh")
  if stamp_ok "prep-$DISTRO" "$h"; then ok "already done"
  else run "os/$DISTRO/prep.sh" && stamp_set "prep-$DISTRO" "$h"; fi
else
  warn "no os/$DISTRO/prep.sh - skipping repo setup"
fi

# ── 2. packages ──────────────────────────────────────────────────────────────
if [ "$NO_PKGS" -eq 0 ]; then
  step "packages"
  MANIFESTS=(packages/core.tsv packages/dev.tsv packages/reliability.tsv)
  [ "$DESKTOP" != none ] && MANIFESTS+=(packages/desktop.tsv)
  h=$(hash_of "${MANIFESTS[@]}")
  if stamp_ok "packages-$PKG_COL" "$h"; then ok "manifests unchanged"
  else
    mapfile -t PKGS < <(pkg_resolve "$PKG_COL" "${MANIFESTS[@]}")
    info "${#PKGS[@]} packages for column '$PKG_COL'"
    case "$PKG_COL" in
      fedora) run sudo dnf install -y "${PKGS[@]}" ;;
      arch)   run sudo pacman -S --needed --noconfirm "${PKGS[@]}" ;;
      nix)    warn "NixOS: add these to configuration.nix - ${PKGS[*]}" ;;
    esac && stamp_set "packages-$PKG_COL" "$h"
    # Anything the manifest marks "-" for this distro needs a special path.
    for u in $(pkg_unavailable "$PKG_COL" "${MANIFESTS[@]}"); do
      case "$u" in
        starship) command -v starship >/dev/null && ok "starship present" ||
                    run sh -c 'curl -sS https://starship.rs/install.sh | sh -s -- --yes' ;;
        *) warn "no repo package for '$u' on $DISTRO - install it manually" ;;
      esac
    done
  fi
fi

# ── 3. chezmoi ───────────────────────────────────────────────────────────────
step "chezmoi"
if ! command -v chezmoi >/dev/null; then
  warn "chezmoi not on PATH - installing to ~/.local/bin"
  run sh -c 'sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin"'
  export PATH="$HOME/.local/bin:$PATH"
fi
if command -v chezmoi >/dev/null; then
  if [ -d "${XDG_CONFIG_HOME:-$HOME/.config}/chezmoi" ]; then
    run chezmoi apply --source "$REPO"
  else
    info "first run - chezmoi will prompt for name/email/desktop"
    run chezmoi init --apply --source "$REPO"
  fi
  ok "home configuration applied"
fi

# ── 4. shell ─────────────────────────────────────────────────────────────────
step "login shell"
if [ "${SHELL##*/}" != zsh ] && command -v zsh >/dev/null; then
  info "changing login shell to zsh (asks for your password)"
  run chsh -s "$(command -v zsh)"
else ok "already zsh"; fi

# ── 5. what still needs a human ──────────────────────────────────────────────
step "remaining manual steps"
cat <<'EOS'
  sudo ./system/apply.sh      install /etc drop-ins (memory tuning, journald, docker)
  ./scripts/reclaim.sh        remove unused idle services (KDE PIM, PackageKit, Baloo)
  ./scripts/secrets-setup.sh  generate an SSH key and sign in to GitHub
  ./scripts/doctor.sh         verify everything
EOS
