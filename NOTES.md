# Development notes

**For agents and maintainers, not for users.** Investigations, bring-up records
and hardware notes: how the current board support was arrived at. Nothing here is
needed to *use* this repository — for that, see the README,
[`docs/PROVISIONING.md`](docs/PROVISIONING.md) and
[`docs/PORTING.md`](docs/PORTING.md).

Content is verbatim from the documents it was gathered from; original paths are
noted per section so `git log --follow` still reaches their history.


---

# The MCUboot swap failure on RP2040, and the patch that came out of it

> Was `docs/MCUBOOT_SWAP_BUG.md`.

Draft of an upstream report, with a fix carried as a patch in
`patches/`.

**Scope, stated plainly.** `find_last_idx()` is genuinely unbounded and MCUboot
was observed spinning in it on hardware. But it was **not** the cause of the
deploy failure that led us here -- that turned out to be a malformed test image
of our own making (see [`HARDWARE_GATE.md`](https://github.com/shaunmulligan/runtt/blob/main/NOTES.md)), and **MCUboot swap on RP2040
works correctly with a well-formed image**, verified end to end.

So this is a robustness report, not a "MCUboot is broken" report: a bootloader
should not hang unrecoverably on a corrupt or erased trailer, whatever put it in
that state. Frame it that way upstream, because the stronger claim is not true
and a maintainer will find that out.

### Summary

`find_last_idx()` in `boot/bootutil/src/swap_offset.c` is an unbounded loop with
no guard on its inputs. When `swap_size` is `0xFFFFFFFF` — the value read from
erased flash — the loop cannot terminate, and MCUboot spins forever instead of
booting. The device never boots the primary image, never performs the swap, and
never times out. On a board whose only management path is the application's own
SMP server, that is unrecoverable without physical intervention.

```c
uint32_t find_last_idx(struct boot_loader_state *state, uint32_t swap_size)
{
    uint32_t sector_sz;
    uint32_t sz;
    uint32_t last_idx;

    sector_sz = boot_img_sector_size(state, BOOT_SLOT_PRIMARY, 0);
    sz = 0;
    last_idx = 0;

    while (1) {
        sz += sector_sz;
        if (sz >= swap_size) {
            break;
        }
        last_idx++;
    }

    return last_idx;
}
```

Two ways this fails to terminate:

* **`swap_size == 0xFFFFFFFF`.** With a 4096-byte sector, `sz` climbs to
  `0xFFFFF000`; the next addition overflows to `0`, and `sz >= swap_size` is
  never satisfied. The loop runs forever, wrapping indefinitely.
* **`sector_sz == 0`.** `sz` never advances, so unless `swap_size` is 0 the loop
  never exits. No caller checks this.

### Environment

| | |
|---|---|
| Zephyr | v4.4.2 (`dccb0959`) |
| Zephyr SDK | 1.0.1 |
| Board | `rpi_pico/rp2040/mcuboot` |
| Swap mode | `CONFIG_BOOT_SWAP_USING_OFFSET=y` (pinned, via sysbuild) |
| `CONFIG_MCUBOOT_BOOT_MAX_ALIGN` | 1 |
| Slots | slot0 `0x10010000`+`0xd0000`, slot1 `0x100e0000`+`0xd0000` |
| Signing | RSA-2048, MCUboot's development key |

### Reproduction

1. Provision the board: MCUboot plus a confirmed application in slot 0.
2. Upload an image to slot 1 over MCUmgr and mark it for test
   (`img_mgmt` `set_state`, confirm=false). Read back confirms `pending=true`.
3. Reset.

Observed: the device never comes back. It does not re-enumerate, does not boot
the primary image, and does not perform the swap. A bare `os reset` with **no**
staged image reboots correctly every time, so the reset path itself is sound.

### Evidence

Read over SWD with a Raspberry Pi Debug Probe and pyOCD, on a board left in the
failed state.

**MCUboot is running, and it is looping.** Four PC samples taken a second apart
all land in the same three-instruction window:

```
pc=0x10005ef4   find_last_idx  swap_offset.c:71
pc=0x10005ef8   find_last_idx  swap_offset.c:74
pc=0x10005ef4   find_last_idx  swap_offset.c:71
pc=0x10005efc   find_last_idx  swap_offset.c:70
```

`VTOR = 0x10000100` — MCUboot's own vector table — so the reset happened and the
bootloader is what is executing. The core reports `Running`, not halted or
faulted.

**The input is erased flash.** The trailer words in the primary slot read
`0xffffffff`.

**A second failure mode.** On some runs the core ends in `Lockup` instead:
`xpsr` exception 3 (HardFault) with `SP = 0xffffffe0`, i.e. SP was zero when the
fault was taken — the signature of chain-loading an image whose vector table is
blank. Whether this is a distinct path or the same one at a different point is
not yet established.

**Not specific to one build.** The same failure reproduces on firmware built
from an earlier commit of this project that had recorded a working deploy cycle
on the same board, so it is not a regression in application configuration.

### Second defect: the swapped image lands 0x200 bytes too far in

Found after the `find_last_idx` fix let the bootloader get far enough to
actually perform the swap. This is the one that produces the lockup.

Read over SWD at a `reset halt`, so XIP is up and the reads are trustworthy:

```
slot 1 (source)              slot 0 (destination, after the failed swap)
0x100e0000: 96f3b83d hdr     0x10010000: 96f3b83d   header magic ok
                             0x100101f0: ffffffff   header NOT fully written
0x100e0200: 20003890 <-- SP  0x10010200: 00000000   512 bytes of programmed zeros
0x100e0204: 10012141 <-- PC  0x10010300: 00000000
                             0x10010400: 20003890   <-- the image starts HERE
                             0x10010404: 10012141
```

`slot0 + 0x400` matches `slot1 + 0x200` word for word. The image was copied, but
written **0x200 bytes too far in — exactly one image-header length.**

The consequence is the lockup. MCUboot chain-loads the primary at
`slot_start + hdr_size` (`0x10010200`), which now holds zeros. It loads `SP = 0`
and `PC = 0` from that blank vector table, faults immediately, and cannot service
the fault, so the core ends in Cortex-M lockup. Every register matches:
`SP = 0xffffffe0` (zero, less a 32-byte exception frame), `xpsr` exception 3
(HardFault), `pc = 0xfffffffe`.

Note the zeros are *programmed*, not erased — erased NOR reads `0xFF` — so
something deliberately wrote 512 bytes of zeros into the gap it left.

**A measurement warning for anyone reproducing this.** Flash reads taken while
the core is locked up, or while it sits inside a bootrom flash routine, are not
trustworthy: those routines run with XIP disabled, and reads through the XIP
window then return garbage. The same address read `0x00000000` and `0x00070000`
on consecutive samples during the swap. Take every flash reading at a
`reset halt`, and sanity-check that boot2 at `0x10000000` reads plausibly before
believing anything else.

### The fix, and what it does and does not resolve

`patches/mcuboot/0001-bound-find_last_idx-loops.patch` guards both
copies of the function: it returns early on a zero sector size and bounds the
walk by the primary slot's own sector count, so the loop terminates for any
input and can never return an index beyond a real sector.

**Verified:**

* MCUboot's own simulator passes 25/25 with the patch, under **both**
  `swap-offset` and `swap-move`. No regression.
* On hardware the behaviour demonstrably changes. Without the patch the
  bootloader spins in `find_last_idx` (4 of 4 PC samples inside a
  three-instruction window). With it, it no longer spins there.

**Not resolved:** the deploy still fails. With the patch applied the bootloader
gets past this function and then ends in `Lockup` instead, with slot 0's vector
table reading zeros. So the unbounded loop is a genuine defect worth fixing on
its own terms, but something further along the swap path is also wrong, and that
is still open.

An earlier version of this patch only guarded the arithmetic overflow. That was
worse than useless: with `swap_size = 0xFFFFFFFF` it let `last_idx` climb to
about a million before breaking, returning a nonsense sector index for callers
to use. Bounding by the sector count is the part that makes the result safe, not
just terminating.

### Suggested fix

Guard the loop rather than trusting the trailer:

```c
if (sector_sz == 0U || swap_size == 0U || swap_size == UINT32_MAX) {
    return 0;  /* or propagate an error to the caller */
}
```

and bound the iteration by the sector count of the primary slot, so a corrupt or
erased trailer can never produce an unterminated loop. A bootloader that hangs on
bad input is strictly worse than one that declines to swap and boots the primary
image, because the hang removes every remaining path to recovery.

### What is confirmed, and what is not

**Confirmed:** the loop is unbounded as written; MCUboot is demonstrably
executing inside it (4 of 4 samples); the reset occurs and the bootloader runs;
the trailer region reads `0xFFFFFFFF`; a bare reset with nothing staged is fine.

**Not confirmed:** that `swap_size` specifically holds `0xFFFFFFFF` at the call
— the trailer field offsets depend on `BOOT_MAX_ALIGN` and were misread twice
during this investigation, so the exact field has not been proven, only the
region. Also unproven: the relationship between the hang and the `Lockup`
variant, and whether `sector_sz` is 0 here rather than `swap_size` being
invalid. Either input reproduces the hang, and the fix should cover both.

### On reproducing it in the simulator

Attempted, and worth recording as a negative result: the simulator's existing
25 scenarios **pass** under `swap-offset`, so they never feed `find_last_idx` a
corrupt trailer. The bad input comes from real-world flash state its model does
not produce.

A proper regression test would therefore need to inject an erased or corrupted
`swap_size` into the trailer and assert the bootloader terminates. That is the
right thing to offer upstream alongside the patch, and it is not yet written.
The defect itself does not depend on it — the loop is unbounded by inspection —
but a deterministic test is what makes a report easy for a maintainer to accept.

### Filing checklist

* [x] Fix written and carried as a patch, both swap modes
* [x] Simulator green with the fix (25/25, `swap-offset` and `swap-move`)
* [x] Behaviour change confirmed on hardware
* [ ] Regression test injecting a corrupt trailer
* [ ] Confirm which input is bad (`swap_size` vs `sector_sz`) — see caveats above
* [ ] File upstream, then add the URL to `patches.yml` as `issue:`



---

# Hardware targets: what each board needed, and what is on order

> Was `docs/HARDWARE_TARGETS.md`.

A register of the boards this project runs on: what each one proves, what Zephyr
gives us upstream, and what we have to write ourselves. Prices and stock are from
The Pi Hut as of **2026-08-30** and will age; the Zephyr claims are checked against
the pinned **v4.4.2** tree in this repo and are reproducible with the commands
shown.

Related: [ROADMAP.md](https://github.com/shaunmulligan/runtt/blob/main/NOTES.md) for why these targets, [HARDWARE_GATE.md](https://github.com/shaunmulligan/runtt/blob/main/NOTES.md)
for the CI story, [WIRE_CONTRACT.md](https://github.com/shaunmulligan/runtt/blob/main/docs/WIRE_CONTRACT.md) for what a board must present.

---

### On the bench today

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

### On order

| Board | Price | Buys us | Status |
|---|---|---|---|
| Waveshare ESP32-S3-DEV-KIT-N16R8 | £10.60 | ESP32 milestone **and** CAN via TWAI | still on order |
| Adafruit RP2040 CAN Bus Feather (MCP2515) | £19.20 | CAN on silicon we already know | **arrived, supported, 2026-09-04** — see below |

Two boards with **different CAN controllers** is deliberate. MCP2515 (SPI,
standalone) and TWAI (on-die, SJA1000-compatible) exercise completely different
Zephyr drivers under the same `isotp` API. If our transport works on both, it is
controller-agnostic in fact and not just in intent. Two of the same controller
would not prove that. CAN is also a bus — the robotics demo wants ≥2 nodes anyway.

---

#### 1. Waveshare ESP32-S3-DEV-KIT-N16R8 — £10.60

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

#### 2. Adafruit RP2040 CAN Bus Feather, MCP2515 — £19.20 — DONE

**Arrived and promoted to supported, 2026-09-04.** All six PORTING checks pass,
with deploy, logs and revert proven over BOTH transports; the physical-bus half
ran against a BTT U2C (gs_usb) at 500 kbit/s. Ships in releases from v0.3.0.
The notes below are kept as the record of what the bring-up needed. Three things
it added beyond them: this repo became a Zephyr BOARD_ROOT (the mcuboot variant
is not upstream), the module gained ISOTP receive-pool configdefaults (Zephyr's
224-byte default cannot hold an SMP chunk), and uf2_merge learned that the
RP2040 bootrom silently discards non-256-byte UF2 blocks while still counting
them -- the identity record now pads.


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

#### 3. Raspberry Pi Pico 2 W (RP2350) — DONE, and it is now a supported board

**Arrived and brought up 2026-09-02.** All six checks in
[PORTING.md](PORTING.md) pass on hardware and it ships provisioning images from
v0.2.0 onward, so it is in `boards.yml` as `supported` rather than on this page's
shopping list. Kept here for the SoC notes below, which are what the bring-up
actually needed.

The headline result: it needed **no new snippet files at all**. The module's
`/rpi_pico.*/` key already matches, and the RP2040 conf and overlay are correct
for RP2350 — same `raspberrypi,pico-usbd` driver, same `zephyr_udc0` label, also
16 bidirectional endpoints. Slot offsets are identical too, so the provisioning
image builder needed no new constants. That is the strongest evidence so far
that the contract is not Pico-shaped.

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

### Bus wiring, once two CAN nodes exist

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

### Open questions to measure, not assume

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

### Reproducing the Zephyr claims

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

### Boards considered and rejected

| Board | Why not |
|---|---|
| TinyPICO (ESP32-PICO-D4) | Classic ESP32: no USB device controller, so it can never present the dual-CDC contract. Has TWAI, so usable as a CAN-only node — but the S3 does that *and* the USB milestone. |
| BLYNK_v1.3 (ESP32-WROVER-B + SIM800L) | Same classic-ESP32 USB limit, plus an undocumented clone layout and a SIM800L modem drawing ~2 A bursts on unknown pins. Debugging CAN next to that is the kind of confounder that already cost us days. |
| Espressif ESP32-S3-DevKitC-1 (£28.90) | Same silicon as the Waveshare board at ~3× the price; module variant not even stated on the listing. |
| Voron SB2040 v1 (RP2040 + SN65HVD230) | The can2040 PIO software controller it relies on has no Zephyr equivalent. |
| Pico + SN65HVD230 alone | SN65HVD230 is a *transceiver* — physical layer only. No controller, so nothing for Zephyr to drive. |



---

## ESP32-S3 bring-up, stages 1-3 (2026-09-05)

Stages 1-2 were an afternoon, as predicted. Stage 3 (MCUboot) proved the big
machinery and found one real defect, still open.

**Proven on this SoC, third architecture (Xtensa):**

* Swap mode: `SWAP_SCRATCH`, pinned per-board via `bringup/sysbuild-esp32s3.conf`
  passed as `-DSB_EXTRA_CONF_FILE` so it overrides the common OFFSET pin.
  Upstream carves ESP32 out of offset-preference and ships a scratch partition
  in its own table; both halves of the build verified to agree.
* MCUboot swaps, and **the confirm deadline + revert work unaided**: a deploy
  whose new image could not be reached was reverted by the deadline's reboot --
  MCUboot's own console (enabled on UART0 by
  `bringup/esp32s3-mcuboot-console.conf`) shows `Swap type: test` on the deploy
  boot and `Swap type: revert` 60 s later. The §6 safety property now holds on
  RP2350, nRF52840 and ESP32-S3.
* The **runtime-side single-channel demux**: a full 140 KB upload over the
  shared USB-Serial/JTAG link, with clean demultiplexed application logs in
  container stdio. First hardware target for `RUNTT_CHANNELS=1`.

**The warm-reset RX defect: found, fixed, carried as a patch (2026-09-05).**
The USB-Serial-JTAG's `SERIAL_OUT_RECV_PKT` interrupt is raised per received
packet, not while data is available. Bytes already in the RX FIFO when the
interrupt is enabled raise nothing -- and while the FIFO holds data the
controller NAKs the host, so no packet can ever arrive to raise it. A software
reset while the host streams (which is what `os reset` after an upload IS)
guarantees a non-empty FIFO at the next boot's irq_rx_enable, because the
controller and its FIFOs deliberately survive warm resets. Zephyr's driver
already handles the mirror-image TX case (`irq_tx_enable` delivers the callback
by hand when TX-ready is already true); the fix gives RX the same treatment.
`patches/zephyr/0001-serial_esp32_usb-*.patch`, upstreamable, verified by the
previously-failing deploy completing end to end: upload, warm reset, reconnect,
confirm, resident. Matches the known issue class in arduino-esp32#9316.

Found by enabling MCUboot's console and reading the trailer across boots rather
than guessing: the swap had been working all along (it logs nothing at INF), and
the deadline's revert of the unreachable image was the safety net doing its job
on a third architecture -- the "failure" everyone chased for an hour was the
platform working as designed around a one-line driver gap.

CI also gained `west patch apply` in workspace assembly: it had never applied
patches.yml, which was harmless while the only patch was defensive hardening and
becomes load-bearing the day a board cannot deploy without its patch.

**Four bench gotchas worth not rediscovering:**

* MCUboot's scratch swap logs NOTHING at INF between "Swap type: X" and
  "Jumping" -- a completed swap and a skipped one read identically. The trailer
  state on the NEXT boot is the evidence (`image_ok=0x3` after a swap the
  previous line claimed was "test" proves the swap ran).
* The chip parks in the ROM downloader if esptool's closing hard-reset does not
  take: ROM USB device enumerated, no console, no SMP. `esptool run` recovers
  it. Looks exactly like a bricked board and is not.
* The USB-Serial/JTAG re-enumerates on hard reset (stale fds for any holder)
  but NOT on soft reset. The CH343 UART bridge survives everything, which is
  why the MCUboot witness console lives there.
* **Holding the CH343 witness open asserts DTR, and DTR is wired to EN: the
  ESP32 is held in reset for as long as anything reads that port.** This is the
  nastiest of the four, because the witness is exactly what you reach for when a
  board will not come up, and every symptom it produces points somewhere else.
  It cost an hour: the dual-CDC composite appeared not to enumerate, the ROM USB
  device was missing (read as "the app took the PHY"), the witness stayed silent
  through repeated RESET presses, and every esptool reset landed in
  `boot:0x0 (DOWNLOAD)`. All of it was one `cat` holding DTR low. Closing the
  reader made the board boot and enumerate immediately.

  RTS is NOT wired -- pulsing it does nothing, which is what wrongly cleared the
  reader from suspicion the first time. Test both lines before absolving your
  instrumentation.

  Read it with both lines deasserted before and after open:

  ```python
  s = serial.Serial()
  s.port = '/dev/ttyACM1'; s.baudrate = 115200; s.timeout = 0.2
  s.dtr = False; s.rts = False
  s.open()
  s.dtr = False; s.rts = False      # again: opening can re-assert
  ```

  Verified: with that reader attached the board stays enumerated and the witness
  still captures MCUboot live during a deploy.

---

*Co-authored with Claude*
