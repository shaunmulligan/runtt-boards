# The reusable firmware build environment: Zephyr, its modules, MCUboot and the
# runtt module, fetched once.
#
# Exists so an application directory can carry a Dockerfile of half a dozen
# lines. Without it every app's build context would have to include the west
# manifest and the module, which forces the context up to a whole repository and
# makes "cd app1 && docker build ." impossible.
#
# Build it from the repository root, which is the manifest repo:
#
#   docker build -f builder/Dockerfile -t runtt-builder:v4.4.2 .
#
# ⚠ REQUIRES runtt-zephyr-module TO BE PUBLICLY READABLE. west clones it during
# the build over HTTPS, using the url-base in west.yml, so a private module repo
# makes this step fail with an authentication prompt.
#
# There is deliberately no token plumbed through here. A token passed as a build
# arg lands in the image history, and one written to git config lands in a layer;
# neither is worth doing to a build environment that gets shared around. If the
# module must stay private for now, build the image on a machine with a git
# credential helper already configured for github.com, or make the module repo
# public -- which is where it is going anyway.
#
# Rebuild when the Zephyr pin or the module revision in west.yml changes;
# otherwise it is a once-per-machine cost.
FROM docker.io/zephyrprojectrtos/ci:v0.29.3

WORKDIR /ws

# The manifest goes to the path west.yml declares as `self.path`, so the
# workspace inside this image is laid out exactly like a developer's:
#
#   /ws/boards/        the manifest repo
#   /ws/zephyr/
#   /ws/modules/runtt/ the runtt module, as a west project
#
# It used to `COPY runtt /ws/runtt` from this repository, which stopped being
# possible when the module became its own repository. Fetching it through west is
# not a workaround for that -- it is what declaring it in west.yml is for, and it
# means the image cannot drift from the manifest.
COPY west.yml /ws/boards/west.yml

RUN west init -l boards && west update --narrow -o=--depth=1

# The CI image ships a Python venv but not Zephyr's own requirements; without
# them the build fails at configure with "Missing jsonschema dependency".
RUN pip install --no-cache-dir -r /ws/zephyr/scripts/requirements-base.txt

ENV ZEPHYR_BASE=/ws/zephyr
# Where the module landed, for anything that still wants it explicitly. Builds
# do NOT need it: west registered the module, so `west build` finds its Kconfig,
# CMakeLists and snippet on its own.
ENV RUNTT_MODULE=/ws/modules/runtt
