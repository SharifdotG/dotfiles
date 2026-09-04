#!/usr/bin/env bash
# Generate this machine's credentials. Nothing secret is ever stored in the repo:
# a fresh key per machine is better hygiene than syncing one, and it means this
# repo can be public.
set -uo pipefail
cd "$(dirname "$0")/.."
. lib/log.sh

EMAIL=$(git config --global user.email 2>/dev/null || true)
[ -n "$EMAIL" ] || read -r -p "Email for the SSH key: " EMAIL

step "SSH key"
if [ -f "$HOME/.ssh/id_ed25519" ]; then
  ok "~/.ssh/id_ed25519 already exists"
else
  ssh-keygen -t ed25519 -C "$EMAIL" -f "$HOME/.ssh/id_ed25519" && ok "key generated"
fi
info "Public key - add at https://github.com/settings/keys"
cat "$HOME/.ssh/id_ed25519.pub"

step "GitHub CLI"
if command -v gh >/dev/null; then
  gh auth status >/dev/null 2>&1 && ok "gh already authenticated" || gh auth login
else
  warn "gh not installed"
fi

step "Next"
echo "  ./scripts/git-credentials.sh   store a PAT for github.com and your private"
echo "                                 forge, so HTTPS git stops asking every time"

step "Not managed here (by design)"
cat <<'EOS'
  ~/.npmrc, ~/.nuget/NuGet.Config   registry tokens
  ~/.docker/config.json             registry credentials
  kwallet                           desktop secrets. On Plasma it is ksecretd that
                                    owns org.freedesktop.secrets, NOT gnome-keyring -
                                    which is why git-credentials.sh works here
  Brave profile                     use Brave Sync (a sync chain, not an account)
  Bitwarden vault                   sign in normally
EOS
steps_end
