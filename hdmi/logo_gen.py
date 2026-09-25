#!/usr/bin/env python3
"""Render the bouncing-logo bitmap for logo.v.

Output logo.hex: LOGO_W x LOGO_H pixels, row-major, one hex digit per line giving
4-bit coverage (0 = background, 15 = solid) for $readmemh. Edges are anti-aliased
by drawing at SS x resolution and averaging down.
Also writes logo_preview.png (3x scale) to eyeball the result.
"""
from PIL import Image, ImageDraw, ImageFont

LOGO_W, LOGO_H = 192, 96          # must match logo.v
SS = 4                            # supersampling factor
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"


def fitted_font(draw, text, max_w, max_h):
    """Largest font size whose rendered text fits in max_w x max_h."""
    for size in range(max_h * 2, 4, -1):
        font = ImageFont.truetype(FONT, size)
        l, t, r, b = draw.textbbox((0, 0), text, font=font)
        if r - l <= max_w and b - t <= max_h:
            return font
    raise ValueError(f"cannot fit {text!r}")


def draw_centered(draw, text, box, fill):
    x0, y0, x1, y1 = box
    font = fitted_font(draw, text, x1 - x0, y1 - y0)
    l, t, r, b = draw.textbbox((0, 0), text, font=font)
    draw.text((x0 + (x1 - x0 - (r - l)) // 2 - l, y0 + (y1 - y0 - (b - t)) // 2 - t),
              text, font=font, fill=fill)


def main():
    W, H = LOGO_W * SS, LOGO_H * SS
    img = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(img)

    # "TANG NANO" across the top, a disc underneath with "9K" cut out of it.
    draw_centered(d, "TANG NANO", (4 * SS, 6 * SS, W - 4 * SS, 42 * SS), 255)
    disc = (22 * SS, 52 * SS, W - 22 * SS, 90 * SS)
    d.ellipse(disc, fill=255)
    draw_centered(d, "9K", (disc[0], disc[1] + 7 * SS, disc[2], disc[3] - 7 * SS), 0)

    small = img.resize((LOGO_W, LOGO_H), Image.BOX)
    levels = [round(v * 15 / 255) for v in small.tobytes()]

    with open("logo.hex", "w") as f:
        f.write("\n".join(f"{v:x}" for v in levels) + "\n")

    preview = Image.new("L", (LOGO_W, LOGO_H))
    preview.putdata([v * 17 for v in levels])
    preview.resize((LOGO_W * 3, LOGO_H * 3), Image.NEAREST).save("logo_preview.png")

    solid = sum(v == 15 for v in levels)
    edge = sum(0 < v < 15 for v in levels)
    print(f"logo.hex: {LOGO_W}x{LOGO_H}, {solid} solid + {edge} anti-aliased pixels")


if __name__ == "__main__":
    main()
