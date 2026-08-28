# shellcheck shell=bash
# Sets: DISTRO DISTRO_LIKE DESKTOP SESSION_TYPE IS_VM PKG_COL
detect_all() {
  # shellcheck disable=SC1091
  [ -r /etc/os-release ] && . /etc/os-release
  DISTRO="${ID:-unknown}"
  DISTRO_LIKE="${ID_LIKE:-}"
  case "${XDG_CURRENT_DESKTOP:-}" in
    *KDE*)      DESKTOP=plasma   ;;
    *Hyprland*) DESKTOP=hyprland ;;
    *niri*)     DESKTOP=niri     ;;
    *GNOME*)    DESKTOP=gnome    ;;
    *)          DESKTOP=none     ;;
  esac
  SESSION_TYPE="${XDG_SESSION_TYPE:-tty}"
  IS_VM=no; command -v systemd-detect-virt >/dev/null 2>&1 &&
    [ "$(systemd-detect-virt)" != none ] && IS_VM=yes
  case "$DISTRO" in
    fedora|rhel|centos)      PKG_COL=fedora ;;
    arch|cachyos|endeavouros) PKG_COL=arch  ;;
    nixos)                    PKG_COL=nix   ;;
    *) case "$DISTRO_LIKE" in
         *fedora*|*rhel*) PKG_COL=fedora ;;
         *arch*)          PKG_COL=arch   ;;
         *)               PKG_COL=fedora ;;
       esac ;;
  esac
  export DISTRO DISTRO_LIKE DESKTOP SESSION_TYPE IS_VM PKG_COL
}
