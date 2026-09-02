#!/usr/bin/env bash
# Flash a provisioning image to an Adafruit Feather nRF52840 over SWD.
#
#   ./scripts/flash-feather.sh [build-dir] [--yes]
#
# THIS IS THE DESTRUCTIVE STEP. It chip-erases the part, which destroys the
# Adafruit UF2 bootloader, the MBR and the bootloader settings page. Run
# scripts/backup-nrf52840.sh first; without that backup the Adafruit bootloader
# is not coming back.
#
# Both images go down in ONE pyocd session, deliberately. On a revision 3 part
# APPROTECT is enabled in hardware at every reset, so a reset between the erase
# and the write can re-lock the debug port and leave you re-running recovery.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

TARGET=nrf52840
BUILD_DIR="${1:-build-feather-idle}"
ASSUME_YES=false
for a in "$@"; do [[ "$a" == "--yes" ]] && ASSUME_YES=true; done

die() { echo "error: $*" >&2; exit 1; }

command -v pyocd >/dev/null || die "pyocd not found. pip install --user pyocd"

BOOT_HEX="$BUILD_DIR/mcuboot/zephyr/zephyr.hex"
SLOT0_HEX="$BUILD_DIR/provision-slot0.hex"
[[ -f "$BOOT_HEX"  ]] || die "missing $BOOT_HEX -- run ./scripts/build-feather.sh provision"
[[ -f "$SLOT0_HEX" ]] || die "missing $SLOT0_HEX -- run ./scripts/build-feather.sh provision"

# Refuse to be the reason a board is unrecoverable.
#
# Look for the FILES a restore actually needs, not for a directory name. The
# previous version globbed `nrf52840-backup-*`, which is what backup-nrf52840.sh
# defaults to -- but the script takes an optional output directory, so a backup
# taken as `./scripts/backup-nrf52840.sh feather-backup` was invisible to this
# guard. A safety check that silently fails to see a real backup is worse than no
# check, because it teaches you to pass --yes.
find_backup() {
  local d
  for d in "$REPO"/*/ "$REPO"/../*/; do
    [[ -f "$d/flash_full.bin" && -f "$d/uicr.bin" ]] && { echo "${d%/}"; return 0; }
  done
  return 1
}

if BACKUP_DIR="$(find_backup)"; then
  echo "  backup:    $BACKUP_DIR (flash_full.bin + uicr.bin)"
  if [[ -f "$BACKUP_DIR/BACKUP.sha256" ]]; then
    # Verify it rather than trusting its presence: a truncated backup restores
    # to a brick just as thoroughly as no backup at all.
    if ( cd "$BACKUP_DIR" && sha256sum --quiet -c BACKUP.sha256 ) 2>/dev/null; then
      echo "  checksums: verified"
    else
      echo "!! $BACKUP_DIR/BACKUP.sha256 does NOT match the files beside it."
      $ASSUME_YES || die "refusing to flash against a backup that fails its own checksum"
    fi
  else
    echo "  checksums: none recorded (no BACKUP.sha256)"
  fi
else
  echo "!! No backup found: no directory beside or above the repo holds both"
  echo "   flash_full.bin and uicr.bin."
  echo "   This erase destroys the Adafruit UF2 bootloader and its UICR settings."
  echo "   Take a backup first:  ./scripts/backup-nrf52840.sh"
  echo
  $ASSUME_YES || die "refusing to flash without a backup (override with --yes)"
  echo "   --yes given; proceeding anyway."
fi

echo "=== about to flash, over SWD ==="
echo "  target:    $TARGET"
echo "  bootloader $BOOT_HEX"
echo "  slot 0     $SLOT0_HEX  (confirmed)"
echo "  chip erase: YES -- the Adafruit bootloader will be gone"
echo
if ! $ASSUME_YES; then
  read -r -p "Type 'flash' to continue: " reply
  [[ "$reply" == "flash" ]] || die "aborted"
fi

# One session, both files: chip erase, program bootloader and slot 0, reset once
# at the end. CONNECT_MODE=under-reset if the part is being awkward about
# attaching -- see docs/PROVISIONING.md.
pyocd flash -t "$TARGET" --erase chip \
  ${CONNECT_MODE:+--connect "$CONNECT_MODE"} \
  "$BOOT_HEX" "$SLOT0_HEX"

echo
echo "=== flashed. What should happen now ==="
echo "  MCUboot boots, finds a confirmed image in slot 0, and runs it."
echo "  The board should enumerate two USB interfaces:"
echo "    runtt-mgmt   SMP management"
echo "    runtt-log    application log output"
echo
echo "  Check it answers the contract:"
echo "    ls /dev/runtt/"
echo "    cargo run -p runtt-smp --example ping -- /dev/runtt/*-mgmt"
echo
echo "  Expect echo -> \"runtt\" and a describe line naming the board."
