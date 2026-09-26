#!/usr/bin/env python3
"""Record a gameplay GIF of NANO QUEST from the Verilog, as the board would show it.

Compiles plat_gif_tb.v, runs one simulation job per stretch of ticks in parallel (the bot
plays from power-up in every job, so they agree), and joins the frames into a GIF at 2x size.
  python3 plat_gif.py --out ../../media/nano-quest.gif
"""
import argparse
import os
import subprocess
from concurrent.futures import ThreadPoolExecutor

from PIL import Image

# The bot fetches the first mushroom, then plays on. Parts of the run as (first tick, last
# tick), every 2nd tick becoming a frame (30 fps): title screen, world card, the walk to the
# mushroom block and the mushroom rising, the mushroom coming back and Nano growing, big Nano
# on the run, the finish at the flag, and a brick smashed in world 2.
PARTS = [(4, 63), (150, 181), (182, 421), (500, 1099), (1950, 2279), (3330, 3391)]
SEGMENTS = [(t, min(t + 59, t1)) for t0, t1 in PARTS for t in range(t0, t1 + 1, 60)]


def run_job(job, t0, t1):
    subprocess.run(["vvp", "-n", "plat_gif_tb.vvp", f"+T0={t0}", f"+T1={t1}", "+STEP=2", f"+JOB={job}", "+FETCH"],
                   check=True, stdout=subprocess.DEVNULL)
    return job


def load_frames(path):
    with open(path) as f:
        rows = [line.strip() for line in f if line.strip()]
    frames = []
    for i in range(0, len(rows), 240):
        img = Image.new("RGB", (320, 240))
        img.putdata([(int(r[j:j + 2], 16), int(r[j + 2:j + 4], 16), int(r[j + 4:j + 6], 16))
                     for r in rows[i:i + 240] for j in range(0, 1920, 6)])
        frames.append(img)
    return frames


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default="nano-quest.gif")
    ap.add_argument("--jobs", type=int, default=os.cpu_count())
    args = ap.parse_args()

    subprocess.run(["iverilog", "-g2005", "-I.", "-s", "plat_gif_tb", "-o", "plat_gif_tb.vvp",
                    "plat_gif_tb.v", "platformer.v"], check=True)
    with ThreadPoolExecutor(args.jobs) as pool:
        for job in pool.map(lambda a: run_job(*a), [(i, t0, t1) for i, (t0, t1) in enumerate(SEGMENTS)]):
            print(f"segment {job + 1}/{len(SEGMENTS)} recorded", flush=True)

    with open("plat_palette.hex") as f:
        pal = [int(line, 16) for line in f if line.strip()]
    flat = [c for v in pal for c in ((v >> 16) & 255, (v >> 8) & 255, v & 255)]
    index = {(flat[3 * i], flat[3 * i + 1], flat[3 * i + 2]): i for i in range(len(pal))}
    frames = []
    for i in range(len(SEGMENTS)):
        for img in load_frames(f"plat_gif_{i}.hex"):
            p = Image.new("P", img.size)
            p.putpalette(flat)
            raw = img.tobytes()
            p.putdata([index[(raw[j], raw[j + 1], raw[j + 2])] for j in range(0, len(raw), 3)])
            frames.append(p.resize((640, 480), Image.NEAREST))
        os.remove(f"plat_gif_{i}.hex")
    durations = [30, 30, 40] * (len(frames) // 3 + 1)                  # averages 30 fps
    frames[0].save(args.out, save_all=True, append_images=frames[1:], duration=durations[:len(frames)],
                   loop=0, optimize=False, disposal=1)
    print(f"wrote {args.out}: {len(frames)} frames, {os.path.getsize(args.out) / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
