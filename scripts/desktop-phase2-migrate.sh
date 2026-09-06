#!/usr/bin/env bash
# scripts/desktop-phase2-migrate.sh
#
# Automated, safety-gated implementation of Phase 2 from docs/DESKTOP.md:
# "Migrating the 1 TB disk into the game library"
#
# Stages:
#   Stage 1: Unmount rw, mount ro at /mnt/old, verify space gate (>=1.2x),
#            rsync to ~/Storage-staging on NVMe (excluding Windows junk).
#   Stage 2: Checksum verification: /tmp/old.sha256 vs /tmp/new.sha256.
#            HARD GATE: Aborts if any checksum does not match.
#   Stage 3: Unmount /mnt/old, format /dev/sda2 as ext4 (label: games),
#            configure /etc/fstab with UUID, mount /mnt/games,
#            restore data to /mnt/games/Storage, verify checksums again,
#            purge ~/Storage-staging.
#   Stage 4: Create /mnt/games/SteamLibrary and /mnt/games/Heroic.
#
# Usage:
#   sudo ./scripts/desktop-phase2-migrate.sh [--yes]

set -euo pipefail

# ── Safety Check: Must run as root ───────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "Error: This script must be run with sudo or as root to perform disk operations." >&2
  echo "Usage: sudo $0 [--yes]" >&2
  exit 1
fi

TARGET_DEV="/dev/sda2"
TARGET_DISK="/dev/sda"
OLD_MOUNT="/mnt/old"
NEW_MOUNT="/mnt/games"
AUTO_CONFIRM=false

for arg in "$@"; do
  case "$arg" in
    -y|--yes) AUTO_CONFIRM=true ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

# Resolve the non-root user running sudo
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
STAGING_DIR="$REAL_HOME/Storage-staging"

echo "=================================================================="
echo "  Desktop Phase 2 Migration: 1 TB HDD -> ext4 Game Library"
echo "=================================================================="
echo "Target partition : $TARGET_DEV"
echo "Target disk      : $TARGET_DISK"
echo "Staging area     : $STAGING_DIR"
echo "User             : $REAL_USER ($REAL_HOME)"
echo "=================================================================="

# ── Validate Device ──────────────────────────────────────────────────────────
if [[ ! -b "$TARGET_DEV" ]]; then
  echo "Error: Block device $TARGET_DEV does not exist!" >&2
  exit 1
fi

# Sanity check: Ensure we are not accidentally targeting an NVMe or root device
DEV_NAME=$(basename "$TARGET_DEV")
if [[ "$DEV_NAME" =~ ^nvme ]]; then
  echo "CRITICAL ERROR: $TARGET_DEV appears to be an NVMe drive! Aborting." >&2
  exit 1
fi

ROOT_DEV=$(findmnt -no SOURCE /)
if [[ "$ROOT_DEV" == "$TARGET_DEV" ]]; then
  echo "CRITICAL ERROR: $TARGET_DEV is currently mounted as root (/)! Aborting." >&2
  exit 1
fi

# ── Stage 1: Copy off, read-only ──────────────────────────────────────────────
echo ""
echo "==> [Stage 1/4] Preparing read-only source mount..."

# If currently mounted somewhere (e.g. /run/media/.../Personal), unmount it first
CURRENT_MOUNT=$(findmnt -no TARGET "$TARGET_DEV" 2>/dev/null || true)
if [[ -n "$CURRENT_MOUNT" ]]; then
  echo "Device $TARGET_DEV is currently mounted at $CURRENT_MOUNT. Unmounting..."
  umount "$CURRENT_MOUNT"
fi

mkdir -p "$OLD_MOUNT"
if ! findmnt -no TARGET "$OLD_MOUNT" >/dev/null 2>&1; then
  mount -o ro,noatime "$TARGET_DEV" "$OLD_MOUNT"
fi

# Verify read-only
if touch "$OLD_MOUNT/.ro_test" 2>/dev/null; then
  rm -f "$OLD_MOUNT/.ro_test"
  echo "Error: $OLD_MOUNT mounted writable! Expected read-only." >&2
  exit 1
fi
echo "✓ $TARGET_DEV safely mounted read-only at $OLD_MOUNT"

# Measure data size vs NVMe /home free space
echo "Measuring disk usage and checking space gate (>= 1.2x)..."
DATA_KB=$(df --output=used -k "$OLD_MOUNT" | tail -1 | tr -d ' ')
AVAIL_KB=$(df --output=avail -k "$REAL_HOME" | tail -1 | tr -d ' ')

DATA_GB=$(awk "BEGIN {printf \"%.1f\", $DATA_KB/1048576}")
AVAIL_GB=$(awk "BEGIN {printf \"%.1f\", $AVAIL_KB/1048576}")
RATIO=$(awk "BEGIN {printf \"%.2f\", $AVAIL_KB/$DATA_KB}")

echo "Data size        : ~${DATA_GB} GB"
echo "Free space (/home): ~${AVAIL_GB} GB"
echo "Space ratio      : ${RATIO}x (required >= 1.20x)"

if awk "BEGIN {exit !($AVAIL_KB < 1.2 * $DATA_KB)}"; then
  echo "CRITICAL ERROR: Free space on $REAL_HOME is less than 1.2x the source data!" >&2
  echo "Stop and use an external staging drive as per docs/DESKTOP.md." >&2
  exit 1
fi
echo "✓ Space gate passed (${RATIO}x >= 1.20x)"

mkdir -p "$STAGING_DIR"
chown "$REAL_USER:$REAL_USER" "$STAGING_DIR"

echo "Copying files from $OLD_MOUNT to $STAGING_DIR..."
echo "(Excluding \$RECYCLE.BIN and System Volume Information)"
rsync -aHAX \
  --info=progress2 \
  --exclude='$RECYCLE.BIN' \
  --exclude='System Volume Information' \
  "$OLD_MOUNT/" "$STAGING_DIR/" || {
    ret=$?
    if [[ $ret -eq 23 ]]; then
      echo "Note: rsync completed with exit code 23 (expected for Windows xattr/cache symlinks)."
    else
      echo "Error: rsync failed with exit code $ret" >&2
      exit "$ret"
    fi
  }

chown -R "$REAL_USER:$REAL_USER" "$STAGING_DIR"
echo "✓ Stage 1 complete: All data copied to staging."

# ── Stage 2: Verify by content, not by exit status ────────────────────────────
echo ""
echo "==> [Stage 2/4] Verifying data integrity by checksum manifests..."
echo "Generating SHA-256 manifest for source ($OLD_MOUNT)..."
echo "(Reading ~150 GB off the 5400 RPM HDD; this will take ~30-40 minutes, please wait...)"
(
  cd "$OLD_MOUNT"
  find . -type f \
    ! -path './$RECYCLE.BIN*' \
    ! -path './System Volume Information*' \
    | LC_ALL=C sort \
    | xargs -d'\n' sha256sum > /tmp/old.sha256
)

echo "Generating SHA-256 manifest for staging ($STAGING_DIR)..."
(
  cd "$STAGING_DIR"
  find . -type f \
    | LC_ALL=C sort \
    | xargs -d'\n' sha256sum > /tmp/new.sha256
)

echo "Comparing manifests..."
if ! diff -u /tmp/old.sha256 /tmp/new.sha256; then
  echo "" >&2
  echo "CRITICAL ERROR: Checksums do not match between source and staging!" >&2
  echo "The source disk HAS NOT been touched. Check /tmp/old.sha256 and /tmp/new.sha256." >&2
  exit 1
fi

echo "=================================================================="
echo "  IDENTICAL - SHA-256 matches perfectly. Safe to reformat."
echo "=================================================================="

# ── Stage 3: Reformat, and only then ──────────────────────────────────────────
echo ""
echo "==> [Stage 3/4] Reformatting $TARGET_DEV into ext4 (label: games)..."

if [[ "$AUTO_CONFIRM" != true ]]; then
  read -r -p "Are you ready to format $TARGET_DEV (ext4, games)? [y/N]: " confirm
  if [[ "$confirm" != [yY] && "$confirm" != [yY][eE][sS] ]]; then
    echo "Aborted by user. Data is intact in $OLD_MOUNT and $STAGING_DIR."
    exit 0
  fi
fi

echo "Unmounting $OLD_MOUNT..."
umount "$OLD_MOUNT"

echo "Formatting $TARGET_DEV as ext4..."
mkfs.ext4 -F -L games "$TARGET_DEV"

# Retrieve new UUID
NEW_UUID=$(blkid -s UUID -o value "$TARGET_DEV")
if [[ -z "$NEW_UUID" ]]; then
  echo "Error: Failed to obtain UUID for $TARGET_DEV!" >&2
  exit 1
fi
echo "New Filesystem UUID: $NEW_UUID"

# Backup and update /etc/fstab
FSTAB_BACKUP="/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
echo "Backing up /etc/fstab to $FSTAB_BACKUP..."
cp /etc/fstab "$FSTAB_BACKUP"

# If /mnt/games already exists in /etc/fstab, remove the old line
sed -i '\|[[:space:]]/mnt/games[[:space:]]|d' /etc/fstab
echo "UUID=$NEW_UUID  /mnt/games  ext4  defaults,noatime  0 2" >> /etc/fstab
echo "✓ Added /mnt/games entry to /etc/fstab"

mkdir -p "$NEW_MOUNT"
systemctl daemon-reload
mount "$NEW_MOUNT"
chown "$REAL_USER:$REAL_USER" "$NEW_MOUNT"

echo "Mount verification:"
findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS "$NEW_MOUNT"

# Restore data
echo "Restoring data to $NEW_MOUNT/Storage/..."
mkdir -p "$NEW_MOUNT/Storage"
chown "$REAL_USER:$REAL_USER" "$NEW_MOUNT/Storage"

rsync -aHAX --info=progress2 "$STAGING_DIR/" "$NEW_MOUNT/Storage/" || {
  ret=$?
  if [[ $ret -eq 23 ]]; then
    echo "Note: rsync completed with exit code 23."
  else
    echo "Error: rsync restore failed with exit code $ret" >&2
    exit "$ret"
  fi
}
chown -R "$REAL_USER:$REAL_USER" "$NEW_MOUNT/Storage"

# Verify restored data
echo "Verifying restored data against original manifest..."
(
  cd "$NEW_MOUNT/Storage"
  find . -type f | LC_ALL=C sort | xargs -d'\n' sha256sum > /tmp/final.sha256
)

if ! diff -u <(sed 's|  ./|  |' /tmp/old.sha256) <(sed 's|  ./|  |' /tmp/final.sha256); then
  echo "" >&2
  echo "WARNING: Restored data checksum differs from original manifest!" >&2
  echo "Staging copy preserved at $STAGING_DIR for safety. DO NOT DELETE YET." >&2
  exit 1
fi

echo "✓ Content verified! Restored data is identical."
echo "Purging staging copy at $STAGING_DIR..."
rm -rf "$STAGING_DIR"
echo "✓ Staging directory removed."

# ── Stage 4: Point the launchers at it ────────────────────────────────────────
echo ""
echo "==> [Stage 4/4] Creating launcher directory structure..."
mkdir -p "$NEW_MOUNT/SteamLibrary"
mkdir -p "$NEW_MOUNT/Heroic"
chown "$REAL_USER:$REAL_USER" "$NEW_MOUNT/SteamLibrary" "$NEW_MOUNT/Heroic"

echo ""
echo "=================================================================="
echo "  Phase 2 Migration Complete!"
echo "=================================================================="
echo "Filesystem mounted at : /mnt/games"
echo "Personal data at     : /mnt/games/Storage"
echo "Steam library path   : /mnt/games/SteamLibrary"
echo "Heroic library path  : /mnt/games/Heroic"
echo ""
echo "Remaining manual launcher steps (docs/DESKTOP.md):"
echo "  1. Steam  -> Settings -> Storage -> '+' -> /mnt/games/SteamLibrary"
echo "  2. Heroic -> Settings -> Default install path -> /mnt/games/Heroic"
echo "=================================================================="
