#!/usr/bin/env python3
"""Render the scene animation to an MP4 using the reference model in scene_gen.py.

The model matches scene.v pixel for pixel (make sim-scene checks this), so the video
is exactly what the board shows, starting from power-up (frame 0) at 60 frames per second.
Needs ffmpeg.

  python3 scene_video.py --seconds 30 --scale 4 --out scene.mp4
"""
import argparse
import multiprocessing
import subprocess

import scene_gen

_assets = None


def _init():
    global _assets
    _assets = scene_gen.make_assets()


def _frame(t):
    pal = _assets["palette"]
    return bytes(c for i in scene_gen.render(_assets, t) for c in pal[i])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seconds", type=float, default=30)
    ap.add_argument("--start", type=int, default=0, help="first frame")
    ap.add_argument("--scale", type=int, default=4, help="pixel size in the video (the board uses 2)")
    ap.add_argument("--out", default="scene.mp4")
    args = ap.parse_args()

    frames = range(args.start, args.start + round(args.seconds * 60))
    w, h = scene_gen.LW, scene_gen.LH
    ffmpeg = subprocess.Popen(
        ["ffmpeg", "-y", "-loglevel", "error",
         "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{w}x{h}", "-r", "60", "-i", "-",
         "-vf", f"scale={w * args.scale}:{h * args.scale}:flags=neighbor",
         "-c:v", "libx264", "-preset", "slow", "-crf", "16", "-pix_fmt", "yuv420p",
         "-movflags", "+faststart", args.out],
        stdin=subprocess.PIPE)

    with multiprocessing.Pool(initializer=_init) as pool:
        for n, data in enumerate(pool.imap(_frame, frames, chunksize=8), 1):
            ffmpeg.stdin.write(data)
            if n % 300 == 0:
                print(f"{n}/{len(frames)} frames")
    ffmpeg.stdin.close()
    if ffmpeg.wait() != 0:
        raise SystemExit("ffmpeg failed")
    print(f"wrote {args.out}: {len(frames)} frames, {w * args.scale}x{h * args.scale}")


if __name__ == "__main__":
    main()
