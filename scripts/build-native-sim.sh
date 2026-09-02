#!/usr/bin/env bash
# Build the template firmware for native_sim.
#
# native_sim/native/64 rather than plain native_sim: the 32-bit target needs
# gcc-multilib, and the 64-bit one builds with a stock host compiler. No Zephyr
# SDK is needed either -- native_sim compiles with the host toolchain.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

# The workspace, not the repo. `west init -l boards` puts zephyr/ and
# modules/runtt/ beside this repository rather than inside it, so ZEPHYR_BASE
# cannot be derived from $REPO. Ask west.
TOPDIR="$(west topdir 2>/dev/null)" || {
  echo "not in a west workspace. Set one up with:" >&2
  echo "  mkdir ws && cd ws && git clone <this repo> boards && west init -l boards && west update" >&2
  exit 1
}
export ZEPHYR_BASE="$TOPDIR/zephyr"
export ZEPHYR_TOOLCHAIN_VARIANT=host

# The runtt module is a west project in west.yml, so west registers it as a
# Zephyr module and `west build` picks up its Kconfig, CMakeLists and snippet
# with no extra flags. It needed ZEPHYR_EXTRA_MODULES only while it lived inside
# this repository.
# BUILD_DIR lets a caller keep more than one configuration around at once --
# the CAN gate needs a differently-configured binary from the serial one, and
# clobbering a single build/ between them makes the two gates fight.
BUILD_DIR="${BUILD_DIR:-$REPO/build}"

west build -p always -b native_sim/native/64 --snippet runtt app \
  -d "$BUILD_DIR" \
  -- "$@"
