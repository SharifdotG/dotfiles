#!/usr/bin/env bash
# Store a Personal Access Token per host so git stops asking on every fetch.
#
#   ./scripts/git-credentials.sh                 set up / refresh every host
#   ./scripts/git-credentials.sh --status        what is stored (never the token)
#   ./scripts/git-credentials.sh --forget HOST   drop one host's credential
#   ./scripts/git-credentials.sh --host HOST     add another host (repeatable)
#   ./scripts/git-credentials.sh --plaintext     opt in to the on-disk fallback
#
set -uo pipefail
cd "$(dirname "$0")/.."
. lib/log.sh

# WHERE THE SECRET GOES, and why not in this repo.
#
# The token is handed to git's credential helper, which puts it in the desktop
# keyring over the Secret Service API - the same place Plasma keeps everything
# else. Nothing is written into the dotfiles tree, which is the same rule
# scripts/secrets-setup.sh follows and the reason this repo can be public.
#
# WHY A SEPARATE FILE UNDER ~/.config/git AND NOT `git config --global`.
#
# `git config --global` writes ~/.gitconfig, and ~/.gitconfig is chezmoi's -
# it is generated from home/dot_gitconfig.tmpl. Anything this script wrote there
# would survive exactly until the next `chezmoi apply` and then vanish, which is
# the worst kind of bug: it works when you test it and is gone next week. So the
# machine-local half lives in its own file and dot_gitconfig.tmpl pulls it in
# with [include]. Git silently ignores an include path that does not exist
# (verified), so a machine that has never run this script is not broken by the
# include, it just has no helper configured.

INC="${XDG_CONFIG_HOME:-$HOME/.config}/git/credentials.inc"
CHEZMOI_TOML="${XDG_CONFIG_HOME:-$HOME/.config}/chezmoi/chezmoi.toml"

PLAINTEXT=0 STATUS=0 FORGET="" EXTRA_HOSTS=()
while [ $# -gt 0 ]; do case "$1" in
  --status)    STATUS=1 ;;
  --plaintext) PLAINTEXT=1 ;;
  --forget)    shift; FORGET="${1:-}"; [ -n "$FORGET" ] || die "--forget needs a host" ;;
  --host)      shift; [ -n "${1:-}" ] || die "--host needs a value"; EXTRA_HOSTS+=("$1") ;;
  -h|--help)   awk 'NR>1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
  *)           die "unknown flag: $1" ;;
esac; shift; done

banner "git credentials" "a PAT per host, stored in the desktop keyring"
[ "$(id -u)" -ne 0 ] || die "do not run me as root - these are YOUR credentials"
command -v git >/dev/null || die "git is required"

# ── which helper ─────────────────────────────────────────────────────────────
# libsecret is the one to want: the token is encrypted at rest and unlocked with
# the login session. Arch ships the helper inside the `git` package itself
# (/usr/lib/git-core/git-credential-libsecret) and lists libsecret and
# org.freedesktop.secrets as optdepends - so both have to actually be there.
# On Plasma 6 the Secret Service is provided by ksecretd, not gnome-keyring.
find_libsecret() {
  local d
  for d in "$(git --exec-path 2>/dev/null)" /usr/lib/git-core /usr/libexec/git-core; do
    [ -n "$d" ] && [ -x "$d/git-credential-libsecret" ] && { echo "$d/git-credential-libsecret"; return 0; }
  done
  return 1
}
secret_service_up() {
  command -v busctl >/dev/null 2>&1 &&
    busctl --user list 2>/dev/null | grep -q 'org\.freedesktop\.secrets'
}

HELPER=""
if [ "$PLAINTEXT" -eq 1 ]; then
  HELPER=store
elif LIBSECRET=$(find_libsecret); then
  if secret_service_up; then
    HELPER=libsecret
  else
    warn "found $LIBSECRET but nothing owns org.freedesktop.secrets on the session bus"
    warn "that is normal on a TTY - log into Plasma and re-run, or use --plaintext"
    die  "refusing to configure a helper that cannot reach a keyring"
  fi
else
  warn "git-credential-libsecret not found."
  warn "  Arch/CachyOS: it ships in the 'git' package; install its optdepend 'libsecret'"
  warn "  then re-run. packages/core.tsv lists it."
  warn "Or re-run with --plaintext to fall back to ~/.git-credentials (UNENCRYPTED)."
  die  "no keyring-backed helper available"
fi

# Talk to the HELPER DIRECTLY (`git credential-$HELPER get|store|erase`) rather
# than going through `git credential fill|approve|reject`. Two reasons, both
# learned the hard way:
#
#   1. `git credential fill` FALLS BACK TO PROMPTING when no helper has an
#      answer, and GIT_TERMINAL_PROMPT=0 does not stop it - that only blocks the
#      *terminal* prompt. Plasma exports SSH_ASKPASS=/usr/bin/ksshaskpass, so
#      git happily pops a KDE dialog instead, and a --status run that was
#      supposed to report "nothing stored" sits there waiting on a GUI. (That
#      same askpass fallback is the dialog this script exists to get rid of.)
#   2. `-c credential.helper=X` APPENDS to the helper list, it does not replace
#      it, so a forced helper does not isolate anything - any already-configured
#      helper still runs and can answer first.
#
# The direct call has neither problem: it returns exactly what that one helper
# has, and never prompts. It also works before `chezmoi apply` has written
# ~/.gitconfig, when the [include] naming the helper does not exist yet.
cred_helper() { git "credential-$HELPER" "$1"; }

# ── which hosts ──────────────────────────────────────────────────────────────
# github.com is always in. The private forge is deliberately NOT hardcoded: its
# hostname is machine-local data (chezmoi's `workGitHost`, answered at
# `chezmoi init`), because this repo is public and a hostname is inventory.
HOSTS=(github.com)
WORK_HOST=$(sed -n 's/^[[:space:]]*workGitHost[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' \
    "$CHEZMOI_TOML" 2>/dev/null | head -1)
[ -n "$WORK_HOST" ] && HOSTS+=("$WORK_HOST")
[ "${#EXTRA_HOSTS[@]}" -gt 0 ] && HOSTS+=("${EXTRA_HOSTS[@]}")

# ── modes that do not prompt ─────────────────────────────────────────────────
cred_get()   { printf 'protocol=https\nhost=%s\n\n' "$1" | cred_helper get 2>/dev/null; }
cred_erase() { printf 'protocol=https\nhost=%s\n\n' "$1" | cred_helper erase 2>/dev/null; }
cred_store() { printf 'protocol=https\nhost=%s\nusername=%s\npassword=%s\n\n' "$1" "$2" "$3" | cred_helper store; }

if [ -n "$FORGET" ]; then
  step "forget $FORGET"
  cred_erase "$FORGET"
  ok "dropped (if it was there); git will ask again for $FORGET"
  exit 0
fi

if [ "$STATUS" -eq 1 ]; then
  step "stored credentials ($HELPER)"
  note_helper=$(git config --get credential.helper 2>/dev/null)
  info "helper from git config: ${note_helper:-<none - run chezmoi apply?>}"
  info "machine-local file:     $INC$([ -f "$INC" ] || echo '  (missing)')"
  for h in "${HOSTS[@]}"; do
    out=$(cred_get "$h")
    u=$(printf '%s\n' "$out" | sed -n 's/^username=//p')
    p=$(printf '%s\n' "$out" | sed -n 's/^password=//p')
    if [ -n "$p" ]; then ok "$h  as '$u'  (token present, ${#p} chars)"
    else warn "$h  nothing stored"; fi
  done
  exit 0
fi

# ── write the machine-local include ──────────────────────────────────────────
step "helper"
mkdir -p "$(dirname "$INC")"
cat > "$INC" <<EOF
# Written by scripts/git-credentials.sh - machine-local, NOT in the dotfiles
# repo, and not managed by chezmoi. home/dot_gitconfig.tmpl [include]s it.
# Contains no secret: the token itself lives in the keyring, this only names
# the helper that knows how to fetch it.
[credential]
	helper = $HELPER
EOF
chmod 600 "$INC"
ok "$INC -> helper = $HELPER"
if [ "$HELPER" = store ]; then
  warn "PLAINTEXT MODE: the token will be written to ~/.git-credentials in the"
  warn "clear (mode 600). Anything that can read your home directory can read it."
fi
if ! git config --get credential.helper >/dev/null 2>&1; then
  warn "git does not see a helper yet - ~/.gitconfig has not been applied."
  warn "run 'chezmoi apply' (or bootstrap.sh) so the [include] is in place."
fi

# ── per-host tokens ──────────────────────────────────────────────────────────
cat <<'EOS'

  Create the tokens first, then paste them below. Nothing is echoed.

    github.com    https://github.com/settings/tokens
                  Fine-grained is fine. For pushing to your own repos the only
                  scope needed is Contents: read and write (classic: `repo`).
    private forge Gitea/Forgejo/GitLab all live under Settings -> Applications
                  or Access Tokens. Give it repository read/write, nothing more.

  Paste the token as the PASSWORD. The username is your account name on that
  host - for a PAT most forges ignore it, but git still asks for one.

EOS

for h in "${HOSTS[@]}"; do
  step "$h"
  existing=$(cred_get "$h")
  cur_user=$(printf '%s\n' "$existing" | sed -n 's/^username=//p')
  if [ -n "$(printf '%s\n' "$existing" | sed -n 's/^password=//p')" ]; then
    info "a token is already stored for $h as '$cur_user'"
    printf '    replace it? [y/N] '; read -r ans
    case "$ans" in [Yy]*) ;; *) ok "left alone"; continue ;; esac
  fi

  default_user="${cur_user:-}"
  printf '    username for %s%s: ' "$h" "${default_user:+ [$default_user]}"
  read -r u
  u="${u:-$default_user}"
  [ -n "$u" ] || { warn "no username given - skipping $h"; continue; }

  printf '    token (input hidden): '
  read -rs tok; echo
  [ -n "$tok" ] || { warn "no token given - skipping $h"; continue; }

  # erase first, so a REPLACEMENT token actually replaces rather than leaving
  # the helper with two entries and no defined winner.
  cred_erase "$h"
  cred_store "$h" "$u" "$tok"
  rc=$?
  tok=""; unset tok
  [ "$rc" -eq 0 ] || { warn "helper rejected the credential for $h"; continue; }

  # Read it straight back. A helper that silently stores nothing is the whole
  # failure mode this check exists for.
  back=$(cred_get "$h")
  if [ "$(printf '%s\n' "$back" | sed -n 's/^username=//p')" = "$u" ] &&
     [ -n "$(printf '%s\n' "$back" | sed -n 's/^password=//p')" ]; then
    ok "stored and read back for $h as '$u'"
  else
    warn "stored, but reading it back did not return it - check the keyring"
  fi
done

# gh installs its own per-host helper, which WINS over the global one for
# github.com. If both exist the PAT above is dead weight and any confusion about
# which token is in use starts here.
if gh_helper=$(git config --get-all 'credential.https://github.com.helper' 2>/dev/null) &&
   [ -n "$gh_helper" ]; then
  warn "credential.https://github.com.helper is set to: $gh_helper"
  warn "that takes precedence over the helper above for github.com."
  warn "run 'git config --global --unset-all credential.https://github.com.helper'"
  warn "if you want the PAT you just stored to be the one git uses."
fi

steps_end
step "done"
cat <<EOS
  Test it without changing anything:
      git ls-remote https://github.com/<you>/<repo>.git >/dev/null && echo ok

  Inspect later:  ./scripts/git-credentials.sh --status
  Revoke locally: ./scripts/git-credentials.sh --forget github.com
  Revoke for real: delete the token on the host - forgetting it here does not.
EOS
