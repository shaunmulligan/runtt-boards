# Porting runtt to a new device

What it takes to make a new microcontroller manageable by
[runtt](https://github.com/shaunmulligan/runtt), in the order that finds problems
soonest.

The work spans two repositories. Board configuration lives in
[`runtt-zephyr-module`](https://github.com/shaunmulligan/runtt-zephyr-module),
because it is part of the device half of the contract; the build, provisioning and
publishing live here.

**Budget half a day for a board Zephyr already supports well, and treat anything
else as an unknown.** Most of the elapsed time in past ports went on two things:
discovering a board target had no MCUboot slots, and USB descriptors.

---

## 0. Before you buy anything

Answer these from Zephyr's source, not from vendor marketing.
[`HARDWARE_TARGETS.md`](HARDWARE_TARGETS.md) has worked examples, including boards
that were rejected and why.

**Does Zephyr have the board?**

```bash
ls zephyr/boards/*/ | grep -i <board>
```

**Does the board target have MCUboot slots?** This is the one that has bitten
hardest. A board can be fully supported by Zephyr and still be unusable here,
because runtt needs a secondary slot to stage an image into.

```bash
grep -rn "slot0_partition\|slot1_partition" zephyr/boards/<vendor>/<board>/
```

If nothing comes back, look for a dedicated MCUboot variant of the target
(`rpi_pico/rp2040/mcuboot` exists; plain `rpi_pico` has no slots). If there is no
variant, you will have to write a partition overlay — doable, and it is the
difference between an afternoon and a day.

Beware the near-misses: `adafruit_feather_nrf52840/nrf52840` has slots,
`.../uf2` does not, because that variant keeps Adafruit's bootloader.

**Does it have a USB device controller, or will you need a second transport?**

```bash
grep -cE "usb_otg|usb_serial|usbd" zephyr/dts/.../<soc>_common.dtsi
```

Zero means no USB device support at all — classic ESP32 is the example. Such a
board can still work over CAN or a bare UART, but it cannot present the two-channel
USB contract, and you should decide that before ordering.

**How much flash is the bootloader slot?** MCUboot has to fit. 64 K is
comfortable; the Feather's 48 K boot partition is already 80% full.

---

## 1. Prove the toolchain before the contract

Build *anything* for the board first. A plain Zephyr sample, no runtt involved.

```bash
west build -p always -b <board> zephyr/samples/hello_world
```

This separates "my toolchain and board target are wrong" from "the contract is
wrong", and those two failures look identical from inside a runtt build.

---

### RP2350 (Pico 2 / Pico 2 W): connect under reset

pyocd cannot attach to an RP2350 on the first try:

```
Error while initing target: Unable to set target to secure mode
```

RP2350's flash routines live in ROM and require the core to be in secure state.
pyocd forces that by writing `DSCSR.CDS` and aborts if the core does not come
back secure (`pyocd/target/family/target_rp2.py`). Connecting under reset gets
past it, and once you have, later connections work too:

```bash
pyocd flash -t rp2350 -O connect_mode=under-reset firmware.hex
```

RP2040 has no secure state to negotiate and never hits this.

## 2. Board configuration, in the module repo

In [`runtt-zephyr-module`](https://github.com/shaunmulligan/runtt-zephyr-module),
add two files under `snippets/runtt/boards/`:

* `<board>.conf` — Kconfig for this board: which transport, USB or CAN, stack
  sizes that differ from the defaults.
* `<board>.overlay` — devicetree: the chosen SMP transport, the console, and for
  USB targets the two CDC-ACM instances **with their interface string
  descriptors**. Copy the closest existing board and change one thing at a time.

Then register it in `snippets/runtt/snippet.yml`. Board keys accept regexes, so
one entry can cover a target's variants.

The interface descriptors are contract, not decoration: `runtt-mgmt` and
`runtt-log` are what the host's udev rules and `resolve()` match on. A board that
enumerates with different strings will not be found, and the failure looks like a
missing device rather than a misconfiguration.

Verify with the module's own check:

```bash
./tests/contract_version.sh
```

---

## 3. Bring it up one variable at a time

Use `bringup/` here for configurations that isolate a single thing. Past ports
went wrong in ways that were only diagnosable because the variables were
separated:

1. **No bootloader, console on a UART.** Proves the board boots and the module
   compiles in. If USB is involved, this step deliberately avoids it.
2. **Add the SMP transport, still no bootloader.** Now `runtt` can talk to it:
   `describe` answers, logs arrive. The contract works before MCUboot is anywhere
   near it.
3. **Add MCUboot.** Only now can a deploy swap and confirm.

Skipping to step 3 is tempting and costs more than it saves — a board that will
not answer SMP after a swap gives you no clue which of the three layers broke.

---

## 4. Provisioning: MCUboot plus a confirmed idle image

Add a mode to a build script here, modelled on `scripts/build-pico.sh`
(UF2, no probe) or `scripts/build-feather.sh` (hex over SWD). It must produce
**MCUboot and a signed, confirmed image in slot 0**, because MCUboot with an
empty primary slot halts *silently* — no enumeration, no device node, and a board
in that state is indistinguishable from a dead one. That is what `idle/` is for.

Two traps, both of which produce an image that passes `imgtool verify` and then
locks the board up:

* **Sign for the primary slot with `--pad --confirm`**, not with `--pad-header`,
  when the application already reserves header space via
  `CONFIG_ROM_START_OFFSET`. Padding a header twice puts the vector table at the
  wrong offset.
* **Pin the swap mode.** `SB_CONFIG_MCUBOOT_MODE_SWAP_USING_OFFSET=y` in
  `sysbuild-common.conf`, because a bootloader and application built with
  different swap modes fail in ways that look like corruption.

Anything in this repo that resolves a path must go through `west topdir`, not the
repo root: `zephyr/`, `modules/` and `bootloader/` sit *beside* this repository in
a workspace, not inside it.

---

## 5. Declare it, and let CI do the rest

Add an entry to [`boards.yml`](../boards.yml). While bringing up, mark it
`in-progress` — it is then visible to everyone and built by nobody:

```yaml
  - id: <zephyr board target>
    name: <what a human calls it>
    soc: <soc>
    status: in-progress
    notes: what is still needed
```

Promote it to `supported` **only once a provisioning image has been flashed to
real hardware and a deploy confirmed**, and add the build and provision fields:

```yaml
    status: supported
    build:
      script: scripts/build-<board>.sh
      mode: provision
    provision:
      - from: build-<board>-idle/provision.uf2
        as: provision-<board>.uf2
    flash: what a user does
    probe: true|false
    notes: anything they must know BEFORE flashing
```

Then regenerate the README and let CI check it:

```bash
./scripts/boards.py --write-readme
./scripts/boards.py --check-readme
```

CI builds every `supported` board, collects its artefacts and attaches them to the
next release. You do not touch the workflow.

---

## 6. What "working" means

A port is done when all of these hold on real hardware, not in a simulator:

- [ ] `runtt`'s `describe` reports the board, the contract version and the channel count
- [ ] Application logs reach container stdio (`docker logs`)
- [ ] A deploy uploads, swaps, and **confirms**
- [ ] A deliberately broken image **fails to confirm and reverts** on the next reset
- [ ] Unplugging the board exits non-zero, so a restart policy fires
- [ ] A provisioning image flashed to a factory-fresh board yields a device that
      enumerates and reports `idle: true`

The fourth is the one people skip and the one that matters most: it is the whole
safety property. If a bad image can confirm itself, remote updates are one mistake
away from a truck roll.

---

## Testing discipline, learned the hard way

**Run the full sequence from a clean tree, in CI's order.** A stale build
directory from an earlier run made a wrong default look correct for days, and the
bug only surfaced in CI where the steps run in a different order and nothing is
left over.

**A script default that is right half the time is worse than none.** Two bugs in
this repository were plausible defaults naming one of the two directories a caller
might mean. Make such arguments required.

**Check the artefact, not the source.** Grep the linked ELF for the interface
descriptor strings. Three USB descriptor strings survived a project-wide rename
because every check looked at source files:

```bash
strings build/zephyr/zephyr.elf | grep -E "^runtt-(mgmt|log)$"
```

---

*Co-authored with Claude*
