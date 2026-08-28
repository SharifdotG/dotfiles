#!/usr/bin/env bash
# Fedora: repositories and dnf settings that must exist before packages install.
set -uo pipefail
cd "$(dirname "$0")/../.."
. lib/log.sh

FEDORA_VER=$(rpm -E %fedora)

step "dnf settings"
# NOTE two deliberate omissions vs. the usual advice:
#  - fastestmirror: not needed on dnf5; the mirror manager geo-routes already and
#    the option mostly adds latency to every transaction.
#  - install_weak_deps=False: on KDE it silently skips firmware, codecs and Plasma
#    integration. Use --setopt=install_weak_deps=False per-command instead.
for kv in max_parallel_downloads=10 defaultyes=True countme=false; do
  k=${kv%%=*}
  if grep -q "^$k=" /etc/dnf/dnf.conf 2>/dev/null; then
    ok "$k already set"
  else
    echo "$kv" | sudo tee -a /etc/dnf/dnf.conf >/dev/null && ok "set $kv"
  fi
done

step "RPM Fusion + codecs"
if rpm -q rpmfusion-free-release >/dev/null 2>&1; then
  ok "rpmfusion already present"
else
  sudo dnf install -y \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VER}.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VER}.noarch.rpm" &&
    ok "rpmfusion enabled"
fi

step "VS Code repo"
if [ -f /etc/yum.repos.d/vscode.repo ]; then
  ok "vscode repo present"
else
  sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
  sudo tee /etc/yum.repos.d/vscode.repo >/dev/null <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
autorefresh=1
type=rpm-md
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
  ok "vscode repo added"
fi

step "Docker CE repo"
if [ -f /etc/yum.repos.d/docker-ce.repo ]; then
  ok "docker-ce repo present"
else
  sudo dnf install -y dnf-plugins-core
  sudo dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo &&
    ok "docker-ce repo added"
fi

ok "Fedora prep complete"
