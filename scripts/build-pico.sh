#!/usr/bin/env bash
# Build the template firmware for the Raspberry Pi Pico (RP2040).
#
# Two configurations, because they prove different things:
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
export ZEPHYR_BASE="$REPO/zephyr"
export ZEPHYR_SDK_INSTALL_DIR="${ZEPHYR_SDK_INSTALL_DIR:-$HOME/zephyr-sdk}"
unset ZEPHYR_TOOLCHAIN_VARIANT

[[ -d "$ZEPHYR_SDK_INSTALL_DIR" ]] || {
  echo "Zephyr SDK not found at $ZEPHYR_SDK_INSTALL_DIR" >&2
  echo "Install the ARM toolchain: west sdk install -t arm-zephyr-eabi" >&2
  exit 1
}

build_bringup() {
  echo "=== bringup: plain rpi_pico (no bootloader, no image management) ==="
  west build -p always -b rpi_pico --snippet balena-mcu firmware/app \
    -d build-pico -- -DZEPHYR_EXTRA_MODULES="$REPO/firmware/balena-mcu"
  echo
  echo "  flash by drag-and-drop: hold BOOTSEL, plug in, then"
  echo "    cp build-pico/zephyr/zephyr.uf2 /media/\$USER/RPI-RP2/"
}

build_mcuboot() {
  echo "=== mcuboot: rpi_pico/rp2040/mcuboot under sysbuild (full contract) ==="
  # -Dapp_SNIPPET rather than --snippet. With sysbuild, --snippet applies the
  # snippet to EVERY image, which would enable MCUmgr, our module and a dual CDC
  # composite inside the bootloader.
  west build -p always -b rpi_pico/rp2040/mcuboot --sysbuild firmware/app \
    -d build-pico-mcuboot -- \
    -DZEPHYR_EXTRA_MODULES="$REPO/firmware/balena-mcu" \
    -Dapp_SNIPPET=balena-mcu

  local boot_bin=build-pico-mcuboot/mcuboot/zephyr/zephyr.bin
  local signed=build-pico-mcuboot/app/zephyr/zephyr.signed.bin
  local slot=$((0xfe00))

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
    --zephyr-base "$ZEPHYR_BASE" \
    --objcopy "$ZEPHYR_SDK_INSTALL_DIR/gnu/arm-zephyr-eabi/bin/arm-zephyr-eabi-objcopy"
  echo "    hold BOOTSEL, plug in, then:"
  echo "      cp build-pico-mcuboot/provision.uf2 \"\$(findmnt -rn -o TARGET /dev/sda1)/\""
  echo

  # Loud, every build: an image signed with a public private key is not signed.
  local key
  key=$(grep -oP '(?<=^CONFIG_BOOT_SIGNATURE_KEY_FILE=").*(?=")' \
        build-pico-mcuboot/mcuboot/zephyr/.config 2>/dev/null || true)
  if [[ "$key" == *"/bootloader/mcuboot/root-"* ]]; then
    echo
    echo "  !! Signed with MCUboot's DEVELOPMENT key:"
    echo "     $key"
    echo "     That private key is public. Any image signed with it will verify,"
    echo "     so no trust root is enrolled. Fine for the bench; never for a fleet."
    echo "     See the signing note in firmware/app/sysbuild.conf."
  fi
}

case "$MODE" in
  bringup) build_bringup ;;
  mcuboot) build_mcuboot ;;
  both)    build_bringup; echo; build_mcuboot ;;
  *) echo "usage: $0 [bringup|mcuboot|both]" >&2; exit 2 ;;
esac
