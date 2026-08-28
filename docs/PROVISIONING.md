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
./scripts/build-pico.sh mcuboot          # produces build-pico-mcuboot/provision.uf2
./scripts/flash-pico.sh build-pico-mcuboot/provision.uf2
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

Shipping an app in slot 0 means an unprovisioned-but-working board *enumerates*,
answers `describe`, and waits. It shows up as a service reporting a clear error
rather than as a port that does not exist, which is the difference between a
five-minute diagnosis and an hour of guessing.

The image is emitted as a **single contiguous region** with the gaps padded, and
it erases the whole of slot 0 as a side effect — which is what you want at
provisioning time.

## Adafruit Feather nRF52840 — probe required

The nRF52840 has **no USB ROM loader**, so there is no drag-and-drop equivalent.
Provisioning needs SWD, and flashing MCUboot to `0x0` destroys the Adafruit UF2
bootloader, the MBR and the bootloader settings page.

Before the first flash, back up **flash and UICR** — the latter holds
`BOOTLOADERADDR`, without which a restored flash leaves the bootloader
unfindable:

```bash
pyocd cmd -t nrf52840 -c "savemem 0x0 0x100000 flash_full.bin"
pyocd cmd -t nrf52840 -c "savemem 0x10001000 0x400 uicr.bin"
sha256sum *.bin | tee BACKUP.sha256
```

Also read `FICR.INFO.VARIANT` (`0x10000130`) and `UICR.APPROTECT` (`0x10001208`)
first: nRF52840 revision 3 ships with access-port protection enabled, and a true
chip-erase resets `UICR.APPROTECT` and locks the part at the next reset.
Recovery does not need a J-Link — both pyOCD and probe-rs implement the CTRL-AP
unlock over CMSIS-DAP — but it is destructive, hence the backup.

This asymmetry is a real argument for ROM-loader silicon in a product: on
RP2040 provisioning is a drag-and-drop that cannot brick; on nRF52840 it is a
probe, a backup, and a lock-out risk.

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
> SWD. See the note in `firmware/app/sysbuild.conf`.

---

*Co-authored with Claude*
