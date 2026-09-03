# Provisioning an MCU

The one physical act. Everything after it is remote.

Flashing the bootloader is what **enrols the trust root**: the key embedded in
MCUboot defines whose firmware the board will ever accept. That is why it cannot
be done over the air, and why it is the only step that needs someone at the
bench.

> **Paths below are from the monorepo layout these transcripts were recorded
> in.** The repositories have since been split, so `firmware/app` is now
> `boards/app-test` (or `boards/idle`) in
> [`runtt-boards`](https://github.com/shaunmulligan/runtt-boards),
> `firmware/bringup` is `boards/bringup`, and `firmware/runtt` is its own
> repository, checked out by west at `modules/runtt`. The commands are left as
> they were run rather than retyped untested; `-DZEPHYR_EXTRA_MODULES` in
> particular is no longer needed at all, because west now registers the module
> from the manifest. See `scripts/build-feather.sh`, `build-pico.sh` or
> `build-pico2w.sh` in this repository for the current invocation.

## Raspberry Pi Pico (RP2040) — no probe required

RP2040 has a **mask-ROM bootloader** that cannot be erased or overwritten. Hold
BOOTSEL while plugging the board in and it presents a small USB mass-storage
volume; drop a `.uf2` on it and it flashes and reboots itself.

That makes provisioning a drag-and-drop, with no debug probe, no SWD wiring and
no vendor tooling. It also makes the board effectively unbrickable: a failed
flash leaves you in BOOTSEL, ready to try again.

```bash
./scripts/build-pico.sh provision        # produces build-pico-idle/provision.uf2
./scripts/runtt-board flash rpi_pico
```

Verify:

```bash
lsusb | grep 2fe3                        # the board, as a USB device
ls /dev/runtt/                       # -mgmt and -log, via the udev rules
cargo run -p runtt-smp --example ping -- /dev/runtt/*-mgmt
```

A provisioned board answers `describe` with its board target, contract version
and channel count.

### Use the script, not `cp`

`cp` returns once the data is in the page cache, not once it has reached the
device. The bootrom writes each UF2 block as it arrives and reboots only when it
has received them all, so a truncated transfer fails **silently**: either the
board sits in BOOTSEL waiting for blocks that never come, or it reboots having
written only the early part of the image — a board that looks flashed and is not.

That cost an hour of debugging a bootloader that was behaving perfectly. It also
scales badly with size: the small images completed by luck, the 1.8 MB
provisioning image did not.

`runtt-board flash` writes and syncs, and afterwards checks whether the board
actually left BOOTSEL, which is the only reliable signal that the flash was
accepted.

## What goes in the image, and why an app is included

Two things:

1. **MCUboot**, at the start of flash. Enrols the trust root.
2. **A signed, confirmed application in slot 0.**

The second is not optional, and the reason is worth stating. MCUboot with an
empty primary slot halts with `Unable to find bootable image`, and — because it
has no USB of its own — does so **completely silently**. No enumeration, no
device node, nothing. A board in that state is indistinguishable from one that is
unplugged or dead.

`runtt-idle` (`idle/` in this repository) is that application: the module plus a
no-op main. It reports `idle: true` over `describe`, so the runtime can say

    device is rpi_pico/rp2040/mcuboot freshly provisioned, awaiting its first firmware

rather than treating a factory-fresh board as though it were running something
unrecognised. Those two states look identical otherwise and warrant completely
different reactions.

Shipping an app in slot 0 means an unprovisioned-but-working board *enumerates*,
answers `describe`, and waits. It shows up as a service reporting a clear error
rather than as a port that does not exist, which is the difference between a
five-minute diagnosis and an hour of guessing.

The image is emitted as a **single contiguous region** with the gaps padded, and
it erases the whole of slot 0 as a side effect — which is what you want at
provisioning time.

## Adafruit Feather nRF52840 — probe required

The nRF52840 has **no USB ROM loader**, so there is no drag-and-drop equivalent
and no BOOTSEL to fall back on. Every flash needs SWD, and flashing MCUboot to
`0x0` destroys the Adafruit UF2 bootloader, the MBR and the bootloader settings
page.

### Wiring

Every flash needs SWD, so this is the first thing to get right. The Feather's
2×5 0.05″ (1.27 mm) header needs an adapter; these labels are the Adafruit #2743
breakout, which is signal-labelled rather than numbered:

| Probe wire | Breakout pad | Signal | Cortex-10 pin |
|---|---|---|---|
| orange | `CLK` | SWCLK | 4 |
| yellow | `SWIO` | SWDIO | 2 |
| black | `GND` (either) | GND | 3 or 5 |

Leave `Vref`, `SWO`, `NC` and `KEY` unconnected — the Raspberry Pi Debug Probe is
fixed 3.3 V logic and does not sense VTREF. Pin 1 is marked with a ▶ beside
`Vref`.

Wire colours follow the [3-pin debug connector specification][rpi-debug-spec]:
connector pin 1 = SC (serial clock) = orange, pin 2 = GND = black, pin 3 = SD
(bidirectional data) = yellow.

**The probe cannot drive reset.** The D port carries only SC, GND and SD, so
`pyocd --connect under-reset` is unavailable. Wire the breakout's `!RST` pad out
if you want a reset you control: momentarily jumper it to GND. It is active low,
so leaving it grounded holds the part in reset. That is the lever if APPROTECT
recovery ever needs reset timing controlled — see below.

Prove the wiring before anything destructive. This reads the chip ID and writes
nothing:

```bash
pyocd cmd -t nrf52840 -c "read32 0x10000104"   # FICR.INFO.VARIANT
```

[rpi-debug-spec]: https://datasheets.raspberrypi.com/debug/debug-connector-specification.pdf

### The flow

Three commands, in this order:

```bash
./scripts/backup-nrf52840.sh          # FIRST. Not optional.
./scripts/build-feather.sh provision
./scripts/runtt-board flash adafruit_feather_nrf52840
```

`runtt-board flash` refuses to run on the Feather if it cannot find a
backup directory holding both `flash_full.bin` and `uicr.bin`, and verifies
`BACKUP.sha256` when one is present -- a truncated backup restores to a brick as
thoroughly as no backup.

### Why the backup is not boilerplate

Recovery from a locked part is a **CTRL-AP `ERASEALL`**, which wipes flash *and*
UICR. UICR holds `BOOTLOADERADDR`, so a flash restored without it leaves the
Adafruit bootloader physically present but unfindable. `backup-nrf52840.sh`
takes both, checksums them, and refuses to call an all-`0xff` read a backup.

It also reads `FICR.INFO.VARIANT` (`0x10000104`) and `UICR.APPROTECT`
(`0x10001208`) before touching anything. A build code ending `F0` means a
revision 3 part, where APPROTECT is enabled in hardware at every reset.

### The one way to actually get stuck

Per Nordic, after an `ERASEALL` *"the device should be accessible to a debugger
until it executes a pin, power, or brownout reset"*. So if the part re-locks
between the erase and the write, you need the **nRESET** line to control the
timing. There is a [DevZone case][devzone-nreset] where a custom board did not
route nRESET and the thread ends with no successful recovery.

**The Feather routes RESET** — button and header pin — so that deadlock does not
apply here. Two rules follow:

* **Never reset between an erase and writing firmware.** `runtt-board flash`
  sends both images in one pyocd session for exactly this reason.
* **Never set `CONFIG_NRF_APPROTECT_LOCK`** (`zephyr/soc/nordic/Kconfig`). It
  locks the debug port from `SystemInit()` on every boot. Zephyr's nRF52 default
  is `NRF_APPROTECT_USE_UICR`, which is the safe one.

Neither pyOCD nor probe-rs needs a J-Link for the unlock; both implement CTRL-AP
over CMSIS-DAP.

### Can the Adafruit bootloader be kept?

Not usefully. There is a `uf2` board variant, but its layout
(`nordic/nrf52840_partition_uf2_sdv6.dtsi`) is:

```
0x00000  SoftDevice s140 v6    152 KB   read-only
0x26000  Application           792 KB
0xec000  Storage                32 KB
0xf4000  UF2 bootloader         48 KB   read-only
```

There is **no `slot0`/`slot1`**, and `boot_partition` is the UF2 bootloader
itself — so there is nothing for MCUboot to swap between. Keeping it would mean
hand-authoring a partition overlay and chain-loading MCUboot at `0x26000`,
behind Nordic's MBR, leaving roughly **372 KB per slot against 472 KB** and
reserving 152 KB for a SoftDevice we do not use. Unsupported and unverified.

The backup makes this reversible, which is the point: restore `flash_full.bin`
and `uicr.bin` and the Adafruit bootloader is back.

### The layout we use

From `nordic/nrf52840_partition.dtsi`, which the plain
`adafruit_feather_nrf52840/nrf52840` target includes:

| Region | Address | Size |
|---|---|---|
| `boot_partition` (MCUboot) | `0x00000` | 48 KB |
| `slot0_partition` | `0x0c000` | 472 KB |
| `slot1_partition` | `0x82000` | 472 KB |
| `storage_partition` | `0xf8000` | 32 KB |

No scratch partition, which suits `SB_CONFIG_MCUBOOT_MODE_SWAP_USING_OFFSET`.

**MCUboot uses 80% of its 48 KB partition** (39,680 bytes as built), against
63.5 KB on RP2040. `build-feather.sh` warns below 25% headroom, because serial
recovery is the thing most likely to push it over.

This asymmetry is a real argument for ROM-loader silicon in a product: on
RP2040 provisioning is a drag-and-drop that cannot brick; on nRF52840 it is a
probe, a backup, and a lock-out risk.

[devzone-nreset]: https://devzone.nordicsemi.com/f/nordic-q-a/128196/nrf52840-locked-with-approtect-unable-to-recover-flash-without-nreset-pin

## Recovering a board with nothing bootable

On RP2040: BOOTSEL. Always. Re-flash the provisioning image.

Elsewhere, MCUboot's **serial recovery** can stand in. Built with
`BOOT_SERIAL_UART` and `BOOT_SERIAL_NO_APPLICATION`, MCUboot stays in recovery
when it finds nothing bootable and serves SMP over a UART, so firmware can be
pushed with the ordinary runtime instead of a probe. Verified working on RP2040
through a debug probe's UART bridge.

It is a **bench aid, not a shipped configuration**: it takes over the UART (so
MCUboot's own console goes away) and it is a second write path. Note it is the
*UART* variant — `BOOT_SERIAL_CDC_ACM` depends on MCUboot's legacy USB stack,
which Zephyr removes in 4.5 and which
[mcuboot#2596](https://github.com/mcu-tools/mcuboot/issues/2596) has not yet
addressed.

## Giving a board its identity

Provisioning writes one more thing beyond MCUboot and the idle app: a 32-byte
identity record carrying the board's CAN node id and serial. It goes at the start
of `storage_partition`, outside both MCUboot slots, so firmware updates never
touch it.

This is what lets **one firmware image serve a whole fleet**. Without it a CAN
node id is a Kconfig symbol, so every board on a bus needs its own build — and
since firmware ships as an OCI image, its own image in the registry.

```bash
# Build the record. --can-node-id is only needed for boards on a CAN bus;
# --serial is useful on any board, as identity beyond a USB port path.
./scripts/make-identity.py --can-node-id 0x45 --serial arm-01 \
  -o identity.bin --board adafruit_feather_nrf52840

# Write it. The address is the board's storage_partition, which --board prints.
pyocd flash -t nrf52840 --base-address 0xf8000 identity.bin
```

| Board | `storage_partition` |
|---|---|
| `adafruit_feather_nrf52840` | `0xf8000` |
| `rpi_pico` | `0x1b0000` (`0x101b0000` XIP-mapped) |
| `esp32s3_devkitc` | `0x3b0000` |
| `native_sim` | `0xfc000` |

Verify it took by asking the board:

```console
$ cargo run -p runtt-smp --example ping -- /dev/runtt/<tag>-mgmt
  describe -> Describe { ..., provisioned: Some(true), serial: Some("arm-01") }
```

A board with no record uses its built-in defaults, which is the correct factory
behaviour — that is what keeps an unprovisioned board answering `describe`. A
board with a *damaged* record refuses to bring up CAN rather than guessing an
address; see docs/WIRE_CONTRACT.md for why those two cases differ.

## Signing

> ⚠️ The build default signs with MCUboot's `root-rsa-2048.pem`, which is the
> **private** key and is published in the MCUboot repository. The image verifies,
> `imgtool verify` says "correctly validated", and no trust root is actually
> enrolled — anyone who can reach the SMP transport can push firmware the
> bootloader will accept.
>
> Since provisioning is precisely when the trust root is set, a per-fleet key has
> to be in place *before* boards are provisioned: the public half is baked into
> MCUboot at this step, so changing it later means re-flashing every board over
> SWD. See the note in `sysbuild-common.conf`.

---

*Co-authored with Claude*

## Feather bring-up over the probe's UART bridge

Verified 2026-08-30 on an nRF52840 rev `AAC0`. This stage needs **no MCUboot and
destroys nothing** — the Adafruit MBR, SoftDevice and UF2 bootloader all survive,
because the application is linked at `0x26000` where the Adafruit stack expects
one, rather than at `0x0`.

```bash
west build -p always -b adafruit_feather_nrf52840/nrf52840 \
  --snippet runtt firmware/app -d build-feather -- \
  -DZEPHYR_EXTRA_MODULES="$PWD/firmware/runtt" \
  -DEXTRA_DTC_OVERLAY_FILE="$PWD/firmware/bringup/feather-uart.overlay" \
  -DEXTRA_CONF_FILE="$PWD/firmware/bringup/feather-uart.conf"

pyocd flash -t nrf52840 --base-address 0x26000 build-feather/zephyr/zephyr.bin
pyocd cmd -t nrf52840 -c reset
```

Then, on the probe's UART bridge:

```
$ cargo run -p runtt-smp --example ping -- /dev/ttyACM0
  echo -> "runtt"
  image list -> no images
  describe -> board: "adafruit_feather_nrf52840/nrf52840", channels: 1, img: true
```

`no images` is expected here: the img group is present but nothing is managing
slots without a bootloader. The point of this stage is that **MCUmgr, the
contract and the runtime are proven over a wire that cannot enumerate wrong**, so
when USB is introduced the only new variable is USB.

Note this is also the single-channel configuration: SMP and log output share one
link, and the runtime demultiplexes them by the console transport's framing
markers. The app logs every two seconds throughout, and SMP is unaffected.

### Testing the wiring without any firmware

Both SWD and UART can be confirmed before flashing anything, by driving the
nRF52840's UARTE peripheral straight from the debugger — write a string into RAM,
point `TXD.PTR` at it, set `PSEL.TXD` to P0.25 and trigger `TASKS_STARTTX`; the
reverse with `PSEL.RXD`/`TASKS_STARTRX` for the other direction. A reset clears
it. If RX reads back empty, check `EVENTS_RXDRDY` (`0x40002108`) before blaming
the wiring — it distinguishes "no signal reached the pin" from "the read raced
the DMA", which is a mistake worth not repeating.

## Feather: full provisioning with MCUboot

Verified 2026-08-30, end to end: a container run deploys firmware to an Adafruit
Feather nRF52840 and MCUboot swaps and confirms it.

Re-verified 2026-09-02 through the consolidated tool, from the published release
rather than a local build:

```
$ runtt-board provision adafruit_feather_nrf52840/nrf52840 --name feather-01
  checksums verified (2 files)
  backup: ../feather-backup-20260902 (checksums verified)
  $ pyocd flash -t nrf52840 .../provision-adafruit_feather_nrf52840-mcuboot.hex
  Erased 40960 bytes (10 sectors), programmed 40960 bytes at 23.89 kB/s
  $ pyocd flash -t nrf52840 .../provision-adafruit_feather_nrf52840-slot0.hex
  Erased 81920 bytes (20 sectors), programmed 81920 bytes at 24.46 kB/s
  $ pyocd flash -t nrf52840 --base-address 0xf8000 .../identity.bin

$ podman run --rm --network none --runtime=.../runtt \
    --annotation dev.runtt.target=usb:feather-01 app:v1
  mcu: board serial feather-01
  mcu: device is adafruit_feather_nrf52840/nrf52840 freshly provisioned,
       awaiting its first firmware (contract 2.0.0, 2 channels)
  mcu: uploading 80008/80008 bytes (100%)
  mcu: image staged and marked test, resetting
  mcu: image confirmed
  <inf> runtt_identity: provisioned: can node id 0xffff, serial "feather-01"
  <inf> usbd_init: bNumInterfaces 4 wTotalLength 141
  <inf> runtt_usbd: USB device up with all contract channels registered
  <inf> app: alive, tick 0
```

Two things that come out of that transcript rather than from reasoning. The
board is addressed by **serial**, not port path, so the identity record written
at `0xf8000` is what the placement label resolves against. And a second run of
the same image reports `device already runs this digest, confirmed; nothing to
do` — the deploy is idempotent, and re-running it does not re-flash.

**This is the destructive step.** It overwrites the Nordic MBR, the SoftDevice
and the Adafruit UF2 bootloader -- `slot1_partition` spans `0xf4000`, where the
bootloader lives. Afterwards the only recovery path is SWD. Take the backup
first (`pyocd cmd -t nrf52840 -c "savemem 0x0 0x100000 flash_full.bin"` plus
UICR at `0x10001000`), and check the sha256.

```bash
west build -p always -b adafruit_feather_nrf52840/nrf52840 --sysbuild firmware/app \
  -d build-feather -- -DZEPHYR_EXTRA_MODULES="$PWD/firmware/runtt" \
  -Dapp-test_SNIPPET=runtt

# A confirmed image for the PRIMARY slot: --pad --confirm, and no --pad-header
# (the app already reserves its header via CONFIG_ROM_START_OFFSET).
python3 bootloader/mcuboot/scripts/imgtool.py sign \
  --key bootloader/mcuboot/root-rsa-2048.pem \
  --header-size 0x200 --align 4 --version 0.1.0 \
  --slot-size 0x76000 --pad --confirm \
  build-feather/app-test/zephyr/zephyr.bin slot0.bin

pyocd flash -t nrf52840 --base-address 0x0     build-feather/mcuboot/zephyr/zephyr.bin
pyocd flash -t nrf52840 --base-address 0xc000  slot0.bin
pyocd cmd -t nrf52840 -c reset
```

Layout is Nordic's standard `nrf52840_partition.dtsi`: MCUboot `0x0..0xc000`
(39 KB of 48 KB used, 81% -- tight), slot0 `0xc000..0x82000`, slot1
`0x82000..0xf8000`.

### The one board-specific defect worth knowing

Zephyr's default `UDC_NRF_THREAD_STACK_SIZE` is 512 bytes, and that is not
enough for two CDC-ACM instances. The driver thread overflows the first time USB
suspend is handled, and it presents as an MPU **Instruction Access Violation**
jumping into a data symbol, with `xpsr` showing the Thumb bit clear -- a call
through a pointer holding a data address. It fires immediately after
`udc_nrf: SUSPEND state detected`, and the board simply never enumerates.

`CONFIG_UDC_NRF_THREAD_STACK_SIZE=2048` in the board conf fixes it. Isolated by
bisection on hardware: that line alone, nothing else.

Debugging tip that made this findable: build with the console on `uart0` rather
than the USB log channel while bringing USB up. A console on a channel that
never enumerates has nowhere to print the fatal error explaining why -- the
board just looks silently dead. `bringup/feather-usb-uartconsole.overlay`
does exactly that.
