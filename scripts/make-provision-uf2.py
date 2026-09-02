#!/usr/bin/env python3
"""Build a single provisioning image: MCUboot plus a confirmed app in slot 0.

One physical act, over BOOTSEL, needing no probe. Everything after it is remote.

Two details this exists to get right:

* The app's own `zephyr.uf2` is emitted with a target address of 0x00020000,
  which is neither the XIP window nor slot0's offset. Flashing it directly
  writes nowhere useful. The HEX extents are correct, so we work from those.

* An image flashed straight into the PRIMARY slot is the running image, not a
  candidate awaiting a test, so it needs a padded trailer marked **confirmed**.
  Sysbuild does not emit that variant here, so we produce it with imgtool.

* The result is written as ONE CONTIGUOUS REGION, padding the gaps with 0xff.
  A sparse UF2 covering the same bytes in three disjoint regions is structurally
  valid -- sequential blockNo, correct numBlocks, legitimate address gaps -- and
  was accepted without complaint, but the second region did not reach flash.
  Reproduced twice on an RP2040; every single-region image we have flashed
  worked. Rather than fight the bootrom, emit one region. It costs a larger file
  and a slower flash, and it has the side benefit of leaving the slot properly
  erased.
"""
import argparse
import pathlib
import subprocess
import sys
import tempfile

FLASH_BASE = 0x10000000
SLOT0_ADDR = 0x10010000
SLOT0_SIZE = 0xD0000
TRAILER_LEN = 64


def run(cmd, **kw):
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, **kw)


def read_hex(path):
    """Minimal Intel HEX reader: {absolute address: bytes}."""
    out, base = {}, 0
    for line in open(path):
        line = line.strip()
        if not line.startswith(":"):
            continue
        n = int(line[1:3], 16)
        addr = int(line[3:7], 16)
        rec = int(line[7:9], 16)
        if rec == 4:
            base = int(line[9:13], 16) << 16
        elif rec == 0:
            out[base + addr] = bytes.fromhex(line[9:9 + 2 * n])
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    # Required, no default. It defaulted to build-pico-idle, which is one of the
    # two directories a caller might mean -- so build-pico.sh's mcuboot mode
    # silently pointed at the provisioning build instead of its own. It only
    # surfaced in CI, where mcuboot runs BEFORE provision so the directory does
    # not exist yet; locally the stale directory from an earlier run made it look
    # correct. A default that is right half the time is worse than none.
    ap.add_argument("--build-dir", required=True,
                    help="the sysbuild build directory to read images from")
    ap.add_argument("--image", default=None,
                    help="sysbuild image name (defaults to the sole non-mcuboot image)")
    ap.add_argument("--zephyr-base", default="zephyr")
    # The UF2 family id is checked by the boot ROM, and a wrong one is rejected
    # rather than misflashed -- so it is a per-SoC value, not a detail. RP2040 is
    # 0xe48bff56 and RP2350 is 0xe48bff57 in Zephyr's uf2families.json, which is
    # also what Zephyr's own `west build` emits for each board. (Raspberry Pi's
    # own scheme calls 0xe48bff57 "absolute" and reserves 0xe48bff59 for
    # "RP2350-ARM-S"; we follow what Zephyr emits for the board, because that is
    # what the board's own UF2s carry.)
    ap.add_argument("--family", default="RP2040",
                    help="uf2conv family id name, e.g. RP2040 or RP2350")
    # No usable default: MCUboot lives at the WEST WORKSPACE root, which is the
    # parent of this repository, so any path relative to the CWD is wrong as
    # often as it is right. Callers pass --mcuboot "$(west topdir)/bootloader/mcuboot".
    ap.add_argument("--mcuboot", required=True,
                    help="path to the mcuboot checkout, e.g. $(west topdir)/bootloader/mcuboot")
    ap.add_argument("--key", default=None,
                    help="signing key; defaults to <mcuboot>/root-rsa-2048.pem")
    ap.add_argument("--objcopy", required=True)
    ap.add_argument("-o", "--output", default=None)
    args = ap.parse_args()
    if args.key is None:
        args.key = str(pathlib.Path(args.mcuboot) / "root-rsa-2048.pem")

    build = pathlib.Path(args.build_dir)
    zbase = pathlib.Path(args.zephyr_base)

    # Sysbuild names the application image after its directory, so do not
    # hardcode "app" -- the provisioning payload is runtt-idle.
    image = args.image
    if image is None:
        candidates = sorted(
            d.name for d in build.iterdir()
            if d.is_dir() and d.name != "mcuboot" and (d / "zephyr/zephyr.bin").exists()
        )
        if len(candidates) != 1:
            print(f"cannot pick an image from {candidates}; pass --image", file=sys.stderr)
            return 1
        image = candidates[0]

    app_bin = build / image / "zephyr/zephyr.bin"
    boot_hex = build / "mcuboot/zephyr/zephyr.hex"
    out = pathlib.Path(args.output or (build / "provision.uf2"))

    for p in (app_bin, boot_hex):
        if not p.exists():
            print(f"missing {p}; run a sysbuild mcuboot build first", file=sys.stderr)
            return 1

    with tempfile.TemporaryDirectory() as td:
        td = pathlib.Path(td)
        confirmed = td / "app.confirmed.bin"
        run([sys.executable, str(pathlib.Path(args.mcuboot) / "scripts/imgtool.py"), "sign",
             "--key", args.key, "--header-size", "0x200", "--align", "4",
             "--version", "0.1.0", "--slot-size", hex(SLOT0_SIZE),
             "--pad", "--confirm", str(app_bin), str(confirmed)])

        data = confirmed.read_bytes()
        # Where the image body stops and the padding begins.
        run_len, body_end = 0, len(data)
        for i, b in enumerate(data):
            run_len = run_len + 1 if b == 0xFF else 0
            if run_len > 4096:
                body_end = i - run_len + 1
                break

        # Flatten everything into one image starting at the flash base: the
        # bootloader, the gap, the app, its padding, and the confirmed trailer.
        boot = read_hex(boot_hex)
        flat = bytearray(b"\xff" * (SLOT0_ADDR - FLASH_BASE + SLOT0_SIZE))
        for addr, chunk in boot.items():
            flat[addr - FLASH_BASE:addr - FLASH_BASE + len(chunk)] = chunk
        flat[SLOT0_ADDR - FLASH_BASE:SLOT0_ADDR - FLASH_BASE + len(data)] = data

        flat_bin = td / "flat.bin"
        flat_bin.write_bytes(bytes(flat))
        run([sys.executable, str(zbase / "scripts/build/uf2conv.py"), "-c",
             "-f", args.family,
             "-b", hex(FLASH_BASE), "-o", str(out), str(flat_bin)])

    print(f"  provisioning image: {out} ({out.stat().st_size} bytes)")
    print(f"    payload: {image}")
    print(f"    one contiguous region {FLASH_BASE:#010x} .. "
          f"{SLOT0_ADDR + SLOT0_SIZE:#010x}")
    # RP2040 needs a 256-byte second-stage bootloader at 0x0 and puts MCUboot at
    # 0x100; RP2350's boot ROM reads flash directly and MCUboot starts at 0x0.
    # Either way the layout comes from MCUboot's own hex rather than from here,
    # so this line only has to describe what it did.
    print(f"    MCUboot from its hex, app in slot 0 ({body_end} bytes), "
          f"confirmed trailer, family {args.family}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
