#!/usr/bin/env python3
"""Generate the data files for terminal.v (NANO TERM).

  python3 term_gen.py [BAUD]

Writes, for $readmemh and `include:
  term_font.hex     512 glyphs x 16 rows, one byte per row (MSB = left)
  term_palette.hex  256 colours, rrggbb
  term_bars.hex     templates of the title bar and status bar, 160 words
  term_cells.hex    the initial screen: 62 rows x 80 cell words (boot screen and bars)
  term_uni.hex      symbol, zero-width and double-width code point ranges, scanned by the engine
  term_uni.vh       DEC graphics -> glyph and decimal functions, the shell's commands
  term_say.hex      what the built-in shell prints: help, clear, the error messages
  term_sbox.hex     the AES S-box and its inverse
  term_aes.hex      the AES unit's RAM at power-up: a default key's round keys and IV
  term_params.vh    constants shared with terminal.v
and term_font.png / term_boot.png previews.
"""
import re
import sys

import term_aes
import term_font as tf
import term_model as tm


CLK_HZ = 27_000_000
# Serial speeds the terminal detects by itself (see term_autobaud in terminal.v)
RATES = [9600, 19200, 38400, 57600, 115200, 230400, 460800, 1000000, 2000000, 3000000]


def rate_tables():
    """Verilog functions over a rate index: its bit timer period (1/16 clocks), its digits, the
    pulse width (clocks) below which a sender must be faster, and width -> rate."""
    bits = [CLK_HZ / r for r in RATES]
    lines = ['// Serial speeds, by index: ' + ', '.join(map(str, RATES)), f'localparam NUM_RATES = {len(RATES)};']
    assert CLK_HZ * 16 / RATES[0] < 65536
    lines += ['function [15:0] rate_period;', '    input [3:0] r;', '    case (r)']
    lines += [f"        4'd{i}: rate_period = 16'd{round(CLK_HZ * 16 / r)};" for i, r in enumerate(RATES)]
    lines += [f"        default: rate_period = 16'd{round(CLK_HZ * 16 / RATES[-1])};", '    endcase', 'endfunction']
    lines += ['function [27:0] rate_bcd;', '    input [3:0] r;', '    case (r)']
    lines += [f"        4'd{i}: rate_bcd = 28'h{r:07d};" for i, r in enumerate(RATES)]
    lines += [f"        default: rate_bcd = 28'h{RATES[-1]:07d};", '    endcase', 'endfunction']
    lines += ['function [15:0] rate_short;               // 0.7 of a bit (clocks)', '    input [3:0] r;', '    case (r)']
    lines += [f"        4'd{i}: rate_short = 16'd{int(0.7 * b)};" for i, b in enumerate(bits)]
    lines += [f"        default: rate_short = 16'd{int(0.7 * bits[-1])};", '    endcase', 'endfunction']
    lines += ['function [15:0] rate_quiet;               // 10 bits (clocks)', '    input [3:0] r;', '    case (r)']
    lines += [f"        4'd{i}: rate_quiet = 16'd{int(10 * b)};" for i, b in enumerate(bits)]
    lines += [f"        default: rate_quiet = 16'd{int(10 * bits[-1])};", '    endcase', 'endfunction']
    # a pulse shorter than rate_edge(k) means speed k or faster: geometric midpoints between
    # neighbouring bit times
    lines += ['function [15:0] rate_edge;', '    input [3:0] k;', '    case (k)']
    lines += [f"        4'd{i + 1}: rate_edge = 16'd{int((bits[i] * bits[i + 1]) ** 0.5)};" for i in range(len(RATES) - 1)]
    lines += ["        default: rate_edge = 16'd0;", '    endcase', 'endfunction']
    return lines


def write_hex(path, values, digits):
    with open(path, 'w') as f:
        f.write('\n'.join(f'{v:0{digits}x}' for v in values) + '\n')


# ------------------------------------------------------------------ boot screen
LOGO = {
    'N': '##....## ####..## ####..## ##.##.## ##.##.## ##..#### ##..#### ##...### ##....## ##....##',
    'A': '..####.. .##..##. ##....## ##....## ##....## ######## ##....## ##....## ##....## ##....##',
    'O': '.######. ##....## ##....## ##....## ##....## ##....## ##....## ##....## ##....## .######.',
    'T': '######## ######## ...##... ...##... ...##... ...##... ...##... ...##... ...##... ...##...',
    'E': '######## ##...... ##...... ##...... ######.. ##...... ##...... ##...... ##...... ########',
    'R': '#######. ##....## ##....## ##....## #######. ##..##.. ##...##. ##....## ##....## ##....##',
    'M': '##....## ###..### ######## ##.##.## ##....## ##....## ##....## ##....## ##....## ##....##',
}


def esc(s):
    return s.replace('^[', '\x1b')


def logo_ansi():
    """NANO TERM in 10-pixel-high letters with a drop shadow, drawn with half blocks."""
    w, h = 80, 12
    px = [[None] * w for _ in range(h)]
    x = 3
    marks = []
    for ch in 'NANO TERM':
        if ch == ' ':
            x += 5
            continue
        for r, line in enumerate(LOGO[ch].split()):
            for c, v in enumerate(line):
                if v == '#':
                    marks.append((x + c, r))
        x += 9
    for mx, my in marks:                             # shadow first, letters on top
        px[my + 1][mx + 1] = 'shadow'
    for mx, my in marks:
        px[my][mx] = 'ink'

    def colour(kind, cx, cy):
        if kind is None:
            return tm.BG0
        if kind == 'shadow':
            return 236
        t = min(1.0, max(0.0, (cx - 3) / 75))        # cyan -> blue -> magenta -> pink across the logo
        stops = [(0.0, (0, 230, 255)), (0.35, (70, 130, 255)), (0.7, (190, 90, 255)), (1.0, (255, 90, 200))]
        for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
            if t <= t1:
                k = (t - t0) / (t1 - t0)
                rgb = [round(a + (b - a) * k) for a, b in zip(c0, c1)]
                break
        if cy % 10 < 3:                              # a lighter top edge on each letter
            rgb = [min(255, c + 60) for c in rgb]
        return tf.rgb256(*rgb)

    out = ''
    for row in range(h // 2):
        for cx in range(w):
            top = colour(px[2 * row][cx], cx, 2 * row)
            bot = colour(px[2 * row + 1][cx], cx, 2 * row + 1)
            out += f'^[[38;5;{top};48;5;{bot}m▀'
        out += '^[[0m'
    return out


def visible(s):
    return len(re.sub(r'\^\[\[[0-9;]*m', '', s))


def boxes(left, right, width=36, gap=2):
    """Two boxes side by side: (title, [lines]) each, drawn with box-drawing characters."""
    dim, key, off = '^[[38;5;245m', '^[[38;5;221m', '^[[0m'
    rows = []
    for title, lines in (left, right):
        top = f'{dim}╭─{off} {key}{title}{off} {dim}' + '─' * (width - 5 - len(title)) + f'╮{off}'
        body = [f'{dim}│{off} ' + line + ' ' * (width - 3 - visible(line)) + f'{dim}│{off}' for line in lines]
        rows.append([top] + body + [f'{dim}╰' + '─' * (width - 2) + f'╯{off}'])
    return ['  ' + a + ' ' * gap + b for a, b in zip(*rows)]


def boot_ansi(baud):
    dim, hi, acc, key, off = '^[[38;5;245m', '^[[1;97m', '^[[38;5;81m', '^[[38;5;221m', '^[[0m'
    swatch = ''.join(f'^[[48;5;{i}m  ' for i in range(16)) + off + '  ' + \
        ''.join(f'^[[48;5;{c}m ' for c in (196, 202, 208, 214, 220, 226, 190, 154, 118, 82, 46, 47, 48, 49, 50,
                                            51, 45, 39, 33, 27, 21, 57, 93, 129, 165, 201, 199, 197)) + off
    grays = ''.join(f'^[[48;5;{232 + i}m ' for i in range(24)) + off
    lines = [
        '',
        logo_ansi(),
        f'  {dim}▸{off} {hi}Tang Nano 9K{off} {dim}·{off} GW1NR-9 FPGA {dim}·{off} 720×480 HDMI {dim}·{off} '
        f'80×28 cells {dim}·{off} {acc}xterm-256color{off}',
        '',
        f'  {swatch}',
        f'  {grays}  ^[[1mbold{off}  ^[[2mdim{off}  ^[[3mitalic{off}  ^[[4munderline{off}  '
        f'^[[9mstrike{off}  ^[[7mreverse{off}',
        '',
        f'  Send text to the board\'s serial port {acc}/dev/ttyUSB1{off}, at {key}any speed{off} to 3 Mbaud:',
        '',
        f'    {dim}${off} echo \'hello, world\' > /dev/ttyUSB1',
        f'    {dim}${off} minicom -D /dev/ttyUSB1       {dim}and type on this screen{off}',
        '',
        f'    {dim}${off} {acc}./nanoterm.py shell{off}   {dim}a live shell on this screen{off}',
        f'    {dim}${off} {acc}./nanoterm.py demo{off}    {dim}colours, boxes and braille graphics{off}',
        '',
    ] + boxes(('buttons', [f'{hi}S1{off}  theme: colour, green, amber', f'{hi}S2{off}  CRT scanlines']),
              ('speaks', ['UTF-8, VT100 and xterm escapes', 'box drawing ┼╬▒ and braille ⣿⡷'])) + [
        '',
        f'  Type {key}help{off} and press Enter, or {key}enc hello{off} to encrypt it with AES-128.',
        '$ ',
    ]
    return esc('\r\n'.join(lines))


def main():
    BAUD = int(sys.argv[1]) if len(sys.argv) > 1 else 2000000
    if BAUD not in RATES:
        raise SystemExit(f'the starting speed must be one of {RATES}')
    glyphs = tf.GLYPHS
    write_hex('term_font.hex', [b for g in glyphs for b in g], 2)
    write_hex('term_palette.hex', [r << 16 | g << 8 | b for r, g, b in tf.PALETTE], 6)
    templates = tm.bar_templates()
    write_hex('term_bars.hex', templates, 8)

    term = tm.Term()
    boot = boot_ansi(BAUD).encode()
    term.feed(boot)
    assert term.scrolls == 0, 'the boot screen must fit without scrolling'
    assert term.cx == 2, 'the boot screen ends at the shell prompt'
    assert (term.fg, term.bg, term.fl, term.inv, term.con) == (tm.FG0, tm.BG0, 0, False, False)
    bars = tm.default_bars(term, BAUD)
    cells = tm.physical(term, bars)
    write_hex('term_cells.hex', [w for row in cells for w in row], 8)

    with open('term_params.vh', 'w') as f:
        f.write('// Generated by term_gen.py\n')
        for name, value in (('BAUD', BAUD), ('INIT_RATE', RATES.index(BAUD)), ('INIT_CX', term.cx), ('INIT_CY', term.cy),
                            ('TITLE_COL', tm.TITLE_COL), ('TITLE_LEN', tm.TITLE_LEN),
                            ('G_REPLACEMENT', tf.REPLACEMENT), ('G_WIDE_R', tf.WIDE_R)):
            f.write(f'localparam {name} = {value};\n')
        text = b''
        for name in tm.SAY:                                           # 0-terminated strings
            f.write(f'localparam SAY_{name.upper()} = {len(text)};\n')
            text += tm.SAY[name] + b'\0'
        assert len(text) <= 2048
        write_hex('term_say.hex', list(text) + [0] * (2048 - len(text)), 2)
        title = templates[tm.TITLE_COL] & ~0x3FF & ~(7 << 29)       # the title cells' colours, no glyph
        f.write(f"localparam [31:0] TITLE_WORD = 32'h{title:08x};\n")
        f.write('\n'.join(rate_tables()) + '\n')
    write_uni()
    write_hex('term_sbox.hex', term_aes.SBOX + term_aes.INV_SBOX, 2)
    write_hex('term_aes.hex', aes_ram(), 2)

    font_sheet('term_font.png')
    tm.save_png(tm.render_term(term), 'term_boot.png')
    print(f'wrote term_*.hex, term_uni.vh, term_params.vh (boot screen cursor at {term.cy},{term.cx})')


def aes_ram():
    """term_aes's RAM at power-up: the round keys (0x700) and IV (0x7C0) of SP 800-38A's example."""
    ram = [0] * 2048
    ram[0x700:0x700 + 176] = term_aes.expand_key(term_aes.SP_KEY)
    ram[0x7C0:0x7C0 + 16] = term_aes.SP_IV
    return ram


def uni_table():
    """Code point ranges the engine scans for characters outside its direct ranges (Latin-1, box
    drawing, blocks, braille): symbols, zero-width and double-width characters, sorted, with a
    sentinel. Each entry is {lo[20:0], hi[20:0], width[1:0], glyph[9:0]}."""
    entries = [(cp, cp, 1, slot) for cp, slot in tf.MISC_SLOT.items() if cp >= 0x100]
    entries += [(lo, hi, 0, 0) for lo, hi in tf.ZERO_WIDTH]
    entries += [(lo, hi, 2, tf.WIDE_L) for lo, hi in tf.WIDE]
    entries.sort()
    for (lo0, hi0, _, _), (lo1, _, _, _) in zip(entries, entries[1:]):
        assert hi0 < lo1, f'overlapping ranges at {lo0:x}'
    entries.append((0x1FFFFF, 0x1FFFFF, 1, tf.REPLACEMENT))
    assert len(entries) <= 256
    for lo, hi, w, g in entries:            # the model must agree with the table
        for cp in {lo, hi}:
            assert tf.uni_glyph(cp) == (g if w else 0, w) or lo == 0x1FFFFF, hex(cp)
    return [lo << 33 | hi << 12 | w << 10 | g for lo, hi, w, g in entries]


def write_uni():
    table = uni_table()
    write_hex('term_uni.hex', table + [table[-1]] * (256 - len(table)), 14)
    lines = ['// Generated by term_gen.py', '',
             '// DEC special graphics (ESC ( 0): the glyph for bytes 0x5F-0x7E',
             'function [9:0] dec_glyph;', '    input [4:0] i;', '    begin', '        case (i)']
    for i in range(32):
        lines.append(f'            5\'d{i}: dec_glyph = 10\'h{tf.dec_glyph(0x5F + i):03X};')
    lines += ['            default: dec_glyph = 10\'h020;', '        endcase', '    end', 'endfunction', '',
              '// 0..99 -> two BCD digits', 'function [7:0] bcd;', '    input [6:0] v;', '    begin',
              '        case (v)']
    for v in range(100):
        lines.append(f'            7\'d{v}: bcd = 8\'h{v // 10}{v % 10};')
    lines += ['            default: bcd = 8\'h00;', '        endcase', '    end', 'endfunction', '']
    # the built-in shell's commands: letter i of command k, and the lengths
    lines += ['// the built-in shell\'s commands: ' + ', '.join(tm.COMMANDS),
              'function [7:0] cmd_char;', '    input [2:0] k;', '    input [2:0] i;', '    begin',
              '        case ({k, i})']
    for k, word in enumerate(tm.COMMANDS):
        for i, ch in enumerate(word):
            lines.append(f"            6'd{k * 8 + i}: cmd_char = \"{ch}\";")
    lines += ["            default: cmd_char = 8'h00;", '        endcase', '    end', 'endfunction',
              'function [2:0] cmd_len;', '    input [2:0] k;', '    case (k)']
    lines += [f"        3'd{k}: cmd_len = 3'd{len(w)};" for k, w in enumerate(tm.COMMANDS)]
    lines += ["        default: cmd_len = 3'd0;", '    endcase', 'endfunction', '']
    assert len(tm.COMMANDS) == 8 and max(map(len, tm.COMMANDS)) <= 7
    with open('term_uni.vh', 'w') as f:
        f.write('\n'.join(lines))


def font_sheet(path, scale=3):
    from PIL import Image
    cols = 32
    im = Image.new('RGB', (cols * 9 * scale, 24 * 17 * scale), (40, 40, 48))
    for g in range(0x300):
        ox, oy = (g % cols) * 9 * scale, (g // cols) * 17 * scale
        rows = tf.glyph_rows(g)
        for y in range(16):
            for x in range(8):
                on = rows[y] >> (7 - x) & 1
                c = (230, 235, 240) if on else (12, 15, 20)
                for dy in range(scale):
                    for dx in range(scale):
                        im.putpixel((ox + x * scale + dx, oy + y * scale + dy), c)
    im.save(path)


if __name__ == '__main__':
    main()
