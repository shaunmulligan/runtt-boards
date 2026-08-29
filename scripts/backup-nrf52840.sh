#!/usr/bin/env bash
# Back up an nRF52840 before the first destructive flash, and read the two
# registers that decide whether recovery will be painful.
#
#   ./scripts/backup-nrf52840.sh [outdir]
#   ./scripts/backup-nrf52840.sh --check      # tooling only, no board needed
#
# RUN THIS BEFORE FLASHING MCUBOOT TO 0x0. That flash destroys the Adafruit UF2
# bootloader, the MBR and the bootloader settings page. The only route back is
# restoring these images.
#
# UICR matters as much as flash: it holds BOOTLOADERADDR, and a flash restored
# without it leaves the Adafruit bootloader present but unfindable.
set -euo pipefail

TARGET=nrf52840
FLASH_SIZE=0x100000       # 1 MB internal flash
UICR_ADDR=0x10001000
UICR_SIZE=0x400
FICR_VARIANT=0x10000130   # FICR.INFO.VARIANT -- build code, e.g. "AAF0"
UICR_APPROTECT=0x10001208

die() { echo "error: $*" >&2; exit 1; }

command -v pyocd >/dev/null || die "pyocd not found. pip install --user pyocd"

if [[ "${1:-}" == "--check" ]]; then
  echo "pyocd: $(pyocd --version)"
  echo "probes:"; pyocd list || true
  echo
  echo "Tooling looks present. Re-run without --check, with the board attached,"
  echo "to take the backup."
  exit 0
fi

OUTDIR="${1:-nrf52840-backup-$(date +%Y%m%d-%H%M%S)}"
[[ -e "$OUTDIR" ]] && die "$OUTDIR already exists; refusing to overwrite a backup"
mkdir -p "$OUTDIR"
cd "$OUTDIR"

# read32 prints a line like: 10000130: 0041414630
read_word() {
  pyocd cmd -t "$TARGET" -c "read32 $1" 2>/dev/null \
    | grep -oE '0x[0-9a-fA-F]{8}' | tail -1
}

echo "=== 1. Identify the part, before touching anything ==="
variant_raw=$(read_word "$FICR_VARIANT" || true)
approtect_raw=$(read_word "$UICR_APPROTECT" || true)
[[ -n "$variant_raw" ]] || die "could not read FICR over SWD -- is the probe wired and the board powered?"

# VARIANT is four packed ASCII bytes, big-endian, e.g. 0x41414630 = "AAF0".
variant_ascii=$(python3 -c "
v = int('$variant_raw', 16)
print(''.join(chr((v >> s) & 0xff) for s in (24, 16, 8, 0)))
")
echo "  FICR.INFO.VARIANT = $variant_raw (\"$variant_ascii\")"
echo "  UICR.APPROTECT    = ${approtect_raw:-unreadable}"
echo

case "$variant_ascii" in
  *F0)
    echo "  !! Build code ends F0: this is a revision 3 (or later) part."
    echo "     APPROTECT is enabled in hardware at every reset, and a chip erase"
    echo "     resets UICR.APPROTECT, so the part can re-lock between an erase and"
    echo "     the next write. Recovery is a CTRL-AP ERASEALL, which wipes flash"
    echo "     AND UICR -- which is what this backup is for."
    echo "     Do NOT reset the board between an ERASEALL and writing firmware."
    ;;
  *) echo "  Build code does not end F0; the rev-3 APPROTECT hardening likely" \
          "does not apply. Treat as unverified and keep the backup anyway." ;;
esac
echo
echo "  Recovery needs the RESET line. The Feather routes it (button + header"
echo "  pin), so the documented no-nRESET deadlock does not apply to this board."
echo

echo "=== 2. Dump flash and UICR ==="
echo "  flash 0x0..$FLASH_SIZE -> flash_full.bin  (1 MB, takes a moment)"
pyocd cmd -t "$TARGET" -c "savemem 0x0 $FLASH_SIZE flash_full.bin"
echo "  UICR  $UICR_ADDR    -> uicr.bin"
pyocd cmd -t "$TARGET" -c "savemem $UICR_ADDR $UICR_SIZE uicr.bin"

echo
echo "=== 3. Verify the dumps are the size they claim ==="
want_flash=$((FLASH_SIZE)); want_uicr=$((UICR_SIZE))
got_flash=$(stat -c %s flash_full.bin 2>/dev/null || echo 0)
got_uicr=$(stat -c %s uicr.bin 2>/dev/null || echo 0)
[[ "$got_flash" -eq "$want_flash" ]] || die "flash_full.bin is $got_flash bytes, expected $want_flash"
[[ "$got_uicr"  -eq "$want_uicr"  ]] || die "uicr.bin is $got_uicr bytes, expected $want_uicr"

# An all-0xff flash dump means we read a blank or inaccessible part, not a
# backup worth trusting.
python3 - <<'PY' || die "flash dump is entirely erased -- that is not a backup"
import sys, pathlib
d = pathlib.Path('flash_full.bin').read_bytes()
sys.exit(0 if d.count(b'\xff') < len(d) * 0.99 else 1)
PY

{
  echo "# nRF52840 backup taken $(date -Iseconds)"
  echo "# FICR.INFO.VARIANT = $variant_raw (\"$variant_ascii\")"
  echo "# UICR.APPROTECT    = ${approtect_raw:-unreadable}"
} > BACKUP.info
sha256sum flash_full.bin uicr.bin | tee BACKUP.sha256

echo
echo "=== Backup complete: $OUTDIR ==="
echo
echo "To restore (this puts the Adafruit bootloader back):"
echo "  pyocd erase -t $TARGET --chip"
echo "  pyocd flash -t $TARGET --base-address 0x0 $OUTDIR/flash_full.bin"
echo "  pyocd flash -t $TARGET --base-address $UICR_ADDR $OUTDIR/uicr.bin"
echo
echo "Keep this directory somewhere that is not this working tree."
