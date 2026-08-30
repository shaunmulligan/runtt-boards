#!/usr/bin/env bash
# Build the template firmware for native_sim.
#
# native_sim/native/64 rather than plain native_sim: the 32-bit target needs
# gcc-multilib, and the 64-bit one builds with a stock host compiler. No Zephyr
# SDK is needed either -- native_sim compiles with the host toolchain.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

export ZEPHYR_BASE="$REPO/zephyr"
export ZEPHYR_TOOLCHAIN_VARIANT=host

# balena-mcu lives inside the manifest repo, so west does not treat it as a
# module automatically; ZEPHYR_EXTRA_MODULES is the documented way in.
# BUILD_DIR lets a caller keep more than one configuration around at once --
# the CAN gate needs a differently-configured binary from the serial one, and
# clobbering a single build/ between them makes the two gates fight.
BUILD_DIR="${BUILD_DIR:-$REPO/build}"

west build -p always -b native_sim/native/64 --snippet balena-mcu firmware/app \
  -d "$BUILD_DIR" \
  -- -DZEPHYR_EXTRA_MODULES="$REPO/firmware/balena-mcu" "$@"
