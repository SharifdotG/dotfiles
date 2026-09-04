#!/usr/bin/env bash
# Configure a CachyOS machine from this repo.
#
#   git clone <this repo> ~/dotfiles && ~/dotfiles/bootstrap.sh
#
# Flags: --dry-run  --no-packages  --no-desktop  --force
# Idempotent: safe to re-run, and re-running is the normal update path.
set -uo pipefail
cd "$(dirname "$0")"
REPO="$PWD"
. lib/log.sh
. lib/detect.sh
. lib/pkg.sh

DRY=0 NO_PKGS=0 NO_DESKTOP=0 FORCE=0
for a in "$@"; do case "$a" in
  --dry-run)     DRY=1 ;;
  --no-packages) NO_PKGS=1 ;;
  --no-desktop)  NO_DESKTOP=1 ;;
  --force)       FORCE=1 ;;
  # NB: derived, not a hardcoded line range. This was `sed -n '2,12p'`, which
  # printed five lines of shell (set -uo pipefail, the cd, the sources) once the
  # header comment got shorter than the range. Stop at the first non-comment.
  -h|--help) awk 'NR>1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
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
# UI_STEPS only numbers the step headers; nothing branches on it. Counted from
# the flags rather than hardcoded to 5, because two of the five are conditional -
# a hardcoded total prints "[4/5]" as the last step under --no-packages, which is
# exactly the kind of small wrongness that makes a tool feel careless.
UI_STEPS=3
[ -x "os/$DISTRO/prep.sh" ] && UI_STEPS=$((UI_STEPS + 1))
[ "$NO_PKGS" -eq 0 ]        && UI_STEPS=$((UI_STEPS + 1))
banner "dotfiles" "$DISTRO · $DESKTOP · re-running this is the normal update path"
info "$DISTRO / desktop=$DESKTOP / session=$SESSION_TYPE / vm=$IS_VM"
# This repo used to carry a fedora column too. It does not any more - the
# package names and the /etc drop-ins are CachyOS specific. Fail here rather
# than half-installing Arch names on something else.
[ "$PKG_COL" = arch ] ||
  die "this repo targets CachyOS (or Arch); detected '$DISTRO' -> column '$PKG_COL'"
[ "$DRY" -eq 1 ] && warn "DRY RUN - nothing will be changed"

# ── 1. distro prep (repos, pacman config, AUR helper) ────────────────────────
if [ -x "os/$DISTRO/prep.sh" ]; then
  step "distro prep ($DISTRO)"
  h=$(hash_of "os/$DISTRO/prep.sh")
  if stamp_ok "prep-$DISTRO" "$h"; then ok "already done"
  else run "os/$DISTRO/prep.sh" && stamp_set "prep-$DISTRO" "$h"; fi
elif [ "$DISTRO" = cachyos ]; then
  die "os/cachyos/prep.sh is missing or not executable"
else
  warn "no os/$DISTRO/prep.sh - skipping repo setup"
fi

# ── 2. packages ──────────────────────────────────────────────────────────────
if [ "$NO_PKGS" -eq 0 ]; then
  step "packages"
  MANIFESTS=(packages/core.tsv packages/dev.tsv packages/reliability.tsv)
  # NB: this used to be `[ "$DESKTOP" != none ] && MANIFESTS+=(desktop.tsv)`.
  # On a fresh install bootstrapped from a TTY, XDG_CURRENT_DESKTOP is unset,
  # so DESKTOP=none and the machine silently came up with no browser and no
  # terminal - with no error. This repo targets exactly one laptop and that
  # laptop has a GUI, so the desktop set is now the default.
  [ "$NO_DESKTOP" -eq 1 ] || MANIFESTS+=(packages/desktop.tsv)
  h=$(hash_of "${MANIFESTS[@]}")

  mapfile -t PKGS < <(pkg_resolve arch "${MANIFESTS[@]}")
  mapfile -t AUR  < <(pkg_resolve aur  "${MANIFESTS[@]}")

  # NB: `pacman -S a b c` is atomic - ONE unknown name aborts the whole
  # transaction and nothing installs. With ~90 names in the manifests that is
  # one typo away from a bootstrap that can never finish, so check first and
  # drop the bad names rather than letting them block everything else.
  # `pacman -Slq` lists every package in every configured repo; -Sgq adds group
  # names (base-devel), which are legal targets but are not packages.
  MISSING=()
  if [ "$NO_PKGS" -eq 0 ] && command -v pacman >/dev/null; then
    # NB: the database read is split out of the comm pipeline ONLY so it can be
    # spun - it is seconds long on a fresh sync, fully non-interactive, and its
    # output was already being discarded, which is exactly the shape spin() is
    # safe for. The comm itself is unchanged.
    _pkgdb=$(mktemp)
    spin "reading the package databases" \
      bash -c '{ pacman -Slq; pacman -Sgq; } 2>/dev/null | sort -u > "$1"' _ "$_pkgdb"
    mapfile -t MISSING < <(comm -23 \
      <(printf '%s\n' "${PKGS[@]}" | sort -u) \
      "$_pkgdb")
    rm -f "$_pkgdb"
    if [ "${#MISSING[@]}" -gt 0 ]; then
      warn "${#MISSING[@]} manifest name(s) not in any repo: ${MISSING[*]}"
      warn "continuing without them - fix packages/*.tsv"
      mapfile -t PKGS < <(comm -23 \
        <(printf '%s\n' "${PKGS[@]}" | sort -u) \
        <(printf '%s\n' "${MISSING[@]}" | sort -u))
    fi
  fi

  if stamp_ok "packages-arch" "$h"; then ok "repo manifests unchanged"
  else
    info "${#PKGS[@]} repo packages"
    # NB: -Syu, not -S. `pacman -S` against a stale sync DB either 404s on
    # moved mirrors or leaves a partial upgrade - the one thing Arch does not
    # survive. Folding the install into the full upgrade closes that window.
    run sudo pacman -Syu --needed --noconfirm "${PKGS[@]}" &&
      stamp_set "packages-arch" "$h"
  fi

  if [ "${#AUR[@]}" -gt 0 ]; then
    info "${#AUR[@]} AUR packages"
    if stamp_ok "packages-aur" "$h"; then ok "AUR manifests unchanged"
    elif command -v paru >/dev/null; then
      # NB: a separate transaction from pacman, deliberately. paru can build
      # repo packages too, but one AUR build that fails a PGP check or a
      # compile takes the whole transaction with it - and one of these is the
      # primary editor. Repo packages go in first, atomically; AUR is
      # best-effort on top, with its own stamp so a failed build retries
      # without re-running pacman.
      # NB: --skipreview is mandatory. Without it paru opens a pager on the
      # PKGBUILD diff and blocks forever under --noconfirm.
      # NB: never `sudo paru`. It calls sudo itself and refuses to build as root.
      run paru -S --needed --noconfirm --skipreview --sudoloop "${AUR[@]}" &&
        stamp_set "packages-aur" "$h"
    else
      warn "no AUR helper - build these by hand: ${AUR[*]}"
    fi
  fi

  # Manifest rows marked "-" have no package and install themselves from
  # upstream. This used to be a bare warn(); it is a real dispatch now.
  #
  # Two different reasons a row lands here, and they are worth telling apart:
  #   zed, claude-code - a package EXISTS (or could) but the vendor installer
  #     SELF-UPDATES in place, so pacman would only ever chase a version the
  #     app has already replaced underneath it.
  #   mint - no package exists anywhere, in any repo or the AUR. This is what
  #     "-" originally meant.
  # Either way they install ONCE; the guards below are what make re-running
  # bootstrap.sh a no-op rather than a reinstall that stomps a self-update.
  for u in $(pkg_unavailable arch "${MANIFESTS[@]}"); do
    case "$u" in
      zed)
        # Preview channel, deliberately - see packages/dev.tsv. The stable
        # `zed` in extra is a DIFFERENT app with its own config dir; installing
        # both is a supported but separate decision.
        if [ -x "$HOME/.local/zed-preview.app/bin/zed" ]; then
          ok "zed (preview) present - it self-updates, leaving it alone"
        else
          info "zed (preview) from zed.dev"
          # NB: -fsSL, matching the claude-code line below. Bare -f leaves the
          # progress meter in the bootstrap log and, without -L, a future
          # redirect would pipe an empty body straight into sh.
          # NB: ZED_CHANNEL goes on the RIGHT of the pipe. Prefixing curl scopes
          # it to curl, and the installer reads it in the sh on the other side,
          # so the wrong form silently installs stable.
          run sh -c 'curl -fsSL https://zed.dev/install.sh | ZED_CHANNEL=preview sh'
        fi ;;
      claude-code)
        if command -v claude >/dev/null 2>&1; then
          ok "claude code present - it self-updates, leaving it alone"
        else
          info "claude code from claude.ai/install.sh"
          run sh -c 'curl -fsSL https://claude.ai/install.sh | bash'
        fi ;;
      mint)
        # npm, not pacman - and deliberately NOT `sudo npm -g`, which writes
        # into /usr/lib/node_modules, a directory pacman owns and will fight
        # over on the next nodejs upgrade. NPM_CONFIG_PREFIX (set in dot_zshrc)
        # keeps it in ~/.npm-global; it is passed explicitly here because
        # bootstrap can run before that zshrc is ever sourced.
        if command -v mint >/dev/null 2>&1; then
          ok "mint present - upgrade with 'npm i -g mint@latest'"
        elif command -v npm >/dev/null 2>&1; then
          info "mint (Mintlify CLI) from npm"
          run env NPM_CONFIG_PREFIX="$HOME/.npm-global" npm install -g mint
        else
          warn "npm missing - cannot install mint"
        fi ;;
      *) warn "no package for '$u' - install it manually" ;;
    esac
  done
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
    # NB: "plasma" is the default and almost certainly what you want.
    # promptStringOnce caches the answer and never asks again, so a carried-over
    # ~/.config/chezmoi/chezmoi.toml keeps whatever the old machine said.
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
steps_end
step "remaining manual steps"
rule
cat <<'EOS'
  sudo ./system/apply.sh      /etc drop-ins + enable the units Arch ships disabled
  sudo usermod -aG docker "$USER"   then log out and back in
  sudo usermod -aG kvm "$USER"      only if you want Claude Desktop's Cowork tab;
                                    it runs its sandbox in a QEMU/KVM VM. Also needs
                                    virtualization enabled in the BIOS. Chat and
                                    Claude Code work without it.
  ./scripts/reclaim.sh        reclaim disk: pacman cache, orphans, coredumps
  ./scripts/secrets-setup.sh  generate an SSH key and sign in to GitHub
  ./scripts/git-credentials.sh  store a PAT per host so git stops prompting
  ./scripts/doctor.sh         verify everything
EOS
rule
