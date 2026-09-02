#!/usr/bin/env bash
# Build the template firmware for the Raspberry Pi Pico (RP2040).
#
# Two configurations, because they prove different things:
#
#   provision  runtt-idle under sysbuild, emitted as a single UF2. This is
#              what a customer flashes over BOOTSEL to make a board manageable.
#              See docs/PROVISIONING.md.
#
#   bringup  plain `rpi_pico`. No bootloader, no slots, so no image management.
#            Boots standalone, which is what you want while proving USB
#            enumeration, the interface string descriptors and the udev rules.
#            Flashable by drag-and-drop via BOOTSEL -- no probe required.
#
#   mcuboot  `rpi_pico/rp2040/mcuboot` under sysbuild. The full contract,
#            including image management, and the configuration a firmware
#            container would actually ship.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

MODE="${1:-both}"

# ---------------------------------------------------------------------------
# Per-SoC values. The defaults are the Pico 1 (RP2040); scripts/build-pico2w.sh
# overrides them for the Pico 2 W (RP2350). One implementation rather than two
# copies, because the two boards differ in remarkably little: slot0, slot1 and
# the storage partition sit at identical offsets, so only the board targets, the
# boot-slot size and the UF2 family id change.
#
# BOOT_SLOT is the size of boot_partition, and it genuinely differs: RP2040
# spends the first 256 bytes on a second-stage bootloader and leaves MCUboot
# 0xfe00 (63.5 K), while RP2350's boot ROM reads flash directly and MCUboot gets
# the full 0x10000 (64 K).
# ---------------------------------------------------------------------------
BOARD_BRINGUP="${BOARD_BRINGUP:-rpi_pico}"
BOARD_MCUBOOT="${BOARD_MCUBOOT:-rpi_pico/rp2040/mcuboot}"
DIRP="${DIRP:-build-pico}"          # build-directory prefix
UF2_FAMILY="${UF2_FAMILY:-RP2040}"
BOOT_SLOT="${BOOT_SLOT:-0xfe00}"
VOLUME="${VOLUME:-RPI-RP2}"         # BOOTSEL mass-storage label
# The workspace, not the repo. `west init -l boards` puts zephyr/ and
# modules/runtt/ beside this repository rather than inside it, so ZEPHYR_BASE
# cannot be derived from $REPO. Ask west.
TOPDIR="$(west topdir 2>/dev/null)" || {
  echo "not in a west workspace. Set one up with:" >&2
  echo "  mkdir ws && cd ws && git clone <this repo> boards && west init -l boards && west update" >&2
  exit 1
}
export ZEPHYR_BASE="$TOPDIR/zephyr"
export ZEPHYR_SDK_INSTALL_DIR="${ZEPHYR_SDK_INSTALL_DIR:-$HOME/zephyr-sdk}"
unset ZEPHYR_TOOLCHAIN_VARIANT

[[ -d "$ZEPHYR_SDK_INSTALL_DIR" ]] || {
  echo "Zephyr SDK not found at $ZEPHYR_SDK_INSTALL_DIR" >&2
  echo "Install the ARM toolchain: west sdk install -t arm-zephyr-eabi" >&2
  exit 1
}

build_bringup() {
  echo "=== bringup: plain $BOARD_BRINGUP (no bootloader, no image management) ==="
  west build -p always -b "$BOARD_BRINGUP" --snippet runtt app-test \
    -d "$DIRP"
  echo
  echo "  flash by drag-and-drop: hold BOOTSEL, plug in, then"
  echo "    cp $DIRP/zephyr/zephyr.uf2 /media/\$USER/$VOLUME/"
}

build_mcuboot() {
  echo "=== mcuboot: $BOARD_MCUBOOT under sysbuild (full contract) ==="
  # -Dapp-test_SNIPPET rather than --snippet. With sysbuild, --snippet applies the
  # snippet to EVERY image, which would enable MCUmgr, our module and a dual CDC
  # composite inside the bootloader.
  west build -p always -b "$BOARD_MCUBOOT" --sysbuild app-test \
    -d "$DIRP-mcuboot" -- \
       -Dapp-test_SNIPPET=runtt

  local boot_bin="$DIRP-mcuboot/mcuboot/zephyr/zephyr.bin"
  local signed="$DIRP-mcuboot/app-test/zephyr/zephyr.signed.bin"
  local slot=$((BOOT_SLOT))

  echo
  if [[ -f "$boot_bin" ]]; then
    local used; used=$(stat -c %s "$boot_bin")
    printf "  MCUboot: %d bytes, %d%% of the %d-byte boot slot\n" \
      "$used" $(( used * 100 / slot )) "$slot"
    [[ $used -le $slot ]] || { echo "  MCUboot does NOT fit the boot slot" >&2; exit 1; }
  fi
  [[ -f "$signed" ]] && echo "  signed image: $(stat -c %s "$signed") bytes  ($signed)"

  # A single provisioning image: MCUboot plus a CONFIRMED app in slot 0.
  # See scripts/make-provision-uf2.py for why it is built from the hex files and
  # why the trailer matters.
  python3 scripts/make-provision-uf2.py \
    --mcuboot "$TOPDIR/bootloader/mcuboot" \
    --build-dir "$DIRP-mcuboot" \
    --zephyr-base "$ZEPHYR_BASE" \
    --objcopy "$ZEPHYR_SDK_INSTALL_DIR/gnu/arm-zephyr-eabi/bin/arm-zephyr-eabi-objcopy" \
    --family "$UF2_FAMILY" \
    -o "$DIRP-mcuboot/provision.uf2"
  echo "    hold BOOTSEL, plug in, then:"
  echo "      cp $DIRP-mcuboot/provision.uf2 \"\$(findmnt -rn -o TARGET /dev/sda1)/\""
  echo

  warn_dev_key "$DIRP-mcuboot"
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
    echo "     See sysbuild-common.conf."
  fi
}

build_provision() {
  echo "=== provision: runtt-idle + MCUboot, one flashable image ==="
  west build -p always -b "$BOARD_MCUBOOT" --sysbuild idle \
    -d "$DIRP-idle" -- \
       -Didle_SNIPPET=runtt
  echo
  python3 scripts/make-provision-uf2.py \
    --mcuboot "$TOPDIR/bootloader/mcuboot" \
    --build-dir "$DIRP-idle" \
    --zephyr-base "$ZEPHYR_BASE" \
    --objcopy "$ZEPHYR_SDK_INSTALL_DIR/gnu/arm-zephyr-eabi/bin/arm-zephyr-eabi-objcopy" \
    --family "$UF2_FAMILY" \
    -o "$DIRP-idle/provision.uf2"
  echo
  echo "  flash it with:  ./scripts/runtt-board flash $BOARD_MCUBOOT"
  echo "  (hold BOOTSEL while plugging the board in first)"
  warn_dev_key "$DIRP-idle"
}

case "$MODE" in
  bringup)   build_bringup ;;
  mcuboot)   build_mcuboot ;;
  provision) build_provision ;;
  both)      build_bringup; echo; build_mcuboot ;;
  *) echo "usage: $0 [bringup|mcuboot|provision|both]" >&2; exit 2 ;;
esac
