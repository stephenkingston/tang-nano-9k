#!/usr/bin/env python3
"""Convert a 640x480 frame dump (one rrggbb hex value per line) to a PNG.

  python3 frame2png.py pong_frame.hex pong_frame.png
"""
import sys

from PIL import Image


def main():
    src, dst = sys.argv[1], sys.argv[2]
    with open(src) as f:
        px = [int(line, 16) for line in f if line.strip()]
    if len(px) != 640 * 480:
        raise SystemExit(f"{src}: {len(px)} pixels, expected {640 * 480}")
    img = Image.new("RGB", (640, 480))
    img.putdata([((v >> 16) & 255, (v >> 8) & 255, v & 255) for v in px])
    img.save(dst)
    print(f"wrote {dst}")


if __name__ == "__main__":
    main()
