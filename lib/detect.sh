# shellcheck shell=bash
# Sets: DISTRO DISTRO_LIKE DESKTOP SESSION_TYPE IS_VM PKG_COL
#       PROFILE CPU_VENDOR GPU HW_TUNING

# Normalise a number the KERNEL printed - hex "0x..." or decimal - to decimal.
#
# WHY THIS EXISTS, and it is not hypothetical. A module parameter declared
# `hexint` is printed by sysfs as 0x..., and amdgpu's ppfeaturemask is one.
# system/apply.sh compared that raw string against the DECIMAL literal
# 4294967295, which is never equal, so its "is the initramfs stale?" test was
# permanently true - it regenerated the initramfs on every run and eventually
# pushed a power-management mask onto the GPU that hung it in a reset loop.
# scripts/doctor.sh read the SAME file correctly, via printf '%d', so the two
# halves of this repo disagreed about one fact for as long as nobody compared
# them. One helper, used by both, is how that stops being possible.
#
# Prints a decimal number, always. Returns 1 when the input was not a number, so
# "the kernel said 0" and "I could not parse that" stay distinguishable.
#
# NB: TWO traps here, and the first draft of this function fell into both.
#
# 1. `printf '%d' 010` is EIGHT in bash - a leading zero means octal. sysfs is
#    full of zero-padded values, so the decimal branch forces base 10 with 10#.
#    (Checking this at a zsh prompt will tell you 10 and be no help at all: zsh's
#    printf does not do the octal thing. These scripts run under bash.)
# 2. `printf '%d' garbage || echo 0` prints "0" TWICE - once from printf, which
#    emits 0 *and* fails, and once from the fallback. That is precisely the
#    `grep -c` two-line trap scripts/doctor.sh documents and then warns about;
#    the fix is to validate the string first and only ever call printf on input
#    already known to be good.
num() {
  local v="${1-}"
  v="${v//[[:space:]]/}"
  case "$v" in
    0[xX][0-9a-fA-F]*) printf '%d' "$v"; return 0 ;;
    [0-9]*)
      case "$v" in *[!0-9]*) echo 0; return 1 ;; esac
      printf '%d' "$((10#$v))"; return 0 ;;
  esac
  echo 0
  return 1
}

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

  # ── which machine is this ──────────────────────────────────────────────────
  # Three axes, all read from the KERNEL, none of them a name.
  #
  # NB: chezmoi's own documentation reaches for .chezmoi.hostname here, and that
  # is the obvious answer. It is the wrong one for THIS repo: the repo is public
  # and already treats a hostname as inventory disclosure - that is exactly why
  # workGitHost is prompted at `chezmoi init` instead of being committed (see
  # home/.chezmoi.toml.tmpl). Chassis, CPU vendor and PCI vendor id say what the
  # machine IS without saying which machine it is.
  #
  # NB: PROFILE, CPU_VENDOR and GPU are three variables and not one, on purpose.
  # `thermald` is an Intel-CPU fact. LIBVA_DRIVER_NAME is a GPU fact. Neither is
  # a "laptop" fact. Folding them into one profile name is how the third machine
  # silently gets the wrong driver.

  # Order: explicit override, then /etc (which system/apply.sh can still read as
  # root, where ~/.config/chezmoi cannot be reached), then the hardware.
  PROFILE="${DOTFILES_PROFILE:-}"
  if [ -z "$PROFILE" ] && [ -r /etc/dotfiles-profile ]; then
    PROFILE=$(tr -d '[:space:]' < /etc/dotfiles-profile 2>/dev/null)
  fi
  if [ -z "$PROFILE" ]; then
    # SMBIOS chassis types: 8 portable, 9 laptop, 10 notebook, 11 hand-held,
    # 14 sub-notebook. Everything else (3 desktop, 4 low-profile, 6 mini-tower,
    # 7 tower) is a desktop as far as this repo is concerned.
    case "$(cat /sys/class/dmi/id/chassis_type 2>/dev/null)" in
      8|9|10|11|14) PROFILE=laptop ;;
      # NB: the battery check is the FALLBACK, not the primary. A desktop on a
      # UPS can present a power_supply node too, so DMI gets asked first and the
      # battery only decides when the board reports a chassis type this does not
      # recognise (which OEMs do get wrong).
      *) if ls -d /sys/class/power_supply/BAT* >/dev/null 2>&1
         then PROFILE=laptop
         else PROFILE=desktop
         fi ;;
    esac
  fi

  # DOTFILES_CPU_VENDOR overrides, symmetric with the other two. All three
  # exist so the machine you are NOT sitting at can be dry-run from the one you
  # are: `DOTFILES_PROFILE=desktop DOTFILES_CPU_VENDOR=amd DOTFILES_GPU=amd
  # ./bootstrap.sh --dry-run` resolves the whole desktop package set on the
  # laptop, which is the only way to review it before the hardware exists.
  CPU_VENDOR="${DOTFILES_CPU_VENDOR:-}"
  if [ -z "$CPU_VENDOR" ]; then
    case "$(awk -F': ' '/^vendor_id/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)" in
      GenuineIntel) CPU_VENDOR=intel   ;;
      AuthenticAMD) CPU_VENDOR=amd     ;;
      *)            CPU_VENDOR=unknown ;;
    esac
  fi

  # PCI vendor ids: 0x8086 Intel, 0x1002 AMD/ATI, 0x10de NVIDIA.
  # NB: glob card* rather than card[0-9]*, and guard with -r. Connector nodes
  # (card1-eDP-1, card1-HDMI-A-2) also match card*, but they have no
  # device/vendor, so the guard is what filters them - verified on the T490s,
  # where only card1 and renderD128 carry the file.
  # DOTFILES_GPU is a top-level override, symmetric with DOTFILES_PROFILE.
  # It exists mostly so the desktop's code path can be exercised from the
  # laptop before the desktop is built - `DOTFILES_GPU=amd ./bootstrap.sh
  # --dry-run` is a real test, and one that caught a bug in this very file.
  GPU="${DOTFILES_GPU:-}"
  _gpus=()
  for _v in /sys/class/drm/card*/device/vendor; do
    [ -r "$_v" ] || continue
    case "$(cat "$_v" 2>/dev/null)" in
      0x8086) _g=intel  ;;
      0x1002) _g=amd    ;;
      0x10de) _g=nvidia ;;
      *)      continue  ;;
    esac
    # dedupe: a card node and its render node are the same PCI device
    case " ${_gpus[*]} " in *" $_g "*) ;; *) _gpus+=("$_g") ;; esac
  done
  if [ -z "$GPU" ]; then
    case "${#_gpus[@]}" in
      0) GPU=none ;;
      1) GPU="${_gpus[0]}" ;;
      # NB: "mixed" rather than a guess. On a hybrid machine the right VA-API
      # driver is the iGPU's and the right Vulkan driver is the dGPU's, and
      # there is no single answer to encode here. Neither machine this repo
      # targets is hybrid, so say so loudly instead of picking one and being
      # quietly wrong for a year. DOTFILES_GPU is the escape hatch.
      *) GPU=mixed ;;
    esac
  fi
  unset _v _g _gpus

  # ── may this repo change how the KERNEL drives the hardware? ───────────────
  # Default no, and the default is the whole point.
  #
  # WHY. On 2026-09-05 a plain `sudo ./system/apply.sh` wrote
  # amdgpu.ppfeaturemask=0xffffffff into /etc/modprobe.d, regenerated the
  # initramfs, and after the next reboot the desktop hung and reset its GPU
  # every ten seconds - the amdgpu lockup_timeout - until the drop-in was
  # removed. Nothing about that run looked unusual; the tweak was applied
  # because the machine was an AMD desktop, which is not consent.
  #
  # So: package installs, /etc drop-ins and unit enabling stay unconditional,
  # because they are recoverable from a TTY. Anything that changes a kernel
  # module PARAMETER, a power-management mask, or the contents of the initramfs
  # is gated on this and is OFF unless somebody deliberately turned it on. A
  # fresh bootstrap of a clean machine must not be able to destabilise hardware.
  #
  # Same precedence as PROFILE above: env override, then /etc (readable under
  # sudo, where ~/.config is not), then the safe default.
  HW_TUNING="${DOTFILES_HW_TUNING:-}"
  if [ -z "$HW_TUNING" ] && [ -r /etc/dotfiles-hw-tuning ]; then
    HW_TUNING=$(tr -d '[:space:]' < /etc/dotfiles-hw-tuning 2>/dev/null)
  fi
  case "$HW_TUNING" in
    on|1|yes|true) HW_TUNING=on ;;
    *)             HW_TUNING=off ;;
  esac

  export DISTRO DISTRO_LIKE DESKTOP SESSION_TYPE IS_VM PKG_COL \
         PROFILE CPU_VENDOR GPU HW_TUNING
}
