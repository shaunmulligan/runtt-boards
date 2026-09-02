#!/usr/bin/env bash
# Build the template firmware for the Raspberry Pi Pico 2 W (RP2350).
#
# A thin wrapper over build-pico.sh, because the two Pico generations differ in
# remarkably little. slot0, slot1 and the storage partition sit at IDENTICAL
# offsets (0x10000, 0xe0000, 0x1b0000), so the provisioning image builder needs
# no new constants and the identity offset is the same 0x101b0000.
#
# What genuinely differs:
#
#   board targets  rpi_pico2/rp2350a/m33/w and .../w/mcuboot. The /w matters --
#                  it brings in the CYW43439 wiring. Without it you get a Pico 2
#                  build that runs on a 2 W but has no wifi devicetree, which is
#                  not what someone holding a 2 W asked for.
#
#   boot slot      0x10000 (64 K), not RP2040's 0xfe00 (63.5 K). RP2350's boot
#                  ROM reads flash directly, so there is no 256-byte
#                  second-stage bootloader taking the front of flash. MCUboot
#                  measured 35 KB here, 53% of the slot -- roomy, where RP2040
#                  is tight.
#
#   UF2 family     RP2350 (0xe48bff57), not RP2040 (0xe48bff56). The boot ROM
#                  checks this and REJECTS a mismatched family rather than
#                  misflashing, so a wrong id looks like "the drag-and-drop did
#                  nothing". This is the value Zephyr's own UF2s for this board
#                  carry.
#
#   BOOTSEL volume RP2350, not RPI-RP2. Also a different BOOTSEL USB id:
#                  2e8a:000f rather than 2e8a:0003.
#
# The Cortex-M33 cores are the target, not the RP2350's Hazard3 RISC-V cores --
# Zephyr lists rpi_pico2/rp2350a/hazard3 but the runtt module has never been
# built for it.
set -euo pipefail

export BOARD_BRINGUP="rpi_pico2/rp2350a/m33/w"
export BOARD_MCUBOOT="rpi_pico2/rp2350a/m33/w/mcuboot"
export DIRP="build-pico2w"
export UF2_FAMILY="RP2350"
export BOOT_SLOT="0x10000"
export VOLUME="RP2350"

exec "$(dirname "${BASH_SOURCE[0]}")/build-pico.sh" "$@"
