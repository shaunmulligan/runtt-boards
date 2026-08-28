# The canonical firmware-service image.
#
# Stage 1 builds with the Zephyr toolchain. Stage 2 is `FROM scratch` carrying
# nothing but the signed image and an entrypoint naming it, which is what the
# runtime reads. Deltas are computed on full image content rather than per
# layer, so a single-layer blob is the best case for update size.

FROM ghcr.io/zephyrproject-rtos/ci:v0.28.4 AS builder
ARG BOARD=adafruit_feather_nrf52840/nrf52840
WORKDIR /ws
COPY west.yml /ws/firmware/west.yml
RUN west init -l firmware && west update --narrow -o=--depth=1
COPY . /ws/firmware/
# -Dapp_SNIPPET rather than -S: under sysbuild a top-level snippet applies to
# EVERY image, which would pull MCUmgr, this module and a dual CDC composite
# into the bootloader.
RUN west build -b "${BOARD}" --sysbuild firmware/app \
      -- -Dapp_SNIPPET=balena-mcu \
         -DSB_CONFIG_BOOTLOADER_MCUBOOT=y \
         -DSB_CONFIG_MCUBOOT_MODE_SWAP_USING_OFFSET=y

FROM scratch
# The runtime resolves the entrypoint inside the rootfs to find the image.
COPY --from=builder /ws/build/app/zephyr/zephyr.signed.bin /app.signed.bin
ENTRYPOINT ["app.signed.bin"]
