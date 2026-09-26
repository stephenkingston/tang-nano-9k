#!/usr/bin/env python3
"""Art, text and level for platformer.v (NANO QUEST), a small NES-style platformer.

All art is original. Writes, for $readmemh:
  plat_palette.hex  64 colours: 0-15 tiles, 16-31 sprites (16 = transparent), 32-35 logo, 36 text, 37 black
  plat_tiles.hex    64 tile slots of 16x16, 4 bits per pixel (tile palette)
  plat_slots.hex    tile id x animation frame -> tile slot (256 entries)
  plat_sprites.hex  16 frames of 16x16, 4 bits per pixel (sprite palette, 0 = transparent)
  plat_font.hex     64 glyphs of 8x8, one byte per row (MSB = left)
  plat_logo.hex     title logo, LOGO_H rows of 256 (LOGO_W used), 2 bits per pixel
  plat_rows.hex     text layout: per page and 8-px text row, {valid, first column, length, string offset}
  plat_text.hex     the strings: 7 bits per character (bit 6 = blinks)
  plat_level.hex    the level: 16 rows x 256 columns of tile ids
  plat_spawns.hex   enemies: {column, row} sorted by column
  plat_params.vh    constants shared with platformer.v
Also writes plat_level.png (whole level) and plat_sheet.png (tiles and sprites) for checking.
"""
import math

from PIL import Image

# ------------------------------------------------------------------ palettes
TILE_PAL = [
    (0x6B, 0x8C, 0xFF),  # 0 sky
    (0x00, 0x00, 0x00),  # 1 black
    (0xFF, 0xFF, 0xFF),  # 2 white
    (0xC8, 0x4C, 0x0C),  # 3 brick
    (0x6E, 0x22, 0x08),  # 4 brick dark
    (0xFC, 0xBC, 0x90),  # 5 brick light
    (0xF8, 0xA0, 0x30),  # 6 gold
    (0xA8, 0x50, 0x10),  # 7 gold dark
    (0x9C, 0xE0, 0x30),  # 8 green light
    (0x10, 0xA8, 0x20),  # 9 green
    (0x00, 0x50, 0x10),  # 10 green dark
    (0x3C, 0xBC, 0xFC),  # 11 cloud shade
    (0xFC, 0xE0, 0x58),  # 12 yellow
    (0x0C, 0x6C, 0x18),  # 13 hill spots
    (0xB8, 0xB8, 0xC8),  # 14 grey
    (0x30, 0x30, 0x38),  # 15 dark grey
]
SPRITE_PAL = [
    (0, 0, 0),           # 0 transparent
    (0x10, 0x08, 0x10),  # 1 outline
    (0xFC, 0xC8, 0x98),  # 2 skin
    (0xF0, 0x60, 0x18),  # 3 orange (beanie, shoes)
    (0x28, 0x58, 0xE8),  # 4 blue (jacket)
    (0x70, 0x38, 0x10),  # 5 brown (hair, trousers)
    (0xFF, 0xFF, 0xFF),  # 6 white
    (0xFC, 0xE0, 0x40),  # 7 yellow (pompom, buttons)
    (0xA8, 0x40, 0xE8),  # 8 slime
    (0x58, 0x18, 0x88),  # 9 slime dark
    (0xDC, 0x98, 0xFC),  # 10 slime light
    (0xF8, 0xB8, 0x10),  # 11 coin
    (0xA0, 0x60, 0x00),  # 12 coin dark
    (0xFF, 0xF4, 0xB0),  # 13 coin shine
    (0x20, 0xB0, 0x40),  # 14 green (flag emblem)
    (0x90, 0x98, 0xB0),  # 15 grey
]
LOGO_PAL = [(0xC8, 0x4C, 0x0C), (0xFC, 0xE8, 0xC8), (0x30, 0x10, 0x04), (0x00, 0x00, 0x00)]
TEXT_WHITE, BLACK = (0xFF, 0xFF, 0xFF), (0x00, 0x00, 0x00)


def blank(w=16, h=16, v=0):
    return [[v] * w for _ in range(h)]


def from_art(rows, key):
    return [[key[c] for c in row] for row in rows]


# ------------------------------------------------------------------ tiles (tile palette indices)
def ground():
    t = blank(v=3)
    for y in range(16):
        for x in range(16):
            if x == 0 or y == 0:
                t[y][x] = 5
            if x == 15 or y == 15:
                t[y][x] = 4
    # cracks
    for x, y in [(6, 1), (6, 2), (6, 3), (5, 4), (4, 5), (4, 6), (10, 7), (11, 8), (11, 9), (11, 10),
                 (2, 10), (3, 11), (3, 12), (13, 3), (14, 4)]:
        t[y][x] = 4
        if x + 1 < 15:
            t[y][x + 1] = 5 if t[y][x + 1] == 3 and (x + y) % 3 == 0 else t[y][x + 1]
    return t


def brick():
    t = blank(v=3)
    for y in range(16):
        for x in range(16):
            row = y // 4
            off = 0 if row % 2 == 0 else 4
            if y % 4 == 3:
                t[y][x] = 4                                   # mortar
            elif (x + off) % 8 == 7:
                t[y][x] = 4
            elif y % 4 == 0:
                t[y][x] = 5 if (x + off) % 8 != 7 else 4      # lit top edge
    return t


QMARK = ["..####..",
         ".##..##.",
         ".##..##.",
         "....##..",
         "...##...",
         "........",
         "...##...",
         "........"]


def qblock(shade):
    body = {0: 6, 1: 12, 2: 7}[shade]
    t = blank(v=body)
    for y in range(16):
        for x in range(16):
            if x == 15 or y == 15:
                t[y][x] = 1
            elif x == 0 or y == 0:
                t[y][x] = 7
    for x, y in [(2, 2), (13, 2), (2, 13), (13, 13)]:
        t[y][x] = 7                                         # rivets
    for y, row in enumerate(QMARK):
        for x, c in enumerate(row):
            if c == "#":
                t[y + 4][x + 4] = 7
                if x + 5 < 15 and y + 5 < 15 and QMARK[y][x] == "#":
                    pass
    for y, row in enumerate(QMARK):
        for x, c in enumerate(row):
            if c == "#":
                t[y + 3][x + 3] = 2 if shade == 1 else 12 if shade == 0 else 6
    return t


def used_block():
    t = blank(v=7)
    for y in range(16):
        for x in range(16):
            if x == 15 or y == 15 or x == 0 or y == 0:
                t[y][x] = 4
    for x, y in [(2, 2), (13, 2), (2, 13), (13, 13)]:
        t[y][x] = 4
    return t


def hard_block():
    t = blank(v=3)
    for y in range(16):
        for x in range(16):
            d = min(x, y, 15 - x, 15 - y)
            if d == 0:
                t[y][x] = 4
            elif x < 4 and y > x and y < 15 - x or (y < 4 and x > y and x < 15 - y):
                t[y][x] = 5
            elif x > 11 and 15 - x < y and y > 15 - x and y < x or (y > 11 and x > 15 - y and x < y):
                t[y][x] = 4
    return t


def pipe(part):
    """part: tl, tr (the lip) or l, r (the body)."""
    t = blank(v=9)
    lip = part in ("tl", "tr")
    for y in range(16):
        for x in range(16):
            gx = x if part in ("tl", "l") else x + 16         # x across the 32-px pipe
            lo, hi = (0, 31) if lip else (2, 29)
            if gx < lo or gx > hi:
                t[y][x] = 0
                continue
            if gx in (lo, hi) or (lip and (y in (0, 15))):
                t[y][x] = 10
            elif gx in (lo + 3, lo + 4, lo + 6) or gx == lo + 9:
                t[y][x] = 8                                   # highlight stripes
            elif gx > hi - 7:
                t[y][x] = 10 if (gx + y) % 2 == 0 and gx > hi - 4 else 9
    return t


def coin(frame):
    t = blank()
    w = [5, 3, 1, 3][frame]
    for y in range(2, 14):
        for x in range(16):
            dx = (x - 7.5) / max(w, 0.8)
            dy = (y - 7.5) / 6
            if dx * dx + dy * dy <= 1:
                t[y][x] = 12
                if dx * dx + dy * dy > 0.55:
                    t[y][x] = 7
                elif x < 7 and w > 1:
                    t[y][x] = 2 if (y in (5, 6) and x > 5) else 12
    return t


def decor_canvas(w, h):
    return blank(w, h)


def outline(c, fill_vals, line):
    h, w = len(c), len(c[0])
    out = [row[:] for row in c]
    for y in range(h):
        for x in range(w):
            if c[y][x] == 0:
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < w and 0 <= ny < h and c[ny][nx] in fill_vals:
                        out[y][x] = line
                        break
    return out


def cloud():
    """48x32 cloud: returns 6 tiles (TL TM TR / BL BM BR)."""
    c = decor_canvas(48, 32)
    for cx, cy, r in [(12, 20, 8), (24, 13, 11), (36, 19, 9), (18, 22, 8), (30, 23, 8)]:
        for y in range(32):
            for x in range(48):
                if (x - cx) ** 2 + (y - cy) ** 2 <= r * r and y <= 28:
                    c[y][x] = 2
    for y in range(32):
        for x in range(48):
            if c[y][x] == 2 and y >= 24:
                c[y][x] = 11 if (x + y) % 2 == 0 or y >= 26 else 2
    c = outline(c, (2, 11), 1)
    return c


def hill(width, height):
    """A rounded dome filling the bottom of a width x height canvas."""
    c = decor_canvas(width, height)
    cx, rx, ry = width / 2 - 0.5, width / 2 - 1, height - 2
    for y in range(height):
        for x in range(width):
            if ((x - cx) / rx) ** 2 + ((y - height) / ry) ** 2 <= 1:
                c[y][x] = 9
    c = outline(c, (9,), 1)
    for sx, sy in [(int(cx) - 7, 18), (int(cx) + 4, 24), (int(cx) - 12, 34), (int(cx) + 11, 36),
                   (int(cx) - 2, 38)]:
        for y in range(sy, sy + 4):
            for x in range(sx, sx + 2 + (y - sy) % 2):
                if 0 <= y < height and 0 <= x < width and c[y][x] == 9:
                    c[y][x] = 13
    return c


def bush():
    c = decor_canvas(48, 16)
    for cx, cy, r in [(8, 11, 7), (18, 8, 8), (30, 8, 8), (40, 11, 7), (24, 12, 7)]:
        for y in range(16):
            for x in range(48):
                if (x - cx) ** 2 + (y - cy) ** 2 <= r * r:
                    c[y][x] = 8 if y < cy - r // 3 else 9
    c = outline(c, (8, 9), 1)
    return c


def cut(canvas, tx, ty):
    return [row[tx * 16:tx * 16 + 16] for row in canvas[ty * 16:ty * 16 + 16]]


def pole(top):
    t = blank()
    if top:
        for y in range(16):
            for x in range(16):
                if (x - 7.5) ** 2 + (y - 9) ** 2 <= 16:
                    t[y][x] = 9
                if (x - 7.5) ** 2 + (y - 9) ** 2 <= 16 and (x - 6) ** 2 + (y - 7) ** 2 <= 2:
                    t[y][x] = 8
        return outline(t, (8, 9), 1)
    for y in range(16):
        t[y][7] = 14
        t[y][8] = 15
    return t


def flag():
    t = blank()
    for y in range(1, 13):
        for x in range(16):
            if x >= y - 1 and x >= 1 and x >= (12 - y) - 0:
                pass
    for y in range(1, 15):
        span = 15 - abs(y - 7.5) * 2
        for x in range(16 - int(span), 16):
            t[y][x] = 2
    for y in range(5, 10):
        for x in range(9, 13):
            if (x - 10.5) ** 2 + (y - 7) ** 2 <= 3:
                t[y][x] = 9
    return t


def castle(part):
    t = brick()
    if part == "top":
        for y in range(16):
            for x in range(16):
                if y < 6 and (x // 4) % 2 == 1:
                    t[y][x] = 0
                if y == 6 and (x // 4) % 2 == 1:
                    t[y][x] = 5
    elif part == "door":
        for y in range(16):
            for x in range(16):
                if x >= 3 and x <= 12 and (y >= 5 or (x - 7.5) ** 2 + (y - 5) ** 2 <= 22):
                    t[y][x] = 1
    elif part == "window":
        for y in range(3, 12):
            for x in range(5, 11):
                t[y][x] = 1
    return t


# Tile ids: bit 5 set = solid. Each id maps to 1 or more tile slots (animation frames).
HILLS = [f"HILL_{i}" for i in range(12)]                  # 4 x 3 tiles, row by row
T = dict(SKY=0, COIN=1, CLOUD_TL=2, CLOUD_TM=3, CLOUD_TR=4, CLOUD_BL=5, CLOUD_BM=6, CLOUD_BR=7,
         **{name: 8 + i for i, name in enumerate(HILLS)},
         BUSH_L=20, BUSH_M=21, BUSH_R=22, POLE=23, POLE_TOP=24, FLAG=25,
         CASTLE_BRICK=26, CASTLE_TOP=27, CASTLE_DOOR=28, CASTLE_WINDOW=29,
         GROUND=32, BRICK=33, QBLOCK=34, USED=35, HARD=36, PIPE_TL=37, PIPE_TR=38, PIPE_L=39, PIPE_R=40)


def build_tiles():
    slots = []            # list of 16x16 arrays
    slot_of = {}          # (tile id, anim 0..3) -> slot

    def add(tid, frames):
        base = len(slots)
        slots.extend(frames)
        for a in range(4):
            slot_of[(tid, a)] = base + (a % len(frames))

    add(T["SKY"], [blank()])
    add(T["COIN"], [coin(0), coin(1), coin(2), coin(1)])
    cl = cloud()
    for i, name in enumerate(["CLOUD_TL", "CLOUD_TM", "CLOUD_TR", "CLOUD_BL", "CLOUD_BM", "CLOUD_BR"]):
        add(T[name], [cut(cl, i % 3, i // 3)])
    hl = hill(64, 48)
    for i, name in enumerate(HILLS):
        add(T[name], [cut(hl, i % 4, i // 4)])
    bs = bush()
    for i, name in enumerate(["BUSH_L", "BUSH_M", "BUSH_R"]):
        add(T[name], [cut(bs, i, 0)])
    add(T["POLE"], [pole(False)])
    add(T["POLE_TOP"], [pole(True)])
    add(T["FLAG"], [flag()])
    add(T["CASTLE_BRICK"], [brick()])
    add(T["CASTLE_TOP"], [castle("top")])
    add(T["CASTLE_DOOR"], [castle("door")])
    add(T["CASTLE_WINDOW"], [castle("window")])
    add(T["GROUND"], [ground()])
    add(T["BRICK"], [brick()])
    add(T["QBLOCK"], [qblock(0), qblock(0), qblock(1), qblock(2)])
    add(T["USED"], [used_block()])
    add(T["HARD"], [hard_block()])
    add(T["PIPE_TL"], [pipe("tl")])
    add(T["PIPE_TR"], [pipe("tr")])
    add(T["PIPE_L"], [pipe("l")])
    add(T["PIPE_R"], [pipe("r")])
    assert len(slots) <= 64, len(slots)
    return slots, slot_of


# ------------------------------------------------------------------ sprites (sprite palette indices)
SK = {".": 0, "k": 1, "s": 2, "o": 3, "b": 4, "n": 5, "w": 6, "y": 7, "p": 8, "P": 9, "q": 10,
      "g": 11, "G": 12, "h": 13, "e": 14, "z": 15}

HERO_HEAD = [
    "......yy........",
    ".....kkkk.......",
    "....koooook.....",
    "...koooooook....",
    "..kkoooooookk...",
    "..knnkkkkkkk....",
    "..knssswkswk....",
    "..knsssskskk....",
    "..kssssssssk....",
    "...ksssskkk.....",
]
HERO_BODIES = {
    "stand": ["....kbbbbbk.....",
              "...kbbybbbbk....",
              "..ksbbbbbybsk...",
              "..kskbbbbbksk...",
              "...kknnknnkk....",
              "...kookkkook...."],
    "run1":  ["....kbbbbbk.....",
              "...kbbybbbbkk...",
              "..ksbbbbbybbsk..",
              "...kkbbbbbkkk...",
              "..kooknnknnk....",
              "..kkk...kook...."],
    "run2":  ["....kbbbbbk.....",
              "...kbsybbbbk....",
              "...kbbbbbybk....",
              "...kkbbbbbkk....",
              "....knnknnk.....",
              "....kookook....."],
    "run3":  ["....kbbbbbk.....",
              "..kkbbybbbbk....",
              ".ksbbbbbbybk....",
              "..kkkbbbbbkk....",
              "....knnknnkook..",
              "...kook...kkk..."],
    "jump":  [".ks.kbbbbbk.sk..",
              "..kkbbybbbbkk...",
              "....kbbbbbyk....",
              "....kbbbbbbk....",
              "...knnk.knnkok..",
              "..kook....kkk..."],
}
HERO_DEAD = [
    "......yy........",
    ".....kkkk.......",
    "....koooook.....",
    "..kkoooooookk...",
    ".ks.kkkkkkk.sk..",
    ".ks.ksksskk.sk..",
    "..k.kswswsk.k...",
    "....ksskssk.....",
    "....kskkksk.....",
    "...kbbbbbbbk....",
    "..kbbybbbybbk...",
    "..kbbbbbbbbbk...",
    "...knnk.knnk....",
    "...knnk.knnk....",
    "..kook...kook...",
    "..kkk.....kkk...",
]
SLIME = [
    ["................",
     "................",
     "................",
     "................",
     "......kkkk......",
     "....kkpqqpkk....",
     "...kpqqppppPk...",
     "..kpqpppppppPk..",
     "..kpwwkppwwkPk..",
     ".kppwkkppwkkpPk.",
     ".kpppppppppppPk.",
     ".kpppkkkkkpppPk.",
     ".kPppppppppppPk.",
     ".kPPPPPPPPPPPPk.",
     "..kkkkkkkkkkkk..",
     "................"],
    ["................",
     "................",
     "................",
     "................",
     "................",
     ".....kkkkkk.....",
     "...kkpqqqppkk...",
     "..kpqqppppppPk..",
     ".kpqpwwkppwwkPk.",
     ".kppwkkppwkkpPk.",
     "kpppppppppppppPk",
     "kpppppkkkkpppPPk",
     "kPppppppppppPPPk",
     "kPPPPPPPPPPPPPPk",
     ".kkkkkkkkkkkkkk.",
     "................"],
    ["................",
     "................",
     "................",
     "................",
     "................",
     "................",
     "................",
     "................",
     "................",
     "................",
     "....kkkkkkkk....",
     "..kkpqqpppppkk..",
     ".kpwkppppwkppPk.",
     "kPPPPPPPPPPPPPPk",
     ".kkkkkkkkkkkkkk.",
     "................"],
]


def hero(pose):
    rows = HERO_HEAD + HERO_BODIES[pose]
    return from_art(rows, SK)


def coin_sprite(frame):
    t = blank()
    w = [5, 3, 1, 3][frame]
    for y in range(1, 15):
        for x in range(16):
            dx = (x - 7.5) / max(w, 0.8)
            dy = (y - 7.5) / 6.5
            d = dx * dx + dy * dy
            if d <= 1:
                t[y][x] = 12 if d > 0.55 else 11
                if d <= 0.55 and x < 7 and w > 1 and 4 <= y <= 7:
                    t[y][x] = 13
    return t


SPRITE_FRAMES = ["stand", "run1", "run2", "run3", "jump", "dead", "slime1", "slime2", "slime_flat",
                 "coin0", "coin1", "coin2", "coin3"]


def build_sprites():
    frames = [hero("stand"), hero("run1"), hero("run2"), hero("run3"), hero("jump"), from_art(HERO_DEAD, SK),
              from_art(SLIME[0], SK), from_art(SLIME[1], SK), from_art(SLIME[2], SK),
              coin_sprite(0), coin_sprite(1), coin_sprite(2), coin_sprite(1)]
    for f in frames:
        assert len(f) == 16 and all(len(r) == 16 for r in f), "sprite size"
    while len(frames) < 16:
        frames.append(blank())
    return frames


# ------------------------------------------------------------------ font (8x8, NES-like bold)
FONT5 = {
    "0": ["01110", "10011", "10101", "10101", "11001", "10001", "01110"],
    "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
    "2": ["01110", "10001", "00001", "00110", "01000", "10000", "11111"],
    "3": ["11110", "00001", "00001", "01110", "00001", "00001", "11110"],
    "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
    "5": ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
    "6": ["01110", "10000", "10000", "11110", "10001", "10001", "01110"],
    "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
    "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
    "9": ["01110", "10001", "10001", "01111", "00001", "00001", "01110"],
    "A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
    "B": ["11110", "10001", "10001", "11110", "10001", "10001", "11110"],
    "C": ["01110", "10001", "10000", "10000", "10000", "10001", "01110"],
    "D": ["11110", "10001", "10001", "10001", "10001", "10001", "11110"],
    "E": ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
    "F": ["11111", "10000", "10000", "11110", "10000", "10000", "10000"],
    "G": ["01110", "10001", "10000", "10111", "10001", "10001", "01111"],
    "H": ["10001", "10001", "10001", "11111", "10001", "10001", "10001"],
    "I": ["01110", "00100", "00100", "00100", "00100", "00100", "01110"],
    "J": ["00111", "00010", "00010", "00010", "00010", "10010", "01100"],
    "K": ["10001", "10010", "10100", "11000", "10100", "10010", "10001"],
    "L": ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
    "M": ["10001", "11011", "10101", "10101", "10001", "10001", "10001"],
    "N": ["10001", "11001", "10101", "10011", "10001", "10001", "10001"],
    "O": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
    "P": ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
    "Q": ["01110", "10001", "10001", "10001", "10101", "10010", "01101"],
    "R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
    "S": ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
    "T": ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
    "U": ["10001", "10001", "10001", "10001", "10001", "10001", "01110"],
    "V": ["10001", "10001", "10001", "10001", "10001", "01010", "00100"],
    "W": ["10001", "10001", "10001", "10101", "10101", "10101", "01010"],
    "X": ["10001", "10001", "01010", "00100", "01010", "10001", "10001"],
    "Y": ["10001", "10001", "01010", "00100", "00100", "00100", "00100"],
    "Z": ["11111", "00001", "00010", "00100", "01000", "10000", "11111"],
    "-": ["00000", "00000", "00000", "11111", "00000", "00000", "00000"],
    "x": ["00000", "00000", "10001", "01010", "00100", "01010", "10001"],
    "!": ["00100", "00100", "00100", "00100", "00100", "00000", "00100"],
    ".": ["00000", "00000", "00000", "00000", "00000", "00000", "00100"],
    ":": ["00000", "00100", "00000", "00000", "00000", "00100", "00000"],
}
COIN8 = ["..###...", ".#####..", "##.####.", "##.####.", "##.####.", "##.####.", ".#####..", "..###..."]
COPY8 = ["..####..", ".#....#.", "#..##..#", "#.#....#", "#.#....#", "#..##..#", ".#....#.", "..####.."]
CHARS = " 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-x!.:"
CODE = {c: i for i, c in enumerate(CHARS)}
CODE["COIN"] = len(CHARS)
CODE["COPY"] = len(CHARS) + 1
DYN = ["SCORE5", "SCORE4", "SCORE3", "SCORE2", "SCORE1", "SCORE0", "COIN1", "COIN0",
       "TIME2", "TIME1", "TIME0", "LIVES", "WORLD"]
for i, name in enumerate(DYN):
    CODE[name] = 48 + i                                   # filled in by the hardware


def glyph8(ch):
    if ch == "COIN":
        return [int(r.replace("#", "1").replace(".", "0"), 2) for r in COIN8]
    if ch == "COPY":
        return [int(r.replace("#", "1").replace(".", "0"), 2) for r in COPY8]
    if ch == " ":
        return [0] * 8
    rows = FONT5[ch]
    out = []
    for r in rows:
        v = int(r, 2) << 2                                # 5 wide at columns 1..5
        v |= v >> 1                                       # embolden: 6 wide
        out.append(v & 0xFF)
    return out + [0]


def build_font():
    glyphs = [glyph8(c) for c in CHARS] + [glyph8("COIN"), glyph8("COPY")]
    while len(glyphs) < 64:
        glyphs.append([0] * 8)
    return glyphs


# ------------------------------------------------------------------ title logo
LOGO_W, LOGO_H = 192, 56
LOGO_X, LOGO_Y = 64, 40                                   # logical screen position


def build_logo():
    """2 bits per pixel: 0 transparent, 1 box, 2 letters, 3 outline and shadow."""
    img = blank(LOGO_W, LOGO_H)
    for y in range(LOGO_H):
        for x in range(LOGO_W):
            edge = x < 2 or y < 2 or x >= LOGO_W - 2 or y >= LOGO_H - 2
            corner = (x < 4 and y < 4) or (x < 4 and y >= LOGO_H - 4) or (x >= LOGO_W - 4 and y < 4) or \
                     (x >= LOGO_W - 4 and y >= LOGO_H - 4)
            if not corner:
                img[y][x] = 3 if edge else 1
    for x in range(4, LOGO_W - 4, 12):                      # rivets
        for y in (4, LOGO_H - 6):
            img[y][x] = img[y][x + 1] = 3

    def text(s, x0, y0, scale):
        x = x0
        for ch in s:
            if ch != " ":
                for gy, row in enumerate(FONT5[ch]):
                    for gx, bit in enumerate(row):
                        if bit == "1":
                            for sy in range(scale):
                                for sx in range(scale + 1):       # a little bolder
                                    px, py = x + gx * scale + sx, y0 + gy * scale + sy
                                    for dx, dy in ((2, 2), (1, 2), (2, 1)):
                                        if img[py + dy][px + dx] != 2:
                                            img[py + dy][px + dx] = 3
                                    img[py][px] = 2
            x += 6 * scale
    word1, word2 = "NANO", "QUEST"
    s = 3
    text(word1, (LOGO_W - len(word1) * 6 * s) // 2 + 1, 6, s)
    text(word2, (LOGO_W - len(word2) * 6 * s) // 2 + 1, 30, s)
    return img


# ------------------------------------------------------------------ text pages (40 x 30 cells of 8 px)
PAGES = ["PLAY", "TITLE", "CARD", "GAMEOVER", "CLEAR", "TIMEUP"]
HUD = [(1, 3, "NANO           WORLD     TIME"),
       (2, 3, ["SCORE5", "SCORE4", "SCORE3", "SCORE2", "SCORE1", "SCORE0", " ", " ", " ", "COIN", "x",
               "COIN1", "COIN0", " ", " ", " ", " ", " ", "1", "-", "WORLD", " ", " ", " ", " ", " ", " ",
               "TIME2", "TIME1", "TIME0"])]
PAGE_TEXT = {
    "PLAY": [],
    "TITLE": [(17, 14, "!PRESS BUTTON"), (20, 11, "S2 RUN     S1 JUMP"), (23, 13, ["COPY", " ", "2026 TANG NANO"])],
    "CARD": [(12, 15, ["W", "O", "R", "L", "D", " ", "1", "-", "WORLD"]), (15, 19, ["x", " ", " ", "LIVES"])],
    "GAMEOVER": [(14, 15, "GAME OVER")],
    "CLEAR": [(12, 13, "COURSE CLEAR!"), (14, 11, "THANK YOU NANO!")],
    "TIMEUP": [(14, 16, "TIME UP")],
}


def build_text():
    """Row table: per (page, row) {valid, first column, length, offset}; strings as 7-bit codes."""
    strings = []
    rows = [0] * (8 * 32)
    for p, name in enumerate(PAGES):
        for row, col, s in HUD + PAGE_TEXT[name]:
            blink = isinstance(s, str) and s.startswith("!")
            if blink:
                s = s[1:]
            if isinstance(s, str):
                cells = list(s)
            else:                                         # special codes mixed with plain text
                cells = [c for item in s for c in ([item] if item in CODE else list(item))]
            codes = [CODE[c] | (64 if blink else 0) for c in cells]
            off = len(strings)
            strings.extend(codes)
            rows[p * 32 + row] = (1 << 21) | (col << 15) | (len(codes) << 9) | off
    assert len(strings) <= 512
    return rows, strings


# ------------------------------------------------------------------ level (16 rows x 256 columns)
COLS, ROWS = 256, 16
GROUND_ROW = 13                                          # rows 13 and 14 are ground
FLAG_COL = 198


def build_level():
    m = [[T["SKY"]] * COLS for _ in range(ROWS)]

    def put(c, r, t):
        if 0 <= c < COLS and 0 <= r < ROWS:
            m[r][c] = t

    # Scenery first (non-solid), repeating every 48 columns like the classics.
    for base in range(0, COLS, 48):
        for i, name in enumerate(HILLS):
            if T[name] != T["SKY"]:
                put(base + i % 4, 10 + i // 4, T[name])                    # big hill
        for i, name in enumerate(HILLS[4:]):
            put(base + 16 + i % 4, 11 + i // 4, T[name])                   # small hill (lower 2 rows)
        for c0, r0 in [(8, 3), (19, 2), (27, 3), (36, 2)]:
            for i, name in enumerate(["CLOUD_TL", "CLOUD_TM", "CLOUD_TR", "CLOUD_BL", "CLOUD_BM", "CLOUD_BR"]):
                put(base + c0 + i % 3, r0 + i // 3, T[name])
        for c0 in (11, 23, 41):
            for i, name in enumerate(["BUSH_L", "BUSH_M", "BUSH_R"]):
                put(base + c0 + i, 12, T[name])

    # Ground with pits.
    pits = [(69, 71), (86, 89), (153, 155)]
    for c in range(COLS):
        if not any(a <= c < b for a, b in pits):
            put(c, 13, T["GROUND"])
            put(c, 14, T["GROUND"])
            for r in range(10, 13):
                if m[r][c] in (T["BUSH_L"], T["BUSH_M"], T["BUSH_R"]) and False:
                    pass
        else:
            for r in range(10, 13):
                m[r][c] = T["SKY"]                                        # no scenery over pits

    def pipe_at(c, h):
        for r in range(13 - h, 13):
            put(c, r, T["PIPE_TL"] if r == 13 - h else T["PIPE_L"])
            put(c + 1, r, T["PIPE_TR"] if r == 13 - h else T["PIPE_R"])

    def blocks(c, r, pattern):
        for i, ch in enumerate(pattern):
            if ch == "?":
                put(c + i, r, T["QBLOCK"])
            elif ch == "#":
                put(c + i, r, T["BRICK"])
            elif ch == "o":
                put(c + i, r, T["COIN"])

    def stairs_up(c, h):
        for i in range(h):
            for r in range(12 - i, 13):
                put(c + i, r, T["HARD"])

    def stairs_down(c, h):
        for i in range(h):
            for r in range(12 - (h - 1 - i), 13):
                put(c + i, r, T["HARD"])

    blocks(16, 9, "?")
    blocks(20, 9, "#?#?#")
    blocks(22, 5, "?")
    pipe_at(28, 2)
    pipe_at(38, 3)
    blocks(41, 8, "ooo")
    pipe_at(46, 4)
    pipe_at(57, 4)
    blocks(62, 9, "#?#")
    blocks(64, 5, "ooooo")
    blocks(77, 9, "#?#")
    blocks(80, 5, "########")
    blocks(91, 5, "###?")
    blocks(94, 9, "#")
    blocks(100, 9, "##")
    blocks(106, 9, "?  ?  ?")
    blocks(109, 5, "?")
    blocks(118, 9, "#")
    blocks(121, 5, "###")
    blocks(128, 5, "#??#")
    blocks(129, 9, "##")
    blocks(124, 8, "oooo")
    stairs_up(134, 4)
    stairs_down(140, 4)
    stairs_up(148, 4)
    put(152, 9, T["HARD"]); put(152, 10, T["HARD"]); put(152, 11, T["HARD"]); put(152, 12, T["HARD"])
    stairs_down(155, 4)
    pipe_at(165, 2)
    blocks(168, 9, "##?#")
    blocks(170, 5, "ooo")
    pipe_at(179, 2)
    stairs_up(181, 8)
    for r in range(5, 13):
        put(188, r, T["HARD"])

    # Flag and castle.
    put(FLAG_COL, 12, T["HARD"])
    for r in range(3, 12):
        put(FLAG_COL, r, T["POLE"])
    put(FLAG_COL, 2, T["POLE_TOP"])
    put(FLAG_COL - 1, 3, T["FLAG"])
    cx = 202
    for r in range(8, 13):
        for c in range(cx, cx + 5):
            put(c, r, T["CASTLE_BRICK"])
    for c in range(cx, cx + 5):
        put(c, 7, T["CASTLE_TOP"])
    for c in range(cx + 1, cx + 4):
        put(c, 5, T["CASTLE_TOP"])
        put(c, 6, T["CASTLE_BRICK"])
    put(cx + 2, 6, T["CASTLE_WINDOW"])
    put(cx + 2, 11, T["CASTLE_DOOR"])
    put(cx + 2, 12, T["CASTLE_DOOR"])

    spawns = [(22, 12), (40, 12), (51, 12), (53, 12), (80, 4), (82, 4), (97, 12), (99, 12), (107, 12),
              (114, 12), (116, 12), (124, 12), (126, 12), (128, 12), (130, 12), (174, 12), (176, 12)]
    return m, pits, spawns


# ------------------------------------------------------------------ outputs
def write_hex(name, values, digits):
    with open(name, "w") as f:
        f.write("\n".join(f"{v:0{digits}x}" for v in values) + "\n")


def rgb_hex(c):
    return (c[0] << 16) | (c[1] << 8) | c[2]


def main():
    tiles, slot_of = build_tiles()
    sprites = build_sprites()
    font = build_font()
    logo = build_logo()
    rows, strings = build_text()
    level, pits, spawns = build_level()

    palette = TILE_PAL + SPRITE_PAL + LOGO_PAL + [TEXT_WHITE, BLACK]
    palette += [(0, 0, 0)] * (64 - len(palette))
    write_hex("plat_palette.hex", [rgb_hex(c) for c in palette], 6)
    tile_px = [p for t in tiles for row in t for p in row]
    tile_px += [0] * (64 * 256 - len(tile_px))
    write_hex("plat_tiles.hex", tile_px, 1)
    write_hex("plat_slots.hex", [slot_of.get((tid, a), 0) for tid in range(64) for a in range(4)], 2)
    write_hex("plat_sprites.hex", [p for f in sprites for row in f for p in row], 1)
    write_hex("plat_font.hex", [b for g in font for b in g], 2)
    logo_px = [p for row in logo for p in row + [0] * (256 - LOGO_W)]                      # rows padded to 256
    write_hex("plat_logo.hex", logo_px + [0] * (16384 - len(logo_px)), 1)
    write_hex("plat_rows.hex", rows, 6)
    write_hex("plat_text.hex", strings + [0] * (512 - len(strings)), 2)
    write_hex("plat_level.hex", [level[r][c] for r in range(ROWS) for c in range(COLS)], 2)
    write_hex("plat_spawns.hex", [(c << 4) | r for c, r in spawns] + [0xFFF] * (32 - len(spawns)), 3)

    params = [
        "// Generated by platformer_gen.py - do not edit.",
        f"localparam LOGO_X = {LOGO_X}, LOGO_Y = {LOGO_Y}, LOGO_W = {LOGO_W}, LOGO_H = {LOGO_H};",
        f"localparam FLAG_X = {FLAG_COL * 16 + 4};",
        f"localparam SPAWNS = {len(spawns)};",
        "localparam [5:0] " + ", ".join(f"T_{k} = {v}" for k, v in T.items()) + ";",
        "localparam [5:0] " + ", ".join(f"C_{name} = {CODE[name]}" for name in DYN) + ";",
        f"localparam [5:0] C_DIGIT0 = {CODE['0']};",
        "localparam [3:0] " + ", ".join(f"F_{n.upper()} = {i}" for i, n in enumerate(SPRITE_FRAMES)) + ";",
        "localparam [5:0] P_TILE = 0, P_SPRITE = 16, P_LOGO = 32, P_TEXT = 36, P_BLACK = 37;",
        "localparam [2:0] " + ", ".join(f"PG_{n} = {i}" for i, n in enumerate(PAGES)) + ";",
    ]
    with open("plat_params.vh", "w") as f:
        f.write("\n".join(params) + "\n")

    # previews
    def tile_img(t, pal):
        im = Image.new("RGB", (16, 16))
        im.putdata([pal[p] for row in t for p in row])
        return im

    lv = Image.new("RGB", (COLS * 16, 15 * 16))
    for r in range(15):
        for c in range(COLS):
            lv.paste(tile_img(tiles[slot_of[(level[r][c], 0)]], TILE_PAL), (c * 16, r * 16))
    for c, r in spawns:
        s = tile_img(sprites[6], [(255, 0, 255)] + SPRITE_PAL[1:])
        mask = Image.new("L", (16, 16))
        mask.putdata([0 if p == 0 else 255 for row in sprites[6] for p in row])
        lv.paste(s, (c * 16, r * 16), mask)
    lv.save("plat_level.png")

    sheet = Image.new("RGB", (16 * 18, 16 * 8), (40, 40, 40))
    for i, t in enumerate(tiles):
        sheet.paste(tile_img(t, TILE_PAL), ((i % 16) * 18, (i // 16) * 18))
    for i, f in enumerate(sprites):
        sheet.paste(tile_img(f, [(0x6B, 0x8C, 0xFF)] + SPRITE_PAL[1:]), ((i % 16) * 18, 4 * 18 + (i // 16) * 18))
    lg = Image.new("RGB", (LOGO_W, LOGO_H))
    lg.putdata([(0x6B, 0x8C, 0xFF) if p == 0 else LOGO_PAL[p - 1] if p < 4 else (0, 0, 0) for row in logo for p in row])
    big = Image.new("RGB", (max(sheet.width, LOGO_W), sheet.height + LOGO_H + 4), (40, 40, 40))
    big.paste(sheet, (0, 0))
    big.paste(lg, (0, sheet.height + 4))
    big.resize((big.width * 3, big.height * 3), Image.NEAREST).save("plat_sheet.png")
    print(f"tiles {len(tiles)}/64, sprites {len(SPRITE_FRAMES)}/16, text {len(strings)}/512 chars, "
          f"{len(spawns)} enemies")


if __name__ == "__main__":
    main()
