# Hardware targets

A register of the boards this project runs on: what each one proves, what Zephyr
gives us upstream, and what we have to write ourselves. Prices and stock are from
The Pi Hut as of **2026-08-30** and will age; the Zephyr claims are checked against
the pinned **v4.4.2** tree in this repo and are reproducible with the commands
shown.

Related: [ROADMAP.md](ROADMAP.md) for why these targets, [HARDWARE_GATE.md](HARDWARE_GATE.md)
for the CI story, [WIRE_CONTRACT.md](WIRE_CONTRACT.md) for what a board must present.

---

## On the bench today

| Board | Target | Status |
|---|---|---|
| Adafruit Feather nRF52840 Express | `adafruit_feather_nrf52840/nrf52840` | **Working end to end** — dual CDC-ACM, MCUboot swap/confirm, `docker run` |
| Raspberry Pi Pico 1 (RP2040) | `rpi_pico/rp2040/mcuboot` | **Working end to end** |
| Raspberry Pi Debug Probe | — | SWD + UART, firmware v2.3.1 |

Both working boards use USB. **Neither can test CAN**: nRF52840 has no CAN
peripheral at all, and RP2040 has no CAN controller Zephyr can drive (its
`drivers/can/` has ~20 drivers, none for RP2040 — the popular can2040 PIO software
controller is an ESP-IDF/Klipper-world thing with no Zephyr equivalent).

That gap is what the boards below are for.

---

## On order

| Board | Price | Buys us |
|---|---|---|
| Waveshare ESP32-S3-DEV-KIT-N16R8 | £10.60 | ESP32 milestone **and** CAN via TWAI |
| Adafruit RP2040 CAN Bus Feather (MCP2515) | £19.20 | CAN on silicon we already know |
| Raspberry Pi Pico 2 W (RP2350) | £6.70–£7.70 | Later USB bring-up on Cortex-M33 |

Two boards with **different CAN controllers** is deliberate. MCP2515 (SPI,
standalone) and TWAI (on-die, SJA1000-compatible) exercise completely different
Zephyr drivers under the same `isotp` API. If our transport works on both, it is
controller-agnostic in fact and not just in intent. Two of the same controller
would not prove that. CAN is also a bus — the robotics demo wants ≥2 nodes anyway.

---

### 1. Waveshare ESP32-S3-DEV-KIT-N16R8 — £10.60

ESP32-S3-WROOM-1-N16R8: 16 MB flash, 8 MB PSRAM. Despite the vendor, the silkscreen
is honest — it is a **pin-compatible derivative of Espressif's ESP32-S3-DevKitC-1**,
so Zephyr's `esp32s3_devkitc` target applies. Chosen over Espressif's own board
(£28.90) because it is the same thing for a third of the price.

**What upstream already gives us — and it is a lot:**

```console
$ grep -n "twai" -A6 zephyr/boards/espressif/esp32s3_devkitc/esp32s3_devkitc-pinctrl.dtsi
103:	twai_default: twai_default {
104-		group1 {
105-			pinmux = <TWAI_TX_GPIO5>, <TWAI_RX_GPIO6>;
```

TWAI pinctrl is written for this exact board — only the c3/h2/s3 devkits have it,
the classic-ESP32 boards do not. `zephyr,canbus = &twai` is already the chosen node
(`esp32s3_common.dtsi:22`), so `smp_can.c` binds with no chooser override. And
`usb_otg@60080000` exists (`esp32s3_common.dtsi:430`), so the dual CDC-ACM contract
ports over — unlike classic ESP32, which has **no USB device controller at all**
(zero `usb_otg`/`usb_serial` nodes in `esp32_common.dtsi`).

**What we have to write** — all in a new snippet board file, mirroring the four we
already carry:

1. **Module dtsi swap.** The stock board dts includes `esp32s3_wroom_n8.dtsi`
   (8 MB flash, *no PSRAM*). We want `esp32s3_wroom_n16r8.dtsi`, which exists
   upstream. The whole difference is two properties:
   ```dts
   &flash0 { reg  = <0x0 DT_SIZE_M(16)>; };
   &psram0 { size = <DT_SIZE_M(8)>;      };
   ```
2. **Partition table.** `esp32s3_devkitc` includes `partitions_0x0_amp_4M.dtsi` — a
   4 MB layout, on a board that has 8 MB even in its stock form. Left alone it maps
   the bottom quarter of our 16 MB and ignores the rest. Options:

   | Table | slot0 / slot1 each | Note |
   |---|---|---|
   | `partitions_0x0_amp_4M` (stock) | 1344 K | wastes 12 MB |
   | `partitions_0x0_amp_16M` | 5952 K | reserves appcpu image slots |
   | `partitions_0x0_default_16M` | 7936 K | no appcpu slots — likely right for us |

   Our firmware is procpu-only, so `default_16M` is the probable pick. Decide when
   porting, not before.
3. **`status = "okay"` on the TWAI node** — it ships `disabled`
   (`esp32s3_common.dtsi:396`); the board dts supplies pinctrl but not status.

**Wiring.** GPIO5 → SN65HVD230 `D`/TXD, GPIO6 → `R`/RXD, **3.3 V** (the
SN65HVD230 is a 3.3 V part — this is why it is the standard pairing for ESP32 and
RP2040 rather than the 5 V TJA1050). The TWAI is a controller with no on-die
transceiver, which is exactly the half the Waveshare SN65HVD230 board supplies.

**The USB arrangement is unusual and affects us.** One USB-C goes into an onboard
**CH334 hub**, which fans out to a **CH343** USB-UART bridge *and* the S3's native
USB. One cable, two independent devices. Consequences:

- **The port path gets deeper.** Our annotation is `dev.runtt.target=usb:3-4`;
  behind the hub the native USB lands at something like `3-4.1`. `resolve()` reads
  the port path from `DEVPATH` generically so it handles this, but the string you
  write in the annotation is not the one you would write for a hub-less board.
  Arguably a *better* test than a clean board — real robots put MCUs behind hubs.
- **Three CDC devices on one cable**, not two: the CH343's, plus our firmware's
  `runtt-mgmt` and `runtt-log`. Our udev rules key on interface **string
  descriptors** rather than interface numbers, so this exercises that matching
  harder than a clean board would.
- The hub is entirely on the host side of the connector. The S3's USB device stack
  never sees it, so there is **no firmware implication**.

---

### 2. Adafruit RP2040 CAN Bus Feather, MCP2515 — £19.20

CAN controller **and** transceiver both onboard, on RP2040. No wiring, no
breadboard, no external transceiver — a complete CAN node out of the box.

**The part is actually an MCP25625**, not a bare MCP2515: same die with an
integrated transceiver. It is register-compatible, and the upstream board dts
drives it with `compatible = "microchip,mcp2515"`, so Zephyr's MCP2515 driver is
the right one. Worth knowing before someone greps the schematic for "MCP2515" and
concludes the board is wrong.

**Zephyr ships a first-class board for it: `feather_canbus_rp2040`.** The CAN side
needs *nothing* from us:

```dts
zephyr,canbus = &mcp2515;                  /* chosen node, already set */
mcp2515: mcp2515@0 {
    compatible = "microchip,mcp2515";
    spi-max-frequency = <1000000>;
    osc-freq = <16000000>;
    status = "okay";                       /* already enabled */
};
```

That is less work than the ESP32-S3, which still needs its TWAI node enabled. And
it is **RP2040 — silicon we have already brought up end to end**, so the USB
contract and MCUboot swap/confirm are proven on this exact core. CAN would be the
only new variable, which is worth real money after the Pico wedge cost us five
wrong hypotheses.

**What we have to write: the MCUboot variant.** This is the one real gap. The board
dts has a single `code_partition` spanning all 8 MB — no `boot_partition`, no
slot0/slot1, no scratch. Compare `rpi_pico`, which ships a dedicated
`rpi_pico_rp2040_mcuboot` variant. Ours would mirror it; the upstream one is nine
lines:

```dts
#include "rpi_pico.dts"
/delete-node/ &code_partition;
#include <raspberrypi/partitions_2M_sysbuild.dtsi>
/ { chosen { zephyr,code-partition = &slot0_partition; }; };
```

One wrinkle: upstream ships RP2040 tables for **2M and 4M only**, and this board has
8 M. Either use `partitions_4M_sysbuild.dtsi` and waste half, or write an 8 M table
(~30 lines, mechanical). Whichever we pick, the `second_stage_bootloader` partition
at `0x0` size `0x100` is the RP2040 boot2 handling and must carry over unchanged.

**Spec note:** MCP2515 is CAN 2.0B only — **no CAN-FD**. Irrelevant for
SMP-over-ISO-TP, but it caps this board if CAN-FD ever matters.

---

### 3. Raspberry Pi Pico 2 W (RP2350) — later USB bring-up

Not for CAN — RP2350 has no CAN controller either. Bought for USB bring-up on a
Cortex-M33, and it is well supported upstream, wireless variant included:

```
rpi_pico2_rp2350a_m33_w_mcuboot.dts     ← board target: rpi_pico2/rp2350a/m33/w/mcuboot
```

Two things are *better* here than on RP2040, both relevant to old plan risks:

- **No `second_stage_bootloader` partition.** The table these targets use,
  `partitions_4M_sysbuild.dtsi`, starts `boot_partition` at `0x0` — the RP2350
  bootrom handles what boot2 did on RP2040, where the 2 M table reserves `0x0`
  size `0x100` for it. Only the two `rpi_pico2` MCUboot targets include this file,
  so it is the RP2350 layout in practice. One less thing to get wrong.
- **64 K boot slot on an M33**, versus RP2040's 0xfe00 (~63.5 K) on an M0+. The
  original plan flagged "MCUboot must fit 63.5 K on M0+ — tight, prefer Ed25519 +
  tinycrypt". More space and a denser instruction set both ease that.

This supersedes the plan's "do **not** buy a Pico 2" line, which was written when
the roadmap had no third USB target and RP2350 support was newer.

---

## Bus wiring, once two CAN nodes exist

A CAN bus needs **exactly two 120 Ω terminators, one at each end** — not one, not
three. Sources of termination in this collection:

- The Waveshare SN65HVD230 board: some revisions have a fitted resistor, some a
  jumper. **Check yours rather than assuming.**
- The Adafruit CAN Feather: **terminated by default**. The 120 Ω sits between H
  and L and is removed by *cutting* the `Term` jumper — a subtractive change, not
  an additive one, so it is terminated until you act.
- The BTT U2C v2.1 host adapter: terminated.

With the U2C at one end, exactly one device board should be terminated and the
others not.

---

## Open questions to measure, not assume

Each of these is a guess until a number exists. Recording them here so they get
measured rather than asserted.

| Question | Why it matters |
|---|---|
| Does a larger MCUboot slot cost swap time for a small image? | Decides whether to take the 16 M partition tables or a smaller one. Depends on swap mode; we pin `SWAP_USING_OFFSET`. |
| Firmware upload rate over ISO-TP at 500 kbit/s | Sets whether CAN is viable for delivery or only for control. MCP2515's 1 MHz SPI link is ~125 KB/s, above the CAN line rate, so CAN should dominate — unverified. |
| Actual USB port path behind the CH334 hub | The annotation string we document for the ESP32-S3 board. |
| Whether the raw-frame log channel keeps up on a real 500 kbit/s bus | It works on `vcan0`, which has no bit rate. Frames are dropped rather than queued when the controller is busy, so the drop rate under real timing is unknown. |
| Does `CAN_ESP32_TWAI` work on S3 in practice? | Driver and DT exist; nobody upstream reports a Zephyr SMP-over-CAN run on it. |

---

## Reproducing the Zephyr claims

Every upstream claim above came from the pinned tree, not from vendor docs:

```bash
# TWAI pinctrl written for the S3 devkitc
grep -n "twai" -A6 zephyr/boards/espressif/esp32s3_devkitc/esp32s3_devkitc-pinctrl.dtsi

# the CAN Feather board, and its lack of MCUboot slots
ls   zephyr/boards/adafruit/feather_canbus_rp2040/
grep -nE "boot_partition|slot0_partition|code-partition" \
     zephyr/boards/adafruit/feather_canbus_rp2040/adafruit_feather_canbus_rp2040.dts

# Pico 2 W MCUboot variant
ls   zephyr/boards/raspberrypi/rpi_pico2/ | grep w_mcuboot

# no USB device controller on classic ESP32 (why the TinyPICO was rejected)
grep -cE "usb_otg|usb_serial" zephyr/dts/xtensa/espressif/esp32/esp32_common.dtsi   # 0
grep -cE "usb_otg|usb_serial" zephyr/dts/xtensa/espressif/esp32s3/esp32s3_common.dtsi # 2
```

## Boards considered and rejected

| Board | Why not |
|---|---|
| TinyPICO (ESP32-PICO-D4) | Classic ESP32: no USB device controller, so it can never present the dual-CDC contract. Has TWAI, so usable as a CAN-only node — but the S3 does that *and* the USB milestone. |
| BLYNK_v1.3 (ESP32-WROVER-B + SIM800L) | Same classic-ESP32 USB limit, plus an undocumented clone layout and a SIM800L modem drawing ~2 A bursts on unknown pins. Debugging CAN next to that is the kind of confounder that already cost us days. |
| Espressif ESP32-S3-DevKitC-1 (£28.90) | Same silicon as the Waveshare board at ~3× the price; module variant not even stated on the listing. |
| Voron SB2040 v1 (RP2040 + SN65HVD230) | The can2040 PIO software controller it relies on has no Zephyr equivalent. |
| Pico + SN65HVD230 alone | SN65HVD230 is a *transceiver* — physical layer only. No controller, so nothing for Zephyr to drive. |

---

*Co-authored with Claude*
