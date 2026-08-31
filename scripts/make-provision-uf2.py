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
    ap.add_argument("--build-dir", default="build-pico-idle")
    ap.add_argument("--image", default=None,
                    help="sysbuild image name (defaults to the sole non-mcuboot image)")
    ap.add_argument("--zephyr-base", default="zephyr")
    ap.add_argument("--mcuboot", default="bootloader/mcuboot")
    ap.add_argument("--key", default="bootloader/mcuboot/root-rsa-2048.pem")
    ap.add_argument("--objcopy", required=True)
    ap.add_argument("-o", "--output", default=None)
    args = ap.parse_args()

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
        run([sys.executable, str(zbase / "scripts/build/uf2conv.py"), "-c", "-f", "RP2040",
             "-b", hex(FLASH_BASE), "-o", str(out), str(flat_bin)])

    print(f"  provisioning image: {out} ({out.stat().st_size} bytes)")
    print(f"    payload: {image}")
    print(f"    one contiguous region {FLASH_BASE:#010x} .. "
          f"{SLOT0_ADDR + SLOT0_SIZE:#010x}")
    print(f"    boot2 + MCUboot, app in slot 0 ({body_end} bytes), confirmed trailer")
    return 0


if __name__ == "__main__":
    sys.exit(main())
