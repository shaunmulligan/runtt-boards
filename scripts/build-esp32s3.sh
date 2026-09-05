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
#   bringup  single-channel contract on usb_serial, no bootloader
#   mcuboot  the same contract under sysbuild with MCUboot
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
MODE="${1:-mcuboot}"

BOARD="esp32s3_devkitc/esp32s3/procpu"
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
    west build -p always -b "$BOARD" --sysbuild app-test -d build-esp32s3-mcuboot -- \
      -Dapp-test_SNIPPET=runtt \
      -Dapp-test_EXTRA_DTC_OVERLAY_FILE="$REPO/bringup/esp32s3-usbjtag.overlay" \
      -Dapp-test_EXTRA_CONF_FILE="$REPO/bringup/esp32s3-usbjtag.conf" \
      -DSB_EXTRA_CONF_FILE="$REPO/bringup/sysbuild-esp32s3.conf"
    echo
    echo "  flash everything once:  west flash -d build-esp32s3-mcuboot --esp-device <port>"
    echo "  after that, updates arrive through runtt."
    ;;
  *) echo "usage: $0 [bringup|mcuboot]" >&2; exit 2 ;;
esac
