# shellcheck shell=bash
# Sets: DISTRO DISTRO_LIKE DESKTOP SESSION_TYPE IS_VM PKG_COL
detect_all() {
  # shellcheck disable=SC1091
  [ -r /etc/os-release ] && . /etc/os-release
  DISTRO="${ID:-unknown}"
  DISTRO_LIKE="${ID_LIKE:-}"
  case "${XDG_CURRENT_DESKTOP:-}" in
    *niri*)     DESKTOP=niri     ;;
    *Hyprland*) DESKTOP=hyprland ;;
    *KDE*)      DESKTOP=plasma   ;;
    *GNOME*)    DESKTOP=gnome    ;;
    *)          DESKTOP=none     ;;
  esac
  # NB: XDG_CURRENT_DESKTOP is unset under sudo and on a TTY, so the case above
  # yields "none" in exactly the two places that matter most: system/apply.sh
  # (runs as root) and a first bootstrap from a console. Fall back to asking the
  # process table, which does not care about the environment.
  [ "$DESKTOP" = none ] && pgrep -x plasmashell >/dev/null 2>&1 && DESKTOP=plasma
  SESSION_TYPE="${XDG_SESSION_TYPE:-tty}"
  IS_VM=no; command -v systemd-detect-virt >/dev/null 2>&1 &&
    [ "$(systemd-detect-virt)" != none ] && IS_VM=yes
  # This repo targets CachyOS. The arch/endeavouros aliases are kept because
  # they are the same package manager, not because dual-distro support exists.
  case "$DISTRO" in
    cachyos|arch|endeavouros) PKG_COL=arch ;;
    nixos)                    PKG_COL=nix  ;;
    # NB: the default used to be "fedora", which meant an unrecognised distro
    # silently got Fedora package names and failed halfway through an install.
    # "unknown" makes bootstrap.sh's guard die immediately and say why.
    *) case "$DISTRO_LIKE" in
         *arch*) PKG_COL=arch    ;;
         *)      PKG_COL=unknown ;;
       esac ;;
  esac
  export DISTRO DISTRO_LIKE DESKTOP SESSION_TYPE IS_VM PKG_COL
}
