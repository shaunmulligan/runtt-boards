---
name: port-a-board
description: >
  Port a new microcontroller or development board to runtt, the OCI runtime that
  deploys firmware to MCUs as container images. Use whenever someone wants to add
  board support, asks "can runtt run on <board>", wants to know whether a board is
  suitable, is bringing up a new MCU, needs to produce a provisioning image for a
  new device, is adding an entry to boards.yml, or is debugging a board that will
  not enumerate, will not answer SMP, or will not confirm an image after a swap.
  Also trigger for "add a board", "new target", "does this board work", "port to
  ESP32/STM32/nRF/RP2040", "MCUboot slots", "provisioning image for a new board",
  or questions about board .conf/.overlay files and interface string descriptors.
---

# Porting a board to runtt

You are helping someone make a new microcontroller manageable by runtt. Work
through this in order — it is arranged so the expensive discoveries happen first.

**Read [`docs/PORTING.md`](../../../docs/PORTING.md) for the full detail.** This skill
is the decision procedure and the failure modes; that document is the reference.

## The work spans two repositories

| Repo | What goes there |
|---|---|
| [`runtt-zephyr-module`](https://github.com/shaunmulligan/runtt-zephyr-module) | the board's `.conf` and `.overlay` under `snippets/runtt/boards/`, and its `snippet.yml` entry |
| `runtt-boards` (this one) | the build script mode, the provisioning image, the `boards.yml` entry |

Do not put board configuration in `runtt-boards`. It belongs with the device half
of the contract, which is what firmware authors add to their own `west.yml`.

## Step 1 — screen the board before anything is bought or built

Answer all four from Zephyr's source. Report the answers before proceeding: a
"no" on the second or third changes what is worth doing.

```bash
# 1. Does Zephyr have the board?
ls zephyr/boards/*/ | grep -i <board>

# 2. Does the board target have MCUboot slots?  <-- the one that bites
grep -rn "slot0_partition\|slot1_partition" zephyr/boards/<vendor>/<board>/

# 3. Is there a USB device controller?  (0 means no USB contract, ever)
grep -cE "usb_otg|usb_serial|usbd" zephyr/dts/*/*/<soc>*_common.dtsi

# 4. How big is the bootloader slot? MCUboot must fit; 48 K is already tight.
```

**Watch for near-misses on question 2.** A board can be well supported by Zephyr
and still unusable, because runtt stages images into a secondary slot:

* `rpi_pico` has no slots; `rpi_pico/rp2040/mcuboot` does.
* `adafruit_feather_nrf52840/nrf52840` has them; `.../uf2` does not, because that
  variant keeps Adafruit's bootloader.

If there are no slots and no MCUboot variant, a partition overlay must be written.
Say so explicitly — it roughly doubles the work.

If question 3 returns 0, the board cannot present the two-channel USB contract at
all. It may still work over CAN or a bare UART. Classic ESP32 is the example;
say this before someone orders hardware.

## Step 2 — prove the toolchain, not the contract

Build a plain Zephyr sample first, with no runtt involved:

```bash
west build -p always -b <board> zephyr/samples/hello_world
```

This separates "the toolchain or board target is wrong" from "the contract is
wrong". Those two failures are indistinguishable from inside a runtt build, and
conflating them has cost days.

## Step 3 — add board configuration, one variable at a time

In the module repo, copy the closest existing board's `.conf` and `.overlay` and
change **one thing at a time**. Then bring up in this order, never skipping ahead:

1. No bootloader, console on a UART. Proves the board boots and the module
   compiles in. Deliberately avoids USB.
2. Add the SMP transport, still no bootloader. `describe` answers, logs arrive.
   The contract works before MCUboot is anywhere near it.
3. Add MCUboot. Only now can a deploy swap and confirm.

Going straight to 3 is tempting and costs more than it saves: a board that will
not answer after a swap gives no clue which of the three layers broke.

The interface string descriptors `runtt-mgmt` and `runtt-log` are **contract**.
The host matches on them; a board with different strings is simply not found, and
the symptom looks like absent hardware rather than misconfiguration. Verify in the
built artefact, not the source:

```bash
strings build/zephyr/zephyr.elf | grep -E "^runtt-(mgmt|log)$"
```

## Step 4 — the provisioning image

It must contain MCUboot **and a signed, confirmed image in slot 0**. MCUboot with
an empty primary slot halts *silently* — no enumeration, no device node — and such
a board is indistinguishable from a dead one. `idle/` exists for exactly this.

Two traps that both yield an image passing `imgtool verify` and then locking the
board up:

* Sign for the primary slot with `--pad --confirm`. Do **not** add
  `--pad-header` when the application already reserves header space via
  `CONFIG_ROM_START_OFFSET` — padding twice puts the vector table at the wrong
  offset.
* Pin the swap mode (`SB_CONFIG_MCUBOOT_MODE_SWAP_USING_OFFSET=y`). A bootloader
  and application built with different swap modes fail in ways that look like
  flash corruption.

Resolve every path through `west topdir`. `zephyr/`, `modules/` and `bootloader/`
sit beside this repository, not inside it.

## Step 5 — declare it in boards.yml

`boards.yml` drives the CI build list, the release assets and the README table.
Add the board as `in-progress` while bringing it up — visible to everyone, built
by nobody — and promote it to `supported` **only after a provisioning image has
been flashed to real hardware and a deploy confirmed**.

```bash
./scripts/boards.py --write-readme    # regenerate the table
./scripts/boards.py --check-readme    # what CI runs
```

Never hand-edit the generated README block, and never add assets to the workflow
directly. If you are editing `.github/workflows/ci.yml` to add a board, something
has gone wrong.

## Step 6 — the definition of done

Insist on all six, on real hardware:

- [ ] `describe` reports board, contract version and channel count
- [ ] Application logs reach container stdio
- [ ] A deploy uploads, swaps and **confirms**
- [ ] A deliberately broken image **fails to confirm and reverts** on next reset
- [ ] Unplugging exits non-zero, so a restart policy fires
- [ ] A factory-fresh board flashed with the provisioning image enumerates and
      reports `idle: true`

The fourth is the one people skip and the one that matters: it is the entire
safety property. If a bad image can confirm itself, every remote update is one
mistake from a truck roll. Test it by deliberately breaking the contract — build
an image with the SMP transport disabled and check the board comes back on the
old firmware.

## How to work on this

**Verify, do not infer.** A Kconfig symbol being set does not prove the code path
runs. Check the artefact.

**Run the whole sequence from a clean tree, in CI's order.** `rm -rf build*`
first. A stale build directory once made a wrong default look correct for days,
and it surfaced only in CI where the step order differs.

**Never weaken a safety check to make something pass.** `flash-feather.sh`
refusing to flash without a verified backup is protecting a bootloader with no ROM
loader behind it.

**Report what did not work.** A port with one unmet checkbox is useful
information; a port claimed complete with a checkbox quietly skipped is worse than
no port, because someone will trust it.
