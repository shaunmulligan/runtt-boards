# Provisioning an MCU

The one physical act. Everything after it is remote.

Flashing the bootloader is what **enrols the trust root**: the key embedded in
MCUboot defines whose firmware the board will ever accept. That is why it cannot
be done over the air, and why it is the only step that needs someone at the
bench.

## Raspberry Pi Pico (RP2040) — no probe required

RP2040 has a **mask-ROM bootloader** that cannot be erased or overwritten. Hold
BOOTSEL while plugging the board in and it presents a small USB mass-storage
volume; drop a `.uf2` on it and it flashes and reboots itself.

That makes provisioning a drag-and-drop, with no debug probe, no SWD wiring and
no vendor tooling. It also makes the board effectively unbrickable: a failed
flash leaves you in BOOTSEL, ready to try again.

```bash
./scripts/build-pico.sh provision        # produces build-pico-idle/provision.uf2
./scripts/flash-pico.sh build-pico-idle/provision.uf2
```

Verify:

```bash
lsusb | grep 2fe3                        # the board, as a USB device
ls /dev/balena-mcu/                       # -mgmt and -log, via the udev rules
cargo run -p smp-client --example ping -- /dev/balena-mcu/*-mgmt
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

`flash-pico.sh` writes with `oflag=sync`, and afterwards checks whether the board
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

`balena-mcu-idle` (`firmware/idle/`) is that application: the module plus a
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

The flow is three commands, in this order:

```bash
./scripts/backup-nrf52840.sh          # FIRST. Not optional.
./scripts/build-feather.sh provision
./scripts/flash-feather.sh build-feather-idle
```

`flash-feather.sh` refuses to run if it cannot find a backup directory.

### Why the backup is not boilerplate

Recovery from a locked part is a **CTRL-AP `ERASEALL`**, which wipes flash *and*
UICR. UICR holds `BOOTLOADERADDR`, so a flash restored without it leaves the
Adafruit bootloader physically present but unfindable. `backup-nrf52840.sh`
takes both, checksums them, and refuses to call an all-`0xff` read a backup.

It also reads `FICR.INFO.VARIANT` (`0x10000130`) and `UICR.APPROTECT`
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

* **Never reset between an erase and writing firmware.** `flash-feather.sh`
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
> SWD. See the note in `firmware/sysbuild-common.conf`.

---

*Co-authored with Claude*
