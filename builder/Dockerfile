# The reusable firmware build environment: Zephyr, its modules, MCUboot, and the
# balena-mcu module, fetched once.
#
# Exists so an application directory can carry a Dockerfile of half a dozen
# lines. Without it every app's build context would have to include the west
# manifest and the module, which forces the context up to the whole repo and
# makes "cd app1 && docker build ." impossible.
#
# Build from the firmware/ directory, which holds west.yml and balena-mcu/:
#
#   docker build -f firmware/builder/Dockerfile -t balena-mcu-builder:v4.4.2 firmware/
#
# Rebuild it when the Zephyr pin in west.yml changes; otherwise it is a
# once-per-machine cost.
FROM docker.io/zephyrprojectrtos/ci:v0.29.3

WORKDIR /ws

# Manifest first, so a change to module sources does not re-fetch Zephyr.
COPY west.yml /ws/manifest/west.yml
RUN west init -l manifest && west update --narrow -o=--depth=1

# The CI image ships a Python venv but not Zephyr's own requirements; without
# them the build fails at configure with "Missing jsonschema dependency".
RUN pip install --no-cache-dir -r /ws/zephyr/scripts/requirements-base.txt

# The module itself. Last, because it changes most often.
COPY balena-mcu /ws/balena-mcu

ENV ZEPHYR_BASE=/ws/zephyr
ENV BALENA_MCU_MODULE=/ws/balena-mcu
