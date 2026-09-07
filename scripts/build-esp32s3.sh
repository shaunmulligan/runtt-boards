#!/usr/bin/env bash
# Build the template firmware for the ESP32-S3 (Waveshare DevKitC-compatible).
#
# NOT a wrapper over build-pico.sh: this SoC shares none of the RP2 mechanics.
# No UF2 (flashing is esptool over the chip's own USB-Serial/JTAG), no board
# variant (upstream already defaults to MCUboot under sysbuild and ships slot
# partitions), and a different swap mode (scratch -- see
# bringup/sysbuild-esp32s3.conf for why offset is wrong here).
#
# Modes:
#   bringup    single-channel contract on usb_serial, no bootloader
#   mcuboot    the dual-CDC contract under sysbuild with MCUboot
#   provision  runtt-idle plus MCUboot: what a factory-fresh board is flashed
#              with, as two binaries esptool writes at their offsets
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
MODE="${1:-mcuboot}"

BOARD="esp32s3_devkitc/esp32s3/procpu"

# From partitions_0x0_amp_4M.dtsi, read off the generated devicetree rather than
# assumed: boot at 0x0 (64 K), slot0 at 0x20000 (1344 K), slot1, storage at
# 0x3b0000 and a scratch area. The 4 M table sits inside every S3 module variant
# we care about, which is why one image serves N4, N8R8 and N16R8 alike.
BOOT_SLOT=$((0x10000))
SLOT0_OFF=$((0x20000))
SLOT_SIZE=$((0x150000))
TOPDIR="$(west topdir 2>/dev/null)" || {
  echo "not in a west workspace; see the README" >&2; exit 1
}
export ZEPHYR_BASE="$TOPDIR/zephyr"
export ZEPHYR_SDK_INSTALL_DIR="${ZEPHYR_SDK_INSTALL_DIR:-$HOME/zephyr-sdk}"
unset ZEPHYR_TOOLCHAIN_VARIANT

case "$MODE" in
  bringup)
    west build -p always -b "$BOARD" --snippet runtt app-test -d build-esp32s3 -- \
      -DEXTRA_DTC_OVERLAY_FILE="$REPO/bringup/esp32s3-usbjtag.overlay" \
      -DEXTRA_CONF_FILE="$REPO/bringup/esp32s3-usbjtag.conf"
    ;;
  mcuboot)
    # -Dapp-test_SNIPPET, not --snippet: under sysbuild a top-level snippet
    # would apply to MCUboot too.
    # No usbjtag overlay/conf here any more. Those belong to `bringup`, which
    # is deliberately the single-wire stage. The module snippet's
    # /esp32s3_devkitc.*/ key now supplies the board's real configuration -- the
    # dual CDC-ACM composite on usb_otg -- and layering the single-wire files on
    # top of it fights the composite for the one USB PHY.
    west build -p always -b "$BOARD" --sysbuild app-test -d build-esp32s3-mcuboot -- \
      -Dapp-test_SNIPPET=runtt \
      -DSB_EXTRA_CONF_FILE="$REPO/bringup/sysbuild-esp32s3.conf"
    echo
    echo "  flash everything once:  west flash -d build-esp32s3-mcuboot --esp-device <port>"
    echo "  after that, updates arrive through runtt."
    ;;
  provision)
    echo "=== provision: runtt-idle + MCUboot, for esptool ==="
    west build -p always -b "$BOARD" --sysbuild idle -d build-esp32s3-idle -- \
      -Didle_SNIPPET=runtt \
      -DSB_EXTRA_CONF_FILE="$REPO/bringup/sysbuild-esp32s3.conf"
    echo

    boot=build-esp32s3-idle/mcuboot/zephyr/zephyr.bin
    used=$(stat -c %s "$boot")
    printf "  MCUboot: %d bytes, %d%% of the %d-byte boot slot\n" \
      "$used" $(( used * 100 / BOOT_SLOT )) "$BOOT_SLOT"
    [[ $used -le $BOOT_SLOT ]] || { echo "  MCUboot does NOT fit" >&2; exit 1; }

    # An image flashed straight into the PRIMARY slot is the running image, not
    # a candidate awaiting a test, so it needs a padded trailer marked
    # confirmed. Sysbuild emits the unpadded variant, so produce this one with
    # imgtool.
    #
    # The flags mirror what sysbuild itself invokes for this SoC, read out of
    # its ninja rule rather than guessed: --header-size 0x20 (the app reserves
    # its header via CONFIG_ROM_START_OFFSET=0x20, so NO --pad-header, which
    # would yield an image that passes `imgtool verify` and then locks the board
    # up), --align 4, and the slot size from the partition table.
    key=$(grep -oP '(?<=^CONFIG_BOOT_SIGNATURE_KEY_FILE=").*(?=")' \
          build-esp32s3-idle/mcuboot/zephyr/.config)
    version=$(grep -oP '(?<=^VERSION_MAJOR = ).*' idle/VERSION 2>/dev/null || echo 0)
    out=build-esp32s3-idle/provision-slot0.bin

    python3 "$TOPDIR/bootloader/mcuboot/scripts/imgtool.py" sign \
      --key "$key" \
      --header-size 0x20 --align 4 \
      --version "${version}.0.0" --slot-size "$SLOT_SIZE" \
      --pad --confirm \
      build-esp32s3-idle/idle/zephyr/zephyr.bin "$out"

    echo "  confirmed slot-0 image: $out ($(stat -c %s "$out") bytes)"
    echo
    echo "  two binaries, written at their offsets:"
    printf "    0x%06x  %s\n" 0 "$boot"
    printf "    0x%06x  %s\n" "$SLOT0_OFF" "$out"
    echo
    echo "  flash with:  ./scripts/runtt-board provision esp32s3_devkitc --name <name>"
    ;;
  *) echo "usage: $0 [bringup|mcuboot|provision]" >&2; exit 2 ;;
esac
