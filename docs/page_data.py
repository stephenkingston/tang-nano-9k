#!/usr/bin/env python3
"""Refresh the NANO QUEST data embedded in docs/index.html (the explainer page).

Runs hdmi/platformer/platformer_gen.py in a temporary folder and copies the tiles,
sprites, font, text, palette and level it writes into the page's <script id="game-data">
block, so the page's interactive parts always match the hardware. Run it after changing
the art or the level:

  python3 docs/page_data.py
"""
import json
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
GEN = ROOT / "hdmi" / "platformer" / "platformer_gen.py"
PAGE = ROOT / "docs" / "index.html"


def main():
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run([sys.executable, str(GEN)], cwd=tmp, check=True, stdout=subprocess.DEVNULL)

        def hexfile(name):
            text = pathlib.Path(tmp, f"plat_{name}.hex").read_text()
            return [int(line.split("//")[0], 16) for line in text.splitlines() if line.split("//")[0].strip()]

        def nibbles(values):
            return "".join(f"{v:x}" for v in values)

        params = pathlib.Path(tmp, "plat_params.vh").read_text()
        consts = {m[0]: int(m[1]) for m in re.findall(r"\b([A-Z][A-Z0-9_]*) = (\d+)", params)}

        def group(prefix):
            return {k[len(prefix):]: v for k, v in consts.items() if k.startswith(prefix)}

        sys.path.insert(0, str(GEN.parent))
        import platformer_gen

        spawns = hexfile("spawns")[:consts["SPAWNS"]]
        data = {
            "palette": [f"{v:06x}" for v in hexfile("palette")],
            "tiles": nibbles(hexfile("tiles")),
            "slots": hexfile("slots"),
            "sprites": nibbles(hexfile("sprites")),
            "font": "".join(f"{v:02x}" for v in hexfile("font")),
            "rows": hexfile("rows"),
            "text": hexfile("text"),
            "level": "".join(f"{v:02x}" for v in hexfile("level")),
            "spawns": [[s >> 4, s & 15] for s in spawns],
            "flagX": consts["FLAG_X"],
            "T": group("T_"),
            "F": group("F_"),
            "C": group("C_"),
            "P": group("P_"),
            "PG": group("PG_"),
            "artKey": "".join(sorted(platformer_gen.SK, key=platformer_gen.SK.get)),
        }

    page = PAGE.read_text()
    block = json.dumps(data, separators=(",", ":"))
    new, n = re.subn(r'(<script id="game-data" type="application/json">).*?(</script>)',
                     lambda m: m[1] + block + m[2], page, count=1, flags=re.S)
    if n != 1:
        raise SystemExit("game-data block not found in " + str(PAGE))
    PAGE.write_text(new)
    print(f"updated {PAGE.relative_to(ROOT)}: {len(block)} bytes of game data")


if __name__ == "__main__":
    main()
