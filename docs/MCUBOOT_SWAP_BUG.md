# MCUboot hangs in `find_last_idx()` — swap-using-offset, RP2040

Draft of an upstream report. **Reproduced on hardware; not yet reproduced in
MCUboot's simulator**, which is the next step and the form the report should
take before filing.

## Summary

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

## Environment

| | |
|---|---|
| Zephyr | v4.4.2 (`dccb0959`) |
| Zephyr SDK | 1.0.1 |
| Board | `rpi_pico/rp2040/mcuboot` |
| Swap mode | `CONFIG_BOOT_SWAP_USING_OFFSET=y` (pinned, via sysbuild) |
| `CONFIG_MCUBOOT_BOOT_MAX_ALIGN` | 1 |
| Slots | slot0 `0x10010000`+`0xd0000`, slot1 `0x100e0000`+`0xd0000` |
| Signing | RSA-2048, MCUboot's development key |

## Reproduction

1. Provision the board: MCUboot plus a confirmed application in slot 0.
2. Upload an image to slot 1 over MCUmgr and mark it for test
   (`img_mgmt` `set_state`, confirm=false). Read back confirms `pending=true`.
3. Reset.

Observed: the device never comes back. It does not re-enumerate, does not boot
the primary image, and does not perform the swap. A bare `os reset` with **no**
staged image reboots correctly every time, so the reset path itself is sound.

## Evidence

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

## Suggested fix

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

## What is confirmed, and what is not

**Confirmed:** the loop is unbounded as written; MCUboot is demonstrably
executing inside it (4 of 4 samples); the reset occurs and the bootloader runs;
the trailer region reads `0xFFFFFFFF`; a bare reset with nothing staged is fine.

**Not confirmed:** that `swap_size` specifically holds `0xFFFFFFFF` at the call
— the trailer field offsets depend on `BOOT_MAX_ALIGN` and were misread twice
during this investigation, so the exact field has not been proven, only the
region. Also unproven: the relationship between the hang and the `Lockup`
variant, and whether `sector_sz` is 0 here rather than `swap_size` being
invalid. Either input reproduces the hang, and the fix should cover both.

## Next step before filing

Reproduce in [`mcuboot/sim/`](https://github.com/mcu-tools/mcuboot/tree/main/sim).
It compiles the real `bootutil` sources over a NOR-flash model with injectable
failures, and this project's CI already builds and runs it. A test that stages an
image with a corrupted or erased trailer and asserts the bootloader terminates
would turn this from a hardware anecdote into a deterministic upstream test case
— which is worth far more to the maintainers, and would confirm which of the two
inputs is at fault.

---

*Co-authored with Claude*
