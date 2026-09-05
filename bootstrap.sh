#!/usr/bin/env bash
# Configure a CachyOS machine from this repo.
#
#   git clone <this repo> ~/dotfiles && ~/dotfiles/bootstrap.sh
#
# Flags: --dry-run  --no-packages  --no-desktop  --no-gaming  --no-creative
#        --profile=laptop|desktop  --force
# Idempotent: safe to re-run, and re-running is the normal update path.
#
# Two machines share this repo. Which one you are on is DETECTED from the
# hardware (see lib/detect.sh), never from a hostname - so a fresh machine is
# correct with no setup step. --profile forces it; so does DOTFILES_PROFILE.
set -uo pipefail
cd "$(dirname "$0")"
REPO="$PWD"
. lib/log.sh
. lib/detect.sh
. lib/pkg.sh

DRY=0 NO_PKGS=0 NO_DESKTOP=0 NO_GAMING=0 NO_CREATIVE=0 FORCE=0
for a in "$@"; do case "$a" in
  --dry-run)     DRY=1 ;;
  --no-packages) NO_PKGS=1 ;;
  --no-desktop)  NO_DESKTOP=1 ;;
  --no-gaming)   NO_GAMING=1 ;;
  --no-creative) NO_CREATIVE=1 ;;
  # NB: exported, not a local, because lib/detect.sh reads DOTFILES_PROFILE as
  # the highest-precedence source. One code path decides the profile, and it
  # lives in detect.sh - this flag just feeds it.
  --profile=*)   export DOTFILES_PROFILE="${a#*=}" ;;
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
banner "dotfiles" "$DISTRO · $PROFILE · re-running this is the normal update path"
info "$DISTRO / desktop=$DESKTOP / session=$SESSION_TYPE / vm=$IS_VM"
info "profile=$PROFILE / cpu=$CPU_VENDOR / gpu=$GPU"
case "$PROFILE" in
  laptop|desktop) ;;
  *) die "unknown profile '$PROFILE' - expected laptop or desktop.
       Detection reads /sys/class/dmi/id/chassis_type and
       /sys/class/power_supply/. Override with --profile=desktop or by
       putting one word in /etc/dotfiles-profile." ;;
esac
# NB: not fatal. A GPU this does not recognise still gets core, dev and the
# desktop set - it just gets no vendor manifest and no VA-API driver name. Say
# so rather than dying, because that machine is still usable.
case "$GPU" in
  none|mixed) warn "GPU detected as '$GPU' - no packages/gpu-*.tsv will be selected" ;;
esac

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
  # terminal - with no error. Both machines this repo targets have a GUI, so
  # the desktop set is the default.
  # NB: packages/desktop.tsv is the graphical SESSION, on both machines. The
  # desktop MACHINE's extra sets are gaming.tsv and creative.tsv, below.
  [ "$NO_DESKTOP" -eq 1 ] || MANIFESTS+=(packages/desktop.tsv)

  # Hardware axes. Separate from the profile on purpose: thermald is an
  # Intel-CPU fact and the VA-API driver is a GPU fact, and neither is a
  # "laptop" fact. Missing file = nothing to add, which is the correct answer
  # for an unrecognised vendor rather than an error.
  for m in "packages/cpu-$CPU_VENDOR.tsv" "packages/gpu-$GPU.tsv"; do
    [ -f "$m" ] && MANIFESTS+=("$m")
  done

  # Role axis. Only the desktop machine gets these.
  if [ "$PROFILE" = desktop ]; then
    [ "$NO_GAMING" -eq 1 ]   || MANIFESTS+=(packages/gaming.tsv)
    [ "$NO_CREATIVE" -eq 1 ] || MANIFESTS+=(packages/creative.tsv)
  fi

  info "manifests: ${MANIFESTS[*]#packages/}"
  # NB: the stamp is a hash of the manifest CONTENTS, so it needs no profile in
  # its key - a different machine selects a different file list and therefore
  # hashes differently. $STAMPS is already under XDG_STATE_HOME, which is
  # per-machine anyway.
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

  # ── packages this machine must NOT have ────────────────────────────────────
  # Everything above this point is additive. Deleting a row from core.tsv stops
  # bootstrap REINSTALLING that package; it does not take it off a disk that
  # already has it, and pacman has no notion of "the manifest is the whole
  # truth" that would do it for us. packages/unwanted.tsv is the other
  # direction - the only reason `git pull && ./bootstrap.sh` can ever leave this
  # machine with LESS on it than it started with.
  #
  # Deliberately NOT stamped, unlike every other step here. The whole thing is
  # one `pacman -Qq` per row against a list a handful long; on a clean machine
  # it finds nothing and does nothing, so it is already a no-op on re-run. A
  # stamp would buy no time and would teach it to ignore a package that came
  # back - which is the one case it exists to catch.
  mapfile -t UNWANTED < <(pkg_resolve arch packages/unwanted.tsv)
  PURGE=()
  for u in "${UNWANTED[@]}"; do
    pacman -Qq "$u" >/dev/null 2>&1 && PURGE+=("$u")
  done
  if [ "${#PURGE[@]}" -eq 0 ]; then
    ok "no unwanted packages installed"
  else
    info "${#PURGE[@]} unwanted package(s): ${PURGE[*]}"
    # NB: -Rns, and each flag is load-bearing.
    #   -s  also drops dependencies nothing else needs any more - the reclaim
    #   -n  deletes the package's own /etc files instead of leaving .pacsave
    # NB: no --cascade, ever. WITHOUT it pacman refuses to remove a package
    # something else depends on; WITH it, pacman removes the dependent too - so
    # on this machine one careless manifest row could take the Plasma edition
    # out. That refusal is the safety net, which is why the row for alacritty
    # in unwanted.tsv leaves cachyos-alacritty-config alone.
    #
    # NB: `pacman -R` is atomic exactly like `pacman -S`, so one package pinned
    # by a dependency aborts the transaction and NOTHING is removed. Same trap
    # the MISSING check above exists for, same answer: fall back to one at a
    # time so a single blocked row cannot hold the rest hostage.
    if ! run sudo pacman -Rns --noconfirm "${PURGE[@]}"; then
      warn "batch removal failed - retrying one at a time"
      for u in "${PURGE[@]}"; do
        run sudo pacman -Rns --noconfirm "$u" ||
          warn "could not remove '$u' - something still depends on it"
      done
    fi
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
  CHEZMOI_TOML="${XDG_CONFIG_HOME:-$HOME/.config}/chezmoi/chezmoi.toml"
  if [ -d "${XDG_CONFIG_HOME:-$HOME/.config}/chezmoi" ]; then
    # NB: a machine set up before the laptop/desktop split has a stored
    # chezmoi.toml with no `profile` key, and `chezmoi apply` would then abort
    # with "map has no entry for key" the moment it hit a template that reads
    # .profile - on a machine that was working five minutes earlier. `chezmoi
    # init` re-renders the config from .chezmoi.toml.tmpl; promptStringOnce
    # keeps every answer already stored, so this only ADDS the new keys and
    # asks nothing. Idempotent, and a no-op once the key is there.
    if ! grep -q '^[[:space:]]*profile[[:space:]]*=' "$CHEZMOI_TOML" 2>/dev/null; then
      info "stored chezmoi config predates the machine profile - re-running init"
      run chezmoi init --source "$REPO" \
        --promptString "profile=$PROFILE" --promptString "gpu=$GPU"
    fi
    run chezmoi apply --source "$REPO"
  else
    info "first run - chezmoi will prompt for name/email/desktop"
    # NB: "plasma" is the default and almost certainly what you want.
    # promptStringOnce caches the answer and never asks again, so a carried-over
    # ~/.config/chezmoi/chezmoi.toml keeps whatever the old machine said.
    #
    # NB: profile and gpu are PASSED, not prompted. .chezmoi.toml.tmpl can
    # detect them itself (it shells out to the same sysfs reads), but then two
    # code paths would decide the same fact and could disagree. Feeding
    # detect.sh's answer in means there is exactly one decision, made here.
    # --promptString supplies the value, so promptStringOnce does not ask.
    run chezmoi init --apply --source "$REPO" \
      --promptString "profile=$PROFILE" --promptString "gpu=$GPU"
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
  ./scripts/secrets-setup.sh  sign in to GitHub - gh auth login, over HTTPS
  ./scripts/git-credentials.sh  a PAT per host (github.com + the private forge),
                                into the keyring - this is the auth path, not SSH
  ./scripts/doctor.sh         verify everything
EOS
if [ "$PROFILE" = desktop ]; then
cat <<'EOS'

  -- desktop only ------------------------------------------------------------
  docs/DESKTOP.md              migrating the 1 TB disk off NTFS and turning it
                               into the game library, LACT, board sensors, and
                               where Steam and Heroic put their games
EOS
fi
rule
