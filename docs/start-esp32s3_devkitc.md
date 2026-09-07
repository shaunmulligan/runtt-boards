# Getting started: ESP32-S3 DevKitC

Three steps from a stock board to your code running as a container. Assumes the
[runtt runtime](https://github.com/shaunmulligan/runtt#install) is installed.

**No probe needed**, and the board is not brickable: the ESP32-S3 boot ROM
always gives you the download mode this uses. Provisioning is `esptool` over the
board's own USB connector.

```bash
pip install esptool                     # the only extra tool this board needs
esptool --chip esp32s3 chip-id          # reads the MAC, writes nothing
```

## 1. Provision

```bash
curl -fLO https://raw.githubusercontent.com/shaunmulligan/runtt-boards/main/scripts/runtt-board
chmod +x runtt-board
./runtt-board provision esp32s3_devkitc --name esp-01
```

Both binaries and the identity record are written in **one** `esptool`
invocation — MCUboot at `0x0`, the confirmed slot-0 image at `0x20000`, the name
at `0x3b0000` — so there is a single reset, at the end, after everything has
landed. The name becomes the board's USB serial, so `usb:esp-01` addresses it
from now on.

> **A factory-fresh board needs no buttons.** Its ROM is already in download
> mode, so `esptool` finds it. **Re-provisioning a board that is already running
> runtt does**, because the application owns the USB PHY once it boots — see
> [One PHY, two owners](#one-phy-two-owners) below. Hold **BOOT**, tap
> **RESET**, release **BOOT**, then run the command again.

If more than one board is attached, name the port: `--port /dev/ttyACM0`.
Otherwise `esptool` picks one, and with two ESP boards present that is a coin
toss.

## 2. Build your firmware image

Build the builder image once (from this repository's root):

```bash
podman build -f builder/Dockerfile -t runtt-builder:v4.4.2 .
```

Start from [runtt-examples/app1](https://github.com/shaunmulligan/runtt-examples/tree/main/app1)
— a Zephyr application directory with a six-line Dockerfile — put your source in
`src/`, then:

```bash
podman build --build-arg BOARD=esp32s3_devkitc/esp32s3/procpu -t my-app:v1 .
```

The `runtt` snippet supplies this board's configuration, including the one
setting this SoC cannot do without: **deferred logging**. With
`CONFIG_LOG_MODE_IMMEDIATE=y`, every log call is written synchronously from
whichever context logs it — including the USB device thread and its interrupt
handlers — and a blocking UART write inside enumeration misses the host's
timing windows, so the composite never finishes coming up.

**Your `prj.conf` cannot break this**, which is worth knowing because example
applications do set immediate mode. Snippet fragments are merged *after*
`prj.conf`, so the snippet's `CONFIG_LOG_MODE_DEFERRED=y` wins — measured on
this board's target, not assumed. What does override it is a fragment merged
later still: `-DEXTRA_CONF_FILE=...` (or the per-image
`-D<app>_EXTRA_CONF_FILE=...`) on the build command line. Set immediate mode
there and USB stops working with nothing to say why.

One other thing to get right, because it fails *silently*: the snippet flag is
named after the **application directory**, since that is the sysbuild image
name. `-Dapp_SNIPPET=runtt` against a directory called `app1` applies no
snippet at all, configures cleanly and exits zero — the resulting image has no
USB contract, no SMP server and no runtt module in it.

## 3. Deploy

```bash
podman run --rm --network none --runtime=/usr/local/bin/runtt \
  --annotation dev.runtt.target=usb:esp-01 my-app:v1
```

The image uploads, MCUboot swaps and confirms it, and your application's logs
stream to container stdio for as long as it runs. Deploy a new version by
building `my-app:v2` and running it the same way; a broken image reverts by
itself.

## One PHY, two owners

The S3 has a single internal USB PHY, muxed between the ROM's USB-Serial/JTAG
and the USB-OTG controller. runtt's contract needs OTG, because
identity-addressed `usb:esp-01` placement depends on USB descriptors the
firmware owns and the ROM device cannot provide.

The consequence is the one thing about this board that surprises people: while
your application is running, the ROM's serial device is **gone**, so `esptool`
has nothing to talk to. That is not a fault. The ROM reclaims the PHY in
download mode, which is why the BOOT-button sequence above always works, and
firmware updates after provisioning go through runtt rather than `esptool`
anyway.

## Which module variant

Any of them. The partition table this board uses occupies roughly the first
4 MB, so one image is valid on N4, N8R8 and N16R8 alike — the bootloader notes a
flash larger than the image header describes and carries on. Only PSRAM would
force separate builds, and it is compiled in, so an R2 part needs its own image
where R8 does not.

---

*Co-authored with Claude*
