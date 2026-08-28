#!/usr/bin/env bash
# Flash a .uf2 to an RP2040 in BOOTSEL mode.
#
# Exists because the obvious `cp` is subtly wrong. cp returns once the data is
# in the page cache, not once it has reached the device, and the RP2040 bootrom
# writes each UF2 block as it arrives and reboots only when it has received them
# all. A truncated transfer therefore fails SILENTLY: the copy succeeds, the
# board sits in BOOTSEL waiting for blocks that never come, or -- worse -- it
# reboots having written only the early part of the image, leaving a board that
# looks flashed and is not.
#
# That cost an hour of debugging a bootloader that was behaving perfectly.
#
#   ./scripts/flash-pico.sh build-pico-mcuboot/provision.uf2
set -euo pipefail

UF2="${1:-}"
[[ -n "$UF2" && -f "$UF2" ]] || { echo "usage: $0 <image.uf2>" >&2; exit 2; }

# The bootrom presents a small FAT volume labelled RPI-RP2.
DEV="$(readlink -f /dev/disk/by-label/RPI-RP2 2>/dev/null || true)"
if [[ -z "$DEV" ]]; then
  cat >&2 <<'MSG'
No RPI-RP2 volume found. The board is not in BOOTSEL mode.

  Hold the BOOTSEL button while plugging the board in, then try again.
  A board that failed a previous flash is usually ALREADY in BOOTSEL --
  check with: lsusb | grep 2e8a:0003
MSG
  exit 1
fi
echo "found RPI-RP2 on $DEV"

MOUNT="$(findmnt -rn -o TARGET "$DEV" 2>/dev/null || true)"
UNMOUNT_AFTER=0
if [[ -z "$MOUNT" ]]; then
  # No desktop auto-mounter on a headless box, so mount it ourselves. udisksctl
  # needs a polkit agent, which needs a terminal -- hence running this by hand.
  udisksctl mount -b "$DEV" >/dev/null
  MOUNT="$(findmnt -rn -o TARGET "$DEV")"
  UNMOUNT_AFTER=1
fi
echo "mounted at $MOUNT"

SIZE=$(stat -c %s "$UF2")
echo "writing $UF2 ($SIZE bytes)..."

# oflag=sync forces each write out rather than trusting the page cache. Slower,
# and the whole point.
dd if="$UF2" of="$MOUNT/$(basename "$UF2")" bs=64k oflag=sync status=none 2>/dev/null || true
sync 2>/dev/null || true

# The board reboots the instant it has every block, so the volume vanishing here
# is the success case, not an error.
sleep 2
if [[ $UNMOUNT_AFTER -eq 1 ]]; then
  udisksctl unmount -b "$DEV" >/dev/null 2>&1 || true
fi

if [[ -e /dev/disk/by-label/RPI-RP2 ]]; then
  echo
  echo "WARNING: the board is still in BOOTSEL." >&2
  echo "The bootrom is waiting for blocks it never received, which means the" >&2
  echo "transfer was incomplete. Re-run; if it persists the image may be" >&2
  echo "malformed rather than truncated." >&2
  exit 1
fi

echo "board rebooted — flash accepted"
echo
echo "check what came up:"
echo "  lsusb | grep 2fe3"
echo "  ls /dev/balena-mcu/"
