# shellcheck shell=bash
# Which Nuvoton Super-I/O chip is on this board, answered by PROBING it.
#
# WHY THIS FILE EXISTS. Until 2026-09-05 the module was chosen like this:
#
#     if [[ "$_board_name" =~ [bB]450 ]]; then nct6775; else nct6687; fi
#
# That is a marketing string deciding which kernel module to insert at every
# boot, and the `else` is not a fallback - it is an unqualified assertion. Every
# board whose name does not contain "b450" was declared to have an NCT6687D,
# including boards with no Nuvoton chip at all, and including the case where
# board_name could not be READ (the empty string falls to the else). Loading a
# Super-I/O driver for a chip that is not there is not free: the driver and the
# ACPI EC can end up contending for the same index/data port pair.
#
# The honest question is "which driver BINDS", and it is answerable. Everything
# here only READS, so scripts/doctor.sh can use it too - the probe that actually
# inserts modules lives in system/apply.sh, the only thing in this repo that
# runs as root and is allowed to change the machine.

# Candidates, in probe order. nct6775 first because it is IN-TREE: it needs no
# DKMS build and is present on any running kernel. nct6687 is out-of-tree
# (nct6687d-dkms-git in packages/cpu-amd.tsv).
BOARD_SENSOR_MODS="nct6775 nct6687"

# Is this module installed for the RUNNING kernel?
#
# NB: scoped to /lib/modules/$(uname -r), NOT to all of /lib/modules. This box
# carries both a -cachyos and a -cachyos-lts tree, and an unscoped search
# counts a DKMS module built for the kernel you are NOT booted into. That makes
# the module look available, so a modules-load.d drop-in gets written for
# something that cannot load, and systemd-modules-load.service then fails at
# every boot - the exact failure this check exists to prevent, caused by the
# check itself.
board_sensor_available() {
  modinfo "$1" >/dev/null 2>&1 && return 0
  [ -n "$(find "/lib/modules/$(uname -r)" -name "$1.ko*" -print -quit 2>/dev/null)" ]
}

# Print the MODULE name of whichever board sensor driver is currently bound,
# or return 1.
#
# NB: this reads /sys/class/hwmon/*/name, not `lsmod`. lsmod says a module was
# INSERTED; it cannot say the module found hardware. nct6775 registers its hwmon
# under the name of the chip it actually detected - nct6775, nct6796, nct6797
# and so on - so the hwmon name is evidence and the module list is not.
board_sensor_bound() {
  local h n
  for h in /sys/class/hwmon/hwmon*; do
    [ -r "$h/name" ] || continue
    n=$(cat "$h/name" 2>/dev/null || true)
    case "$n" in
      nct6687) echo nct6687; return 0 ;;
      nct6106|nct6116|nct6775|nct6776|nct6779|nct679[1-9])
               echo nct6775; return 0 ;;
    esac
  done
  return 1
}

# Does a bound board driver actually publish a fan input?
#
# NB: bound is still not the same as useful, and this is the check that survives
# a driver which attaches to the chip and then reports nothing. It is
# deliberately scoped to the board driver's own hwmon - amdgpu publishes a fan1
# of its own, and counting that was how an earlier doctor.sh printed a green
# "board reports fan RPM" off the GPU fan on a machine with no board driver.
board_sensor_has_fan() {
  [ "$(board_sensor_fan_count)" -gt 0 ]
}

# How many fan inputs the board driver publishes. Prints a number, always.
#
# NB: reads hwmon sysfs rather than parsing `sensors` text, and that is not just
# tidiness. The `sensors` block is headed by the CHIP name (nct6797-isa-0290),
# while the module is nct6775 - so any text-scoping regex has to know the whole
# chip family or it silently matches nothing. sysfs sidesteps that entirely.
#
# NB: still scoped to the board driver's own hwmon. amdgpu publishes a fan1 of
# its own, and counting that was how an earlier doctor.sh printed a green
# "board reports fan RPM" off the GPU fan on a machine where the board driver
# had never loaded. A count the board driver's absence cannot change is not
# evidence about the board driver.
board_sensor_chip() {
  local h n
  for h in /sys/class/hwmon/hwmon*; do
    [ -r "$h/name" ] || continue
    n=$(cat "$h/name" 2>/dev/null || true)
    case "$n" in
      nct6687|nct6106|nct6116|nct6775|nct6776|nct6779|nct679[1-9])
        echo "$n"; return 0 ;;
    esac
  done
  return 1
}

board_sensor_fan_count() {
  local h n f c=0
  for h in /sys/class/hwmon/hwmon*; do
    [ -r "$h/name" ] || continue
    n=$(cat "$h/name" 2>/dev/null || true)
    case "$n" in
      nct6687|nct6106|nct6116|nct6775|nct6776|nct6779|nct679[1-9]) ;;
      *) continue ;;
    esac
    for f in "$h"/fan[0-9]_input; do
      [ -r "$f" ] && c=$((c + 1))
    done
  done
  echo "$c"
}
