# Getting started: Raspberry Pi Pico 2 W (RP2350)

Three steps from a blank board to your code running as a container. Assumes the
[runtt runtime](https://github.com/shaunmulligan/runtt#install) is installed.

## 1. Provision the board

Once per board. No toolchain, no probe — the image is downloaded and verified:

```bash
git clone https://github.com/shaunmulligan/runtt-boards && cd runtt-boards
./scripts/runtt-board provision rpi_pico2 --name pico2-01
```

Hold **BOOTSEL** while plugging the board in when asked (the drive is labelled
`RP2350` on this board). The name becomes the board's USB serial, so
`usb:pico2-01` addresses it from now on. Success looks like:
`flashed: the board left BOOTSEL.`

## 2. Build your firmware image

Build the builder image once (from this repository's root):

```bash
podman build -f builder/Dockerfile -t runtt-builder:v4.4.2 .
```

Start from [runtt-examples/app1](https://github.com/shaunmulligan/runtt-examples/tree/main/app1)
— a Zephyr application directory with a six-line Dockerfile — put your source in
`src/`, then:

```bash
podman build --build-arg BOARD=rpi_pico2/rp2350a/m33/w/mcuboot -t my-app:v1 .
```

The `/w` in the target matters: it is what brings in the wireless chip's wiring.

## 3. Deploy

```bash
podman run --rm --network none --runtime=/usr/local/bin/runtt \
  --annotation dev.runtt.target=usb:pico2-01 my-app:v1
```

The image uploads, MCUboot swaps and confirms it, and your application's logs
stream to container stdio for as long as it runs. Deploy a new version by
building `my-app:v2` and running it the same way; a broken image reverts by
itself. For Docker instead of podman, register the runtime once — see the
[runtt README](https://github.com/shaunmulligan/runtt#install).
