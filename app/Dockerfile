# SUPERSEDED -- see firmware/examples/app1/Dockerfile.
#
# This built only with firmware/ as the build context, because it copies west.yml
# and the module tree out of it. That makes "cd app && docker build ." fail with
#     "/west.yml": not found
# and forces every application to sit inside this repo.
#
# The replacement builds the Zephyr workspace once into a reusable builder image
# (firmware/builder/Dockerfile), so an application directory carries a Dockerfile
# of a few lines and its own source, and nothing else. See docs/WALKTHROUGH.md.
