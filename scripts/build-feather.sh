#!/usr/bin/env bash
# Build the firmware for the Adafruit Feather nRF52840 Express.
#
#   bringup    plain adafruit_feather_nrf52840/nrf52840, no bootloader and no
#              slots, linked at 0x0 so it boots standalone. What you want while
#              proving SWD, USB enumeration, the interface string descriptors
#              and the udev rules -- one variable at a time.
#
#   mcuboot    the same board under sysbuild with MCUboot: the full contract,
#              and the configuration a firmware container actually ships.
#
#   provision  balena-mcu-idle plus MCUboot, emitted as two hex files ready to
#              flash over SWD. This is the one physical act; everything after it
#              is remote. See docs/PROVISIONING.md.
#
# Unlike the Pico there is no UF2 path and no BOOTSEL: the nRF52840 has no USB
# ROM loader, so every one of these needs a probe. Back the board up first --
# scripts/backup-nrf52840.sh.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

MODE="${1:-mcuboot}"
BOARD=adafruit_feather_nrf52840/nrf52840
export ZEPHYR_BASE="$REPO/zephyr"
export ZEPHYR_SDK_INSTALL_DIR="${ZEPHYR_SDK_INSTALL_DIR:-$HOME/zephyr-sdk}"
unset ZEPHYR_TOOLCHAIN_VARIANT

# Geometry from nordic/nrf52840_partition.dtsi, which the plain board target
# includes. The uf2 variant does NOT have these -- it keeps Adafruit's
# bootloader and has no slots at all.
BOOT_SLOT=$((0xc000))     #  48 KB at 0x0
SLOT_SIZE=$((0x76000))    # 472 KB at 0xc000 and 0x82000

[[ -d "$ZEPHYR_SDK_INSTALL_DIR" ]] || {
  echo "Zephyr SDK not found at $ZEPHYR_SDK_INSTALL_DIR" >&2
  echo "Install the ARM toolchain: west sdk install -t arm-zephyr-eabi" >&2
  exit 1
}

# Loud, every build: an image signed with a publicly known private key is not
# meaningfully signed, and provisioning is exactly when the trust root is set.
warn_dev_key() {
  local key
  key=$(grep -oP '(?<=^CONFIG_BOOT_SIGNATURE_KEY_FILE=").*(?=")' \
        "$1/mcuboot/zephyr/.config" 2>/dev/null || true)
  if [[ "$key" == *"/bootloader/mcuboot/root-"* ]]; then
    echo
    echo "  !! Signed with MCUboot's DEVELOPMENT key:"
    echo "     $key"
    echo "     That private key is public. Any image signed with it will verify,"
    echo "     so no trust root is enrolled. Fine for the bench; never for a fleet."
    echo "     On this board the public half is baked into MCUboot at 0x0, so"
    echo "     rotating it means another SWD flash. See firmware/sysbuild-common.conf."
  fi
}

check_boot_fits() {
  local boot_bin="$1/mcuboot/zephyr/zephyr.bin" used
  [[ -f "$boot_bin" ]] || return 0
  used=$(stat -c %s "$boot_bin")
  printf "  MCUboot: %d bytes, %d%% of the %d-byte boot partition\n" \
    "$used" $(( used * 100 / BOOT_SLOT )) "$BOOT_SLOT"
  [[ $used -le $BOOT_SLOT ]] || { echo "  MCUboot does NOT fit the boot partition" >&2; exit 1; }
  # Headroom is genuinely tight here -- 48 KB against the Pico's 63.5 KB -- and
  # serial recovery is the thing most likely to push it over.
  if [[ $(( used * 100 / BOOT_SLOT )) -ge 75 ]]; then
    echo "  note: under 25% headroom. Adding BOOT_SERIAL_* may not fit."
  fi
}

build_bringup() {
  echo "=== bringup: plain $BOARD (no bootloader, no image management) ==="
  # Plain -S here, not -Dapp_SNIPPET: this is a NON-sysbuild build, so there is
  # no bootloader image for a top-level snippet to leak into.
  west build -p always -b "$BOARD" --snippet balena-mcu firmware/examples/app1 \
    -d build-feather-bringup -- -DZEPHYR_EXTRA_MODULES="$REPO/firmware/balena-mcu"
  echo
  echo "  flash it over SWD (no BOOTSEL on this board):"
  echo "    pyocd flash -t nrf52840 build-feather-bringup/zephyr/zephyr.hex"
}

build_mcuboot() {
  echo "=== mcuboot: $BOARD under sysbuild (full contract) ==="
  # -Dapp1_SNIPPET rather than --snippet: under sysbuild a top-level snippet
  # applies to EVERY image, which would pull MCUmgr, our module and a dual CDC
  # composite into the bootloader -- and into 48 KB, it would not fit.
  west build -p always -b "$BOARD" --sysbuild firmware/examples/app1 \
    -d build-feather -- \
    -DZEPHYR_EXTRA_MODULES="$REPO/firmware/balena-mcu" \
    -Dapp1_SNIPPET=balena-mcu
  echo
  check_boot_fits build-feather
  local signed=build-feather/app1/zephyr/zephyr.signed.bin
  [[ -f "$signed" ]] && echo "  signed image: $(stat -c %s "$signed") bytes  ($signed)"
  verify_image "$signed"
  warn_dev_key build-feather
}

# The malformed-image check from docs/WALKTHROUGH.md, run on every build rather
# than only when something has already gone wrong. A double-padded header passes
# `imgtool verify` and then locks the board up; here it costs nothing to catch.
verify_image() {
  [[ -f "$1" ]] || return 0
  python3 - "$1" <<'PY'
import struct, pathlib, sys
d = pathlib.Path(sys.argv[1]).read_bytes()
magic = struct.unpack('<I', d[0:4])[0]
hdr = struct.unpack('<H', d[8:10])[0]
sp = struct.unpack('<I', d[hdr:hdr+4])[0]
ok = magic == 0x96f3b83d and sp >> 24 == 0x20   # nRF52840 RAM is at 0x20000000
print(f"  image check: magic={magic:#x} hdr={hdr:#x} sp={sp:#010x} "
      f"{'OK' if ok else 'MALFORMED -- do not flash this'}")
sys.exit(0 if ok else 1)
PY
}

build_provision() {
  echo "=== provision: balena-mcu-idle + MCUboot, for SWD ==="
  west build -p always -b "$BOARD" --sysbuild firmware/idle \
    -d build-feather-idle -- \
    -DZEPHYR_EXTRA_MODULES="$REPO/firmware/balena-mcu" \
    -Didle_SNIPPET=balena-mcu
  echo
  check_boot_fits build-feather-idle

  # An image flashed straight into the PRIMARY slot is the running image, not a
  # candidate awaiting a test, so it needs a padded trailer marked confirmed.
  # Sysbuild does not emit that variant, so produce it with imgtool.
  #
  # NOTE: no --pad-header. The app already reserves its header via
  # CONFIG_ROM_START_OFFSET; padding again yields an image that passes
  # `imgtool verify` and then locks the board up. See docs/WALKTHROUGH.md.
  local key version out
  key=$(grep -oP '(?<=^CONFIG_BOOT_SIGNATURE_KEY_FILE=").*(?=")' \
        build-feather-idle/mcuboot/zephyr/.config)
  version=$(grep -oP '(?<=^VERSION_MAJOR = ).*' firmware/idle/VERSION 2>/dev/null || echo 0)
  out=build-feather-idle/provision-slot0.hex

  python3 bootloader/mcuboot/scripts/imgtool.py sign \
    --key "$key" \
    --header-size 0x200 --align 4 \
    --version "${version}.0.0" --slot-size "$SLOT_SIZE" \
    --pad --confirm \
    --hex-addr 0xc000 \
    build-feather-idle/idle/zephyr/zephyr.bin "$out"

  echo "  confirmed slot-0 image: $out"
  echo
  echo "  flash both, in this order, WITHOUT resetting in between:"
  echo "    ./scripts/flash-feather.sh build-feather-idle"
  warn_dev_key build-feather-idle
}

case "$MODE" in
  bringup)   build_bringup ;;
  mcuboot)   build_mcuboot ;;
  provision) build_provision ;;
  *) echo "usage: $0 [bringup|mcuboot|provision]" >&2; exit 2 ;;
esac
