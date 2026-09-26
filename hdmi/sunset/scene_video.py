#!/usr/bin/env python3
"""Render the scene animation to an MP4 or a GIF using the reference model in scene_gen.py.

The model matches scene.v pixel for pixel (make sim checks this), so the result is exactly
what the board shows, starting from power-up (frame 0). The board runs at 60 frames per
second; --step 2 keeps every other frame (30 fps). MP4 output needs ffmpeg.

  python3 scene_video.py --seconds 30 --scale 4 --out scene.mp4
  python3 scene_video.py --seconds 12 --scale 2 --step 2 --out scene.gif
"""
import argparse
import multiprocessing
import subprocess

from PIL import Image

import scene_gen

_assets = None


def _init():
    global _assets
    _assets = scene_gen.make_assets()


def _frame_rgb(t):
    pal = _assets["palette"]
    return bytes(c for i in scene_gen.render(_assets, t) for c in pal[i])


def _frame_indices(t):
    return scene_gen.render(_assets, t)


def write_mp4(args, frames):
    w, h = scene_gen.LW, scene_gen.LH
    ffmpeg = subprocess.Popen(
        ["ffmpeg", "-y", "-loglevel", "error",
         "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{w}x{h}", "-r", f"{60 / args.step:g}", "-i", "-",
         "-vf", f"scale={w * args.scale}:{h * args.scale}:flags=neighbor",
         "-c:v", "libx264", "-preset", "slow", "-crf", "16", "-pix_fmt", "yuv420p",
         "-movflags", "+faststart", args.out],
        stdin=subprocess.PIPE)
    with multiprocessing.Pool(initializer=_init) as pool:
        for n, data in enumerate(pool.imap(_frame_rgb, frames, chunksize=8), 1):
            ffmpeg.stdin.write(data)
            if n % 300 == 0:
                print(f"{n}/{len(frames)} frames")
    ffmpeg.stdin.close()
    if ffmpeg.wait() != 0:
        raise SystemExit("ffmpeg failed")


def write_gif(args, frames):
    # The scene only ever uses its 64 palette colours, so every frame is exact.
    w, h = scene_gen.LW, scene_gen.LH
    flat = [c for rgb in scene_gen.build_palette() for c in rgb]
    images = []
    with multiprocessing.Pool(initializer=_init) as pool:
        for n, idx in enumerate(pool.imap(_frame_indices, frames, chunksize=8), 1):
            img = Image.new("P", (w, h))
            img.putpalette(flat)
            img.putdata(idx)
            images.append(img.resize((w * args.scale, h * args.scale), Image.NEAREST))
            if n % 100 == 0:
                print(f"{n}/{len(frames)} frames")
    ms = 1000 * args.step / 60
    durations = [round(ms * (i + 1)) - round(ms * i) for i in range(len(images))]   # keeps real time
    images[0].save(args.out, save_all=True, append_images=images[1:], duration=durations, loop=0,
                   optimize=False, disposal=1)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seconds", type=float, default=30)
    ap.add_argument("--start", type=int, default=0, help="first frame")
    ap.add_argument("--step", type=int, default=1, help="keep every n-th frame (2 gives 30 fps)")
    ap.add_argument("--scale", type=int, default=4, help="pixel size in the output (the board uses 2)")
    ap.add_argument("--out", default="scene.mp4")
    args = ap.parse_args()

    frames = range(args.start, args.start + round(args.seconds * 60), args.step)
    if args.out.endswith(".gif"):
        write_gif(args, frames)
    else:
        write_mp4(args, frames)
    w, h = scene_gen.LW, scene_gen.LH
    print(f"wrote {args.out}: {len(frames)} frames, {w * args.scale}x{h * args.scale}")


if __name__ == "__main__":
    main()
