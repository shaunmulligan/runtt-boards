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
# FICR.INFO.VARIANT. This said 0x10000130 for a long time, which is not the
# VARIANT register: on a real nRF52840 it reads 0x00000008, decodes to control
# characters as ASCII, and therefore never matches the *F0 test below. The
# revision-3 APPROTECT warning -- the whole reason this block exists -- could
# not fire on any part. Verified against the part on the bench: 0x10000104
# reads 0x41414330, "AAC0", which is the documented four-ASCII-byte build code.
FICR_VARIANT=0x10000104   # FICR.INFO.VARIANT -- build code, e.g. "AAF0"
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
# Refuse to overwrite an actual backup, not merely a directory. The earlier
# check was `[[ -e "$OUTDIR" ]]`, and since mkdir runs before the first SWD
# read, any failed run left an empty directory that then blocked every retry
# with "refusing to overwrite a backup" -- of nothing.
if [[ -e "$OUTDIR" ]]; then
  if [[ -n "$(ls -A "$OUTDIR" 2>/dev/null)" ]]; then
    die "$OUTDIR already exists and is not empty; refusing to overwrite a backup"
  fi
  echo "note: reusing the empty directory $OUTDIR"
fi
mkdir -p "$OUTDIR"
cd "$OUTDIR"

# pyocd prints `read32` as "10000104:  41414330" -- an address, a colon, then
# the value, with NO 0x prefix on either. This used to grep for
# '0x[0-9a-fA-F]{8}' and so matched nothing at all, on any part: the script died
# at step 1 every time it was run with a board attached, claiming the probe was
# unwired. Anchor on the colon and take the value after it.
#
# auto_unlock=false on every call, and this matters more here than anywhere
# else. pyocd defaults it to TRUE, so connecting to a part whose APPROTECT is
# enabled triggers a CTRL-AP ERASEALL to gain access -- which would erase the
# flash and UICR that this script exists to preserve, as its first act. A
# backup tool must fail to connect rather than unlock.
PYOCD_RO=(-O auto_unlock=false)

read_word() {
  pyocd cmd -t "$TARGET" "${PYOCD_RO[@]}" -c "read32 $1" 2>/dev/null \
    | sed -n 's/^[0-9a-fA-F]\{1,\}:[[:space:]]*\(0x\)\{0,1\}\([0-9a-fA-F]\{8\}\).*/\2/p' \
    | tail -1
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
pyocd cmd -t "$TARGET" "${PYOCD_RO[@]}" -c "savemem 0x0 $FLASH_SIZE flash_full.bin"
echo "  UICR  $UICR_ADDR    -> uicr.bin"
pyocd cmd -t "$TARGET" "${PYOCD_RO[@]}" -c "savemem $UICR_ADDR $UICR_SIZE uicr.bin"

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
# Say what this dump actually contains rather than what it contained the first
# time anyone ran this. The message used to read "this puts the Adafruit
# bootloader back", which is only true of a backup taken before MCUboot was
# ever flashed. Taken from a board already running runtt it restores MCUboot and
# the runtt application -- and a user who reaches for a backup is usually
# reaching for the stock bootloader, so the wrong claim points them at a restore
# that will not give them what they want.
echo "This dump contains:"
python3 - "$PWD/flash_full.bin" <<'PY'
import pathlib, struct, sys
d = pathlib.Path(sys.argv[1]).read_bytes()
if d[0xc000:0xc004] == struct.pack("<I", 0x96f3b83d):
    print("  - an MCUboot-signed image in slot0 (0xc000)")
if b"UF2 Bootloader" in d[0xf0000:]:
    print("  - remnants of the Adafruit UF2 bootloader in the top of flash")
if d[0xf8000:0xf8004] == b"rntt":
    ser = d[0xf800c:0xf801c].split(b"\x00")[0].decode("ascii", "replace")
    print(f"  - a runtt identity record at 0xf8000, serial {ser!r}")
PY
echo
echo "To restore exactly this state:"
echo "  pyocd erase -t $TARGET --chip"
echo "  pyocd flash -t $TARGET --base-address 0x0 $OUTDIR/flash_full.bin"
echo "  pyocd flash -t $TARGET --base-address $UICR_ADDR $OUTDIR/uicr.bin"
echo
echo "Keep this directory somewhere that is not this working tree."
