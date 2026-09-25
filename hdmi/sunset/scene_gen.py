#!/usr/bin/env python3
"""Art and reference model for scene.v: a parallax pixel-art sunset over a lake.

The scene is 320x240 logical pixels (each shown as 2x2 on the 640x480 screen). The FPGA
composites it every pixel from palette-indexed layers:

  sky        dithered gradient, sun with glow, star map
  clouds     512-wide strip, slow drift
  mountains  512-wide strip          \
  hills      512-wide strip           > scrolling at different speeds (parallax)
  front      512-wide strip, shore   /
  birds      small flapping sprites
  water      everything above the horizon mirrored, rippled, darkened, with sparkles

Running it writes scene_params.vh (constants shared with scene.v) and the scene_*.hex ROMs.
  --preview N [--out F]     render frame N with the reference model to a 640x480 PNG
  --check FILE --frame N    compare a frame dumped by scene_tb.v with the model
"""
import argparse
import math
import random

from PIL import Image

# ------------------------------------------------------------------ layout (logical pixels)
LW, LH = 320, 240
HORIZON = 160               # first water row
STRIP_W = 512               # width of the scrolling strips (wraps)

STARS_TOP, STARS_H = 0, 64          # star map is LW wide, does not scroll
CLOUDS_TOP, CLOUDS_H = 36, 64
MOUNT_TOP, MOUNT_H = 80, 80
HILLS_TOP, HILLS_H = 104, 56
FRONT_TOP, FRONT_H = 128, 112

SUN_X, SUN_Y = 232, 116
SUN_R2, GLOW1_R2, GLOW2_R2 = 19 ** 2, 25 ** 2, 32 ** 2

# Scroll speeds in 1/256 logical pixel per frame (60 frames per second).
SPD_CLOUDS, SPD_MOUNT, SPD_HILLS, SPD_FRONT = 32, 20, 64, 160
BIRD_SPD = 3                                    # 1/8 pixel per frame
BIRDS = [(0, 50), (21, 42), (40, 55)]           # (x offset, y) of each bird in the flock
BOB = [0, 1, 1, 1, 0, -1, -1, -1]               # flock bobbing, indexed by (t / 8 + 3 * bird)

BAYER4 = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]

# ------------------------------------------------------------------ palette
# Indices 0..31 are the scene colours; 32..63 are the same colours as reflected in the water.
PAL_SKY = 0                 # 0..11, top of the sky to the horizon
PAL_SUN_LIGHT, PAL_SUN_DARK, PAL_GLOW = 12, 13, 14
PAL_STAR_DIM, PAL_STAR_BRIGHT = 15, 16
PAL_CLOUDS = 17             # 17..19: lit underside, middle, shadowed top
PAL_MOUNT = 20              # 20..22: near range, far range, snow
PAL_HILLS = 23              # 23..25: near trees, far trees, rim light
PAL_FRONT = 26              # 26..28: silhouette, far reeds, rim light
PAL_BIRD, PAL_SPARKLE = 29, 30
PAL_WATER = 32

SKY_COLOURS = ["140c2e", "1d1040", "291552", "3a1a63", "4e1f70", "672578",
               "832b7c", "a1337c", "be4176", "d9566c", "ee7462", "fb9a5c"]
COLOURS = {
    PAL_SUN_LIGHT: "fff4c2", PAL_SUN_DARK: "ffd27a", PAL_GLOW: "ffb870",
    PAL_STAR_DIM: "8f7cc0", PAL_STAR_BRIGHT: "fff8e6",
    PAL_CLOUDS + 0: "ffae8a", PAL_CLOUDS + 1: "d9678a", PAL_CLOUDS + 2: "8a3f80",
    PAL_MOUNT + 0: "3a2461", PAL_MOUNT + 1: "5c3479", PAL_MOUNT + 2: "e9a2b4",
    PAL_HILLS + 0: "1e1238", PAL_HILLS + 1: "2c1a4a", PAL_HILLS + 2: "a24c6e",
    PAL_FRONT + 0: "0d0718", PAL_FRONT + 1: "1c0f2c", PAL_FRONT + 2: "e57a4e",
    PAL_BIRD: "1a0e28", PAL_SPARKLE: "fff1c4", 31: "000000",
}
WATER_TINT, WATER_MIX, WATER_DARKEN = (22, 30, 72), 0.30, 0.82


def hex_rgb(s):
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


def build_palette():
    pal = [hex_rgb(c) for c in SKY_COLOURS] + [hex_rgb(COLOURS[i]) for i in range(12, 32)]
    water = [tuple(round(((1 - WATER_MIX) * c + WATER_MIX * w) * WATER_DARKEN)
                   for c, w in zip(rgb, WATER_TINT)) for rgb in pal]
    return pal + water


# ------------------------------------------------------------------ art
rng = random.Random(9)


def periodic(x, terms, ridged=False):
    """Sum of sines that repeats every STRIP_W pixels. terms = [(cycles, amplitude, phase)]."""
    total = 0.0
    for k, a, p in terms:
        s = math.sin(math.pi * k * x / STRIP_W + p)
        total += a * (1 - abs(s)) if ridged else a * math.sin(2 * math.pi * k * x / STRIP_W + p)
    return total


def normalise(vals, lo, hi):
    a, b = min(vals), max(vals)
    return [lo + (v - a) * (hi - lo) / (b - a) for v in vals]


def grid(w, h):
    return [[0] * w for _ in range(h)]


def put(g, x, y, v, wrap=True):
    h = len(g)
    w = len(g[0])
    if wrap:
        x %= w
    if 0 <= x < w and 0 <= y < h:
        g[y][x] = v


def pine(g, x0, base, height, v, wrap=True):
    """Pixel-art pine: stacked tiers that widen towards the bottom, 1 px trunk."""
    tiers = max(3, height // 5)
    crown = height - 2
    for r in range(crown):
        frac = r / crown
        tier_pos = (r * tiers / crown) % 1.0
        half = int(0.5 + (0.6 + 3.6 * frac) * (0.45 + 0.55 * tier_pos) * height / 16 + 0.3)
        y = base - height + r
        for dx in range(-half, half + 1):
            put(g, x0 + dx, y, v, wrap)
    for r in range(crown, height + 1):
        put(g, x0, base - height + r, v, wrap)


def big_pine(g, x0, base, height, v):
    """Large pine: overlapping triangular tiers with drooping tips, widening towards the bottom."""
    trunk = max(2, height // 10)
    crown = height - trunk
    top = base - height
    tiers = max(3, crown // 9)
    step = crown / tiers
    for i in range(tiers):
        a = top + i * step - (step * 0.35 if i else 0)
        b = top + (i + 1) * step
        wmax = (0.05 + 0.19 * (i + 1) / tiers) * height
        for y in range(int(a), int(b) + 1):
            f = (y - a) / (b - a)
            half = int(wmax * max(0.0, f) ** 0.85 + 0.5)
            for dx in range(-half, half + 1):
                put(g, x0 + dx, y, v)
        tip = int(wmax + 0.5)
        for side in (-1, 1):                                  # drooping branch tips
            put(g, x0 + side * (tip + 1), int(b), v)
            put(g, x0 + side * (tip + 1), int(b) + 1, v)
    for y in range(base - trunk, base + 1):
        for dx in range(-max(0, height // 40), max(0, height // 40) + 1):
            put(g, x0 + dx, y, v)


def rim_light(g, solid, rim):
    """Light edges facing up and towards the sun (right): the pixel above is empty and the one to the left is solid."""
    h, w = len(g), len(g[0])
    lit = [(x, y) for y in range(1, h) for x in range(w)
           if g[y][x] == solid and g[y - 1][x] == 0 and g[y][(x - 1) % w] in (solid, rim)]
    for x, y in lit:
        g[y][x] = rim


def make_mountains():
    g = grid(STRIP_W, MOUNT_H)
    far_terms = [(2, 30, 0.4), (5, 16, 1.3), (9, 9, 2.1), (19, 4, 0.2), (37, 2, 1.7)]
    near_terms = [(3, 7, 0.9), (7, 4, 2.5), (15, 2, 0.1)]
    far = normalise([periodic(x, far_terms, ridged=True) for x in range(STRIP_W)], 26, 76)
    near = normalise([periodic(x, near_terms) for x in range(STRIP_W)], 8, 30)
    snow_line = 58
    for x in range(STRIP_W):
        jag = rng.choice([-1, 0, 0, 1])
        for y in range(MOUNT_H):
            up = MOUNT_H - y                      # height above the bottom of the strip
            if up <= near[x]:
                g[y][x] = 1
            elif up <= far[x]:
                # Snow caps the high peaks; it reaches further down on the sunny (right-facing) slopes.
                facing = far[(x + 1) % STRIP_W] < far[x]
                depth = (far[x] - snow_line) * (0.9 if facing else 0.45)
                g[y][x] = 3 if far[x] > snow_line and far[x] - up < depth + jag else 2
    return g


def make_hills():
    g = grid(STRIP_W, HILLS_H)
    back = normalise([periodic(x, [(4, 6, 0.3), (9, 3, 1.1)]) for x in range(STRIP_W)], 12, 26)
    front = normalise([periodic(x, [(3, 5, 2.2), (8, 3, 0.4), (17, 1, 1.9)]) for x in range(STRIP_W)], 4, 15)
    for x in range(STRIP_W):
        for y in range(HILLS_H):
            if HILLS_H - y <= front[x]:
                g[y][x] = 1
            elif HILLS_H - y <= back[x]:
                g[y][x] = 2
    # Forest: a lighter row of trees on the back hills, darker bigger trees in front.
    x = 0
    while x < STRIP_W:
        pine(g, x, HILLS_H - int(back[x]) + 1, rng.randint(6, 12), 2)
        x += rng.randint(3, 7)
    x = 2
    while x < STRIP_W:
        if rng.random() < 0.8:
            pine(g, x, HILLS_H - int(front[x]) + 1, rng.randint(9, 19), 1)
        x += rng.randint(4, 9)
    rim_light(g, 1, 3)
    return g


def make_front():
    g = grid(STRIP_W, FRONT_H)
    bank = normalise([periodic(x, [(2, 5, 1.0), (5, 3, 0.2), (13, 1.5, 2.0)]) for x in range(STRIP_W)], 2, 16)
    # Two mounds for the big trees.
    for cx, w, hgt in ((96, 60, 14), (352, 70, 12)):
        for x in range(cx - w, cx + w):
            k = 1 - ((x - cx) / w) ** 2
            bank[x % STRIP_W] += hgt * k
    for x in range(STRIP_W):
        for y in range(FRONT_H):
            if FRONT_H - y <= bank[x]:
                g[y][x] = 1
    # Far reeds (lighter) first, then near reeds and grass over them.
    for _ in range(90):
        x = rng.randrange(STRIP_W)
        top = FRONT_H - int(bank[x]) - rng.randint(4, 14)
        for y in range(top, FRONT_H - int(bank[x]) + 1):
            put(g, x, y, 2)
    for _ in range(14):
        cx = rng.randrange(STRIP_W)
        for _ in range(rng.randint(5, 11)):
            x = cx + rng.randint(-8, 8)
            ground = FRONT_H - int(bank[x % STRIP_W])
            h = rng.randint(10, 30)
            for y in range(ground - h, ground + 1):
                put(g, x, y, 1)
            if rng.random() < 0.5:                           # cattail head
                for y in range(ground - h + 1, ground - h + 6):
                    put(g, x, y, 1)
                    put(g, x + 1, y, 1)
    for x in range(STRIP_W):
        if rng.random() < 0.35:
            ground = FRONT_H - int(bank[x])
            for y in range(ground - rng.randint(1, 4), ground):
                put(g, x, y, 1)
    # Big pines on the mounds, and a few smaller ones.
    for x0, h in ((92, 106), (120, 70), (346, 92), (372, 56), (470, 38)):
        big_pine(g, x0, FRONT_H - int(bank[x0]) + 2, h, 1)
    rim_light(g, 1, 3)
    return g


def make_clouds():
    g = grid(STRIP_W, CLOUDS_H)
    shade = grid(STRIP_W, CLOUDS_H)            # rows above the cloud's flat bottom
    clouds = []
    for i in range(11):
        cx = int(i * STRIP_W / 11 + rng.randint(-15, 15))
        base = rng.randint(10, CLOUDS_H - 4)
        length = rng.randint(24, 80)
        puffy = rng.random() < 0.55
        clouds.append((cx, base, length, puffy))
    for cx, base, length, puffy in clouds:
        x = cx - length // 2
        while x < cx + length // 2:
            edge = 1 - abs(x - cx) / (length / 2)
            r = rng.uniform(3, 9) * (0.4 + 0.6 * edge) if puffy else rng.uniform(1.5, 3.5) * (0.5 + 0.5 * edge)
            px, py = x, base - r * 0.6
            for yy in range(int(py - r) - 1, base + 1):
                for xx in range(int(px - r) - 1, int(px + r) + 2):
                    if (xx - px) ** 2 + (yy - py) ** 2 <= r * r and 0 <= yy < CLOUDS_H:
                        g[yy][xx % STRIP_W] = 1
                        shade[yy][xx % STRIP_W] = base - yy
            x += max(2, int(r * 0.8))
    # Sunset light comes from below: bright undersides, darker tops, dithered in between.
    for y in range(CLOUDS_H):
        for x in range(STRIP_W):
            if g[y][x]:
                up = shade[y][x] + (0.5 if BAYER4[y & 3][x & 3] < 8 else 0)
                g[y][x] = 1 if up < 1.5 else 2 if up < 4.5 else 3
    return g


def make_stars():
    g = grid(LW, STARS_H)
    for y in range(STARS_H):
        density = 0.022 * (1 - y / STARS_H) ** 1.6
        for x in range(LW):
            if rng.random() < density:
                r = rng.random()
                g[y][x] = 1 if r < 0.6 else 2 if r < 0.82 else 3
    for _ in range(7):                                  # a few big ones
        x, y = rng.randrange(2, LW - 2), rng.randrange(2, 34)
        g[y][x] = 2
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            g[y + dy][x + dx] = 1
    return g


def make_sky_rows():
    """Per row: (base band << 5) | dither threshold; band+1 shows where bayer < threshold."""
    rows = []
    last = len(SKY_COLOURS) - 1
    for y in range(HORIZON):
        pos = last * (y / (HORIZON - 1)) ** 1.15
        band = min(int(pos), last)
        frac = pos - band
        thr = 0 if band == last else max(0, min(16, round((frac * 2 - 0.5) * 16)))
        rows.append((band << 5) | thr)
    return rows


def make_ripple():
    """Signed x offset for water rows: index (depth / 8) * 32 + phase."""
    table = []
    for a in range(16):
        amp = 0.6 + 0.42 * a
        for p in range(32):
            s = math.sin(2 * math.pi * p / 32) + 0.35 * math.sin(4 * math.pi * p / 32 + 1.0)
            table.append(max(-8, min(7, round(amp * s / 1.2))))
    return table


BIRD_FRAMES = [
    ["................",
     "...x.......x....",
     "....x.....x.....",
     ".....xx.xx......",
     ".......x........",
     "................",
     "................",
     "................"],
    ["................",
     "................",
     "................",
     ".....xxxxx......",
     "....x..x..x.....",
     "...x.......x....",
     "................",
     "................"],
]


def make_birds():
    return [1 if c == "x" else 0 for frame in BIRD_FRAMES for row in frame for c in row]


def make_assets():
    return {
        "palette": build_palette(),
        "stars": make_stars(),
        "clouds": make_clouds(),
        "mountains": make_mountains(),
        "hills": make_hills(),
        "front": make_front(),
        "sky": make_sky_rows(),
        "ripple": make_ripple(),
        "bird": make_birds(),
    }


# ------------------------------------------------------------------ outputs
def write_hex(name, values, digits):
    with open(name, "w") as f:
        f.write("\n".join(f"{v & ((1 << (4 * digits)) - 1):0{digits}x}" for v in values) + "\n")


def flat(g):
    return [v for row in g for v in row]


def write_params():
    bob = 0
    for i, b in enumerate(BOB):
        bob |= (b & 7) << (3 * i)
    lines = [
        "// Generated by scene_gen.py - do not edit.",
        f"localparam LW = {LW}, STRIP_W = {STRIP_W}, HORIZON = {HORIZON};",
        f"localparam STARS_TOP = {STARS_TOP}, STARS_H = {STARS_H};",
        f"localparam CLOUDS_TOP = {CLOUDS_TOP}, CLOUDS_H = {CLOUDS_H};",
        f"localparam MOUNT_TOP = {MOUNT_TOP}, MOUNT_H = {MOUNT_H};",
        f"localparam HILLS_TOP = {HILLS_TOP}, HILLS_H = {HILLS_H};",
        f"localparam FRONT_TOP = {FRONT_TOP}, FRONT_H = {FRONT_H};",
        f"localparam SUN_X = {SUN_X}, SUN_Y = {SUN_Y};",
        f"localparam SUN_R2 = {SUN_R2}, GLOW1_R2 = {GLOW1_R2}, GLOW2_R2 = {GLOW2_R2};",
        f"localparam SPD_CLOUDS = {SPD_CLOUDS}, SPD_MOUNT = {SPD_MOUNT}, SPD_HILLS = {SPD_HILLS}, SPD_FRONT = {SPD_FRONT};",
        f"localparam BIRD_SPD = {BIRD_SPD};",
        "localparam " + ", ".join(f"BIRD{i}_X = {x}, BIRD{i}_Y = {y}" for i, (x, y) in enumerate(BIRDS)) + ";",
        f"localparam [23:0] BOB = 24'h{bob:06x};",
        f"localparam PAL_SKY = {PAL_SKY}, PAL_SUN_LIGHT = {PAL_SUN_LIGHT}, PAL_SUN_DARK = {PAL_SUN_DARK}, PAL_GLOW = {PAL_GLOW};",
        f"localparam PAL_STAR_DIM = {PAL_STAR_DIM}, PAL_STAR_BRIGHT = {PAL_STAR_BRIGHT};",
        f"localparam PAL_CLOUDS = {PAL_CLOUDS}, PAL_MOUNT = {PAL_MOUNT}, PAL_HILLS = {PAL_HILLS}, PAL_FRONT = {PAL_FRONT};",
        f"localparam PAL_BIRD = {PAL_BIRD}, PAL_SPARKLE = {PAL_SPARKLE}, PAL_WATER = {PAL_WATER};",
    ]
    with open("scene_params.vh", "w") as f:
        f.write("\n".join(lines) + "\n")


def write_all(a):
    write_params()
    write_hex("scene_palette.hex", [(r << 16) | (g << 8) | b for r, g, b in a["palette"]], 6)
    write_hex("scene_stars.hex", flat(a["stars"]), 1)
    write_hex("scene_clouds.hex", flat(a["clouds"]), 1)
    write_hex("scene_mountains.hex", flat(a["mountains"]), 1)
    write_hex("scene_hills.hex", flat(a["hills"]), 1)
    write_hex("scene_front.hex", flat(a["front"]), 1)
    write_hex("scene_sky.hex", a["sky"], 3)
    write_hex("scene_ripple.hex", a["ripple"], 1)
    write_hex("scene_bird.hex", a["bird"], 1)


# ------------------------------------------------------------------ reference model of scene.v
def hash16(v):
    v ^= (v << 7) & 0xFFFF
    v ^= v >> 9
    v ^= (v << 8) & 0xFFFF
    return v


def render(a, t):
    """Palette index of every logical pixel of frame t, row-major, exactly as scene.v computes it."""
    t &= 0xFFFF
    sc_c = ((t * SPD_CLOUDS) >> 8) & 511
    sc_m = ((t * SPD_MOUNT) >> 8) & 511
    sc_h = ((t * SPD_HILLS) >> 8) & 511
    sc_f = ((t * SPD_FRONT) >> 8) & 511
    flock = ((t * BIRD_SPD) >> 3) & 511
    birds = []
    for i, (ox, oy) in enumerate(BIRDS):
        birds.append(((flock + ox) & 511, oy + BOB[((t >> 3) + 3 * i) & 7], ((t >> 3) + i) & 1))

    def strip(g, top, h, row, col):
        r = row - top
        return g[r][col & 511] if 0 <= r < h else 0

    out = []
    for ly in range(LH):
        water = ly >= HORIZON
        d = ly - HORIZON if water else 0
        ry = 2 * HORIZON - 1 - ly if water else ly
        rip = a["ripple"][((d >> 3) << 5) | ((ly * 5 + (t >> 1)) & 31)] if water else 0
        sky = a["sky"][ry]
        for lx in range(LW):
            sx = lx + rip
            bayer = BAYER4[ly & 3][lx & 3]

            f = strip(a["front"], FRONT_TOP, FRONT_H, ly, lx + sc_f)
            if f:
                out.append(PAL_FRONT + f - 1)
                continue

            if not water:
                bird = 0
                for left, top, frame in birds:
                    bx, by = (lx - left) & 511, ly - top
                    if bx < 16 and 0 <= by < 8:
                        bird = a["bird"][(frame << 7) | (by << 4) | bx]
                        break
                if bird:
                    out.append(PAL_BIRD)
                    continue
            else:
                h = hash16(hash16(((ly & 127) << 9) | lx) ^ (t >> 3))
                if abs(sx - SUN_X) < 6 + (d >> 2) and (h & 63) == 0:
                    out.append(PAL_SPARKLE)
                    continue

            base = PAL_WATER if water else 0
            hl = strip(a["hills"], HILLS_TOP, HILLS_H, ry, sx + sc_h)
            mt = strip(a["mountains"], MOUNT_TOP, MOUNT_H, ry, sx + sc_m)
            cl = strip(a["clouds"], CLOUDS_TOP, CLOUDS_H, ry, sx + sc_c)
            dx, dy = sx - SUN_X, ry - SUN_Y
            d2 = dx * dx + dy * dy if abs(dx) < 64 and abs(dy) < 64 else 1 << 20
            st = a["stars"][ly][lx] if not water and ly < STARS_TOP + STARS_H else 0

            if hl:
                idx = PAL_HILLS + hl - 1
            elif mt:
                idx = PAL_MOUNT + mt - 1
            elif cl:
                idx = PAL_CLOUDS + cl - 1
            elif d2 < SUN_R2:
                idx = PAL_SUN_LIGHT if dy < -4 else PAL_SUN_DARK
            elif (d2 < GLOW1_R2 and bayer < 10) or (d2 < GLOW2_R2 and bayer < 4):
                idx = PAL_GLOW
            elif st:
                twinkle_on = ((t >> 3) + lx + ly) & 3 == 0
                idx = PAL_STAR_DIM if st == 1 else PAL_STAR_BRIGHT if st == 2 or twinkle_on else PAL_STAR_DIM
            else:
                idx = PAL_SKY + (sky >> 5) + (1 if bayer < (sky & 31) else 0)
            out.append(base + idx)
    return out


def to_image(a, idx):
    img = Image.new("RGB", (LW, LH))
    img.putdata([a["palette"][i] for i in idx])
    return img.resize((LW * 2, LH * 2), Image.NEAREST)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--preview", type=int, metavar="N", help="render frame N to --out")
    ap.add_argument("--out", default="scene_preview.png")
    ap.add_argument("--check", metavar="FILE", help="frame dump from scene_tb.v to compare")
    ap.add_argument("--frame", type=int, default=0, help="frame number of --check")
    args = ap.parse_args()

    a = make_assets()
    write_all(a)

    if args.preview is not None:
        to_image(a, render(a, args.preview)).save(args.out)
        print(f"wrote {args.out} (frame {args.preview})")

    if args.check:
        want = to_image(a, render(a, args.frame))
        with open(args.check) as f:
            got = [int(line, 16) for line in f if line.strip()]
        if len(got) != 640 * 480:
            raise SystemExit(f"FAIL: {args.check} has {len(got)} pixels, expected {640 * 480}")
        img = Image.new("RGB", (640, 480))
        img.putdata([((v >> 16) & 255, (v >> 8) & 255, v & 255) for v in got])
        img.save(args.check.rsplit(".", 1)[0] + ".png")
        bad = sum(1 for p, q in zip(img.tobytes(), want.tobytes()) if p != q)
        print(f"{'PASS' if bad == 0 else 'FAIL'}: {bad} byte mismatches vs model for frame {args.frame}")
        if bad:
            raise SystemExit(1)


if __name__ == "__main__":
    main()
