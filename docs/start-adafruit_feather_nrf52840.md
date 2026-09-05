# Getting started: Adafruit Feather nRF52840

Three steps from a stock board to your code running as a container. Assumes the
[runtt runtime](https://github.com/shaunmulligan/runtt#install) is installed.

**This board needs an SWD probe** (e.g. a Raspberry Pi Debug Probe), and
provisioning **erases the Adafruit UF2 bootloader** — there is no ROM loader
behind it, so recovery afterwards is SWD-only. Wire the probe per
[PROVISIONING.md](PROVISIONING.md) and check it with:

```bash
pyocd cmd -t nrf52840 -c "read32 0x10000104"   # reads the chip ID, writes nothing
```

## 1. Back up, then provision

```bash
git clone https://github.com/shaunmulligan/runtt-boards && cd runtt-boards
./scripts/runtt-board backup adafruit_feather_nrf52840      # required; kept beside the repo
./scripts/runtt-board provision adafruit_feather_nrf52840 --name arm-01
```

The tool refuses to flash without a verified backup, deliberately. Both hex
files are flashed over SWD in order, without a reset in between. The name
becomes the board's USB serial, so `usb:arm-01` addresses it from now on.

## 2. Build your firmware image

Build the builder image once (from this repository's root):

```bash
podman build -f builder/Dockerfile -t runtt-builder:v4.4.2 .
```

Start from [runtt-examples/app1](https://github.com/shaunmulligan/runtt-examples/tree/main/app1)
— a Zephyr application directory with a six-line Dockerfile — put your source in
`src/`, then:

```bash
podman build --build-arg BOARD=adafruit_feather_nrf52840/nrf52840 -t my-app:v1 .
```

(The plain target, not `.../uf2` — the uf2 variant keeps Adafruit's partition
layout and has no MCUboot slots.)

## 3. Deploy

```bash
podman run --rm --network none --runtime=/usr/local/bin/runtt \
  --annotation dev.runtt.target=usb:arm-01 my-app:v1
```

The image uploads, MCUboot swaps and confirms it, and your application's logs
stream to container stdio for as long as it runs. Deploy a new version by
building `my-app:v2` and running it the same way; a broken image reverts by
itself. For Docker instead of podman, register the runtime once — see the
[runtt README](https://github.com/shaunmulligan/runtt#install).
