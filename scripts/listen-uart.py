#!/usr/bin/env python3
"""Listen on a serial device and print what arrives, with a timeout.

For reading a target's console through the Debug Probe's UART bridge, which is
how you find out what a bootloader is doing when it has no USB of its own.

    ./scripts/listen-uart.py /dev/runtt/probe-uart --seconds 20
"""
import argparse
import sys
import termios
import time
import tty


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("device")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--seconds", type=float, default=15)
    args = ap.parse_args()

    try:
        fd = __import__("os").open(args.device, __import__("os").O_RDONLY | __import__("os").O_NONBLOCK)
    except OSError as e:
        print(f"cannot open {args.device}: {e}", file=sys.stderr)
        return 1

    # Raw mode at the requested baud: we want bytes, not line discipline.
    attrs = termios.tcgetattr(fd)
    tty.setraw(fd)
    speed = getattr(termios, f"B{args.baud}")
    attrs[4] = attrs[5] = speed
    termios.tcsetattr(fd, termios.TCSANOW, attrs)

    os = __import__("os")
    deadline = time.time() + args.seconds
    seen = bytearray()
    while time.time() < deadline:
        try:
            chunk = os.read(fd, 4096)
            if chunk:
                seen.extend(chunk)
                sys.stdout.write(chunk.decode("utf-8", "replace"))
                sys.stdout.flush()
        except BlockingIOError:
            time.sleep(0.05)
        except OSError:
            break
    os.close(fd)

    if not seen:
        print(f"\n(nothing received in {args.seconds:g}s)", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
