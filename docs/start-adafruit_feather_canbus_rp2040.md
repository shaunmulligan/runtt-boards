# Getting started: Adafruit RP2040 CAN Bus Feather

Three steps from a blank board to your code running as a container — deployable
over **USB or CAN**. Assumes the
[runtt runtime](https://github.com/shaunmulligan/runtt#install) is installed.

## 1. Provision the board

Once per board. No toolchain, no probe. Give it a CAN node id as well as a
name — the id is the board's address on the bus, and it owns three consecutive
ids (requests, replies, console), so space boards at least three apart:

```bash
git clone https://github.com/shaunmulligan/runtt-boards && cd runtt-boards
./scripts/runtt-board provision adafruit_feather_canbus_rp2040 \
    --name can-01 --can-node-id 0x45
```

Hold **BOOTSEL** while plugging the board in when asked. Success looks like:
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
podman build --build-arg BOARD=adafruit_feather_canbus_rp2040/rp2040/mcuboot -t my-app:v1 .
```

## 3. Deploy — over USB or over the bus

Over USB, exactly like the other boards:

```bash
podman run --rm --network none --runtime=/usr/local/bin/runtt \
  --annotation dev.runtt.target=usb:can-01 my-app:v1
```

Over CAN: wire CANH↔CANH, CANL↔CANL and GND to your host adapter (both ends
terminated — this board has 120 Ω onboard), bring the interface up once, then
address the board by its node id:

```bash
sudo modprobe can-isotp
sudo ip link set can0 up type can bitrate 500000 restart-ms 1000

podman run --rm --network none --runtime=/usr/local/bin/runtt \
  --annotation dev.runtt.target=can:can0/0x45 my-app:v1
```

Either way the image uploads, MCUboot swaps and confirms it, and your
application's logs stream to container stdio — over CAN they arrive as raw
frames on the node's third id. A broken image reverts by itself, over either
transport. For Docker instead of podman, register the runtime once — see the
[runtt README](https://github.com/shaunmulligan/runtt#install).
