#!/usr/bin/env bash
# Build the template firmware for the Adafruit Feather RP2040 CAN bus.
#
# A thin wrapper over build-pico.sh, like build-pico2w.sh, because this is an
# RP2040 like the Pico 1 and differs in remarkably little:
#
#   board targets  adafruit_feather_canbus_rp2040/rp2040 and .../rp2040/mcuboot.
#                  The mcuboot variant is NOT upstream: it comes from this
#                  repository's boards/ tree (we are a Zephyr BOARD_ROOT), which
#                  extends the upstream board with the Pico's slot layout.
#
#   partitions     identical offsets to the Pico 1 -- boot 0xfe00 at 0x100,
#                  slots at 0x10000/0xe0000, storage at 0x1b0000 -- despite the
#                  8 MB flash. Same identity offset (0x101b0000), same
#                  make-provision-uf2 constants, no new numbers to get wrong.
#
#   CAN            the point of the board: an MCP25625 (MCP2515 + integrated
#                  transceiver) on spi1, /chosen/zephyr,canbus already set
#                  upstream. The runtt snippet enables SMP over ISO-TP on it at
#                  500 kbit/s, alongside the usual dual-CDC USB contract.
#
# Everything else -- UF2 family (RP2040), boot slot (0xfe00), BOOTSEL volume
# (RPI-RP2, the RP2040 mask ROM's, not the board's) -- is the Pico 1's.
set -euo pipefail

export BOARD_BRINGUP="adafruit_feather_canbus_rp2040/rp2040"
export BOARD_MCUBOOT="adafruit_feather_canbus_rp2040/rp2040/mcuboot"
export DIRP="build-feather-can"
export UF2_FAMILY="RP2040"
export BOOT_SLOT="0xfe00"
export VOLUME="RPI-RP2"

exec "$(dirname "${BASH_SOURCE[0]}")/build-pico.sh" "$@"
