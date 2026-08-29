# The canonical firmware-service image.
#
# Stage 1 builds with the Zephyr toolchain. Stage 2 is `FROM scratch` carrying
# nothing but the signed image and an entrypoint naming it, which is what the
# runtime reads. Deltas are computed on full image content rather than per
# layer, so a single-layer blob is the best case for update size.

# v0.29.3 ships Zephyr SDK 1.0.1. The SDK went 1.x, and Zephyr v4.4.2 requires
# "1.0" exactly -- an older CI image (v0.28.4 carries SDK 0.17.4) fails at
# configure with "Could not find a configuration file for package Zephyr-sdk
# compatible with requested version 1.0". Bump this tag and the west.yml Zephyr
# pin together.
#
# docker.io rather than ghcr.io: ghcr rate-limited this image hard enough to
# fail the pull outright ("toomanyrequests"). Same image, same blob digests.
FROM docker.io/zephyrprojectrtos/ci:v0.29.3 AS builder
ARG BOARD=adafruit_feather_nrf52840/nrf52840
WORKDIR /ws
COPY west.yml /ws/firmware/west.yml
RUN west init -l firmware && west update --narrow -o=--depth=1
# The CI image ships a Python venv but not Zephyr's own requirements, and the
# build fails at configure time with "Missing jsonschema dependency" without
# them -- zephyr_module.cmake uses jsonschema to validate module.yml. `pip` here
# resolves to /opt/python/venv/bin/pip, which is the interpreter cmake uses.
RUN pip install --no-cache-dir -r /ws/zephyr/scripts/requirements-base.txt
COPY . /ws/firmware/
# -Dapp_SNIPPET rather than -S: under sysbuild a top-level snippet applies to
# EVERY image, which would pull MCUmgr, this module and a dual CDC composite
# into the bootloader.
#
# ZEPHYR_EXTRA_MODULES is not optional: balena-mcu lives *inside* the manifest
# repo, and west only auto-discovers a module.yml at a project's root. Ours is
# nested at firmware/balena-mcu/zephyr/module.yml, so without this the module
# and its snippet are simply not there. Same line both build scripts carry.
RUN west build -b "${BOARD}" --sysbuild firmware/app \
      -- -DZEPHYR_EXTRA_MODULES=/ws/firmware/balena-mcu \
         -Dapp_SNIPPET=balena-mcu \
         -DSB_CONFIG_BOOTLOADER_MCUBOOT=y \
         -DSB_CONFIG_MCUBOOT_MODE_SWAP_USING_OFFSET=y

FROM scratch
# The runtime resolves the entrypoint inside the rootfs to find the image.
COPY --from=builder /ws/build/app/zephyr/zephyr.signed.bin /app.signed.bin
ENTRYPOINT ["app.signed.bin"]
