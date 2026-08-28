#!/usr/bin/env python3
"""Build a single provisioning image: MCUboot plus a confirmed app in slot 0.

One physical act, over BOOTSEL, needing no probe. Everything after it is remote.

Two details this exists to get right:

* The app's own `zephyr.uf2` is emitted with a target address of 0x00020000,
  which is neither the XIP window nor slot0's offset. Flashing it directly
  writes nowhere useful. The HEX extents are correct, so we work from those.

* An image flashed straight into the PRIMARY slot is the running image, not a
  candidate awaiting a test, so it needs a padded trailer marked **confirmed**.
  Sysbuild does not emit that variant here, so we produce it with imgtool and
  place just the trailer at the end of the slot -- writing 800 KB of 0xff
  padding would work but makes a needlessly large image and a slow flash.
"""
import argparse
import pathlib
import subprocess
import sys
import tempfile

SLOT0_ADDR = 0x10010000
SLOT0_SIZE = 0xD0000
TRAILER_LEN = 64


def run(cmd, **kw):
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, **kw)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--build-dir", default="build-pico-mcuboot")
    ap.add_argument("--zephyr-base", default="zephyr")
    ap.add_argument("--mcuboot", default="bootloader/mcuboot")
    ap.add_argument("--key", default="bootloader/mcuboot/root-rsa-2048.pem")
    ap.add_argument("--objcopy", required=True)
    ap.add_argument("-o", "--output", default=None)
    args = ap.parse_args()

    build = pathlib.Path(args.build_dir)
    zbase = pathlib.Path(args.zephyr_base)
    app_bin = build / "app/zephyr/zephyr.bin"
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

        body, trailer = td / "body.bin", td / "trailer.bin"
        body.write_bytes(data[:body_end])
        trailer.write_bytes(data[-TRAILER_LEN:])

        body_hex, trailer_hex, merged = td / "body.hex", td / "trailer.hex", td / "merged.hex"
        run([args.objcopy, "-I", "binary", "-O", "ihex",
             "--change-addresses", hex(SLOT0_ADDR), str(body), str(body_hex)])
        run([args.objcopy, "-I", "binary", "-O", "ihex",
             "--change-addresses", hex(SLOT0_ADDR + SLOT0_SIZE - TRAILER_LEN),
             str(trailer), str(trailer_hex)])
        run([sys.executable, str(zbase / "scripts/build/mergehex.py"), "-o", str(merged),
             str(boot_hex), str(body_hex), str(trailer_hex)])
        run([sys.executable, str(zbase / "scripts/build/uf2conv.py"), "-c", "-f", "RP2040",
             "-o", str(out), str(merged)])

    print(f"  provisioning image: {out} ({out.stat().st_size} bytes)")
    print(f"    boot2 + MCUboot   {0x10000000:#010x}")
    print(f"    app in slot 0     {SLOT0_ADDR:#010x}  ({body_end} bytes)")
    print(f"    confirmed trailer {SLOT0_ADDR + SLOT0_SIZE - TRAILER_LEN:#010x}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
