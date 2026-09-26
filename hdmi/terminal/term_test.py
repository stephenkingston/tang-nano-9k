#!/usr/bin/env python3
"""Check terminal.v against the Python model (term_model.py) in Icarus Verilog.

  python3 term_test.py [--fuzz N] [--seed S] [--keep] [capture.bin ...]

Each test stream is fed to the terminal engine in simulation and to the model; the screen,
the cursor and modes, the title and status bars and every byte sent back must match. Streams:
  features   every supported control, escape and CSI sequence, with screen checksums along the way
  fuzz-N     random mixes of text, UTF-8 (valid and broken), controls and escape sequences
  captures   any files given on the command line (e.g. recorded with `script`)
The serial port is tested at the bit level: a sender changes speed (57600 to 3000000 baud,
some with its clock 2.5% off) and the terminal must follow it, losing only the first few bytes. Then a few frames are rendered by term_render and compared pixel for pixel with the model's
renderer, in each colour theme and with the CRT look, and saved as PNGs (term_frame_*.png).
Needs iverilog, and the files from term_gen.py.
"""
import argparse
import os
import random
import re
import subprocess
import sys

import term_font as tf
import term_gen
import term_model as tm

SIM = 'tb_core.vvp'


def params():
    text = open('term_params.vh').read()
    return {k: int(v) for k, v in re.findall(r'localparam (\w+) = (\d+);', text)}


def boot_term():
    """The model in the state the FPGA starts in: after the boot screen, nothing to repeat."""
    t = tm.Term()
    t.feed(term_gen.boot_ansi(params()['BAUD']).encode())
    t.last = None
    t.out = bytearray()
    t.local, t.prow, t.last_cr = True, t.cy, False           # the built-in shell is up
    return t


def compile_sim():
    subprocess.run(['iverilog', '-g2005', '-I.', '-s', 'term_core_tb', '-o', SIM, 'term_core_tb.v', 'terminal.v'],
                   check=True)
    subprocess.run(['iverilog', '-g2005', '-I.', '-s', 'term_frame_tb', '-o', 'tb_frame.vvp', 'term_frame_tb.v',
                    'terminal.v'], check=True)


def uart_tests():
    subprocess.run(['iverilog', '-g2005', '-I.', '-s', 'term_uart_tb', '-o', 'tb_uart.vvp', 'term_uart_tb.v',
                    'terminal.v'], check=True)
    out = subprocess.run(['vvp', '-n', 'tb_uart.vvp'], capture_output=True, text=True).stdout
    lines = [l for l in out.splitlines() if l.startswith(('ok', 'FAIL'))]
    print('\n'.join(lines) if lines else 'FAIL uart: no result')
    return bool(lines) and not any(l.startswith('FAIL') for l in lines) and 'transmit' in lines[-1]


def frame_test(name, state, **settings):
    """Render the cell memory left by the last run_sim with term_render and with the model."""
    words = [int(line, 16) for line in open('tb_ram.hex') if line.strip()]
    cells = [words[r * 80:(r + 1) * 80] for r in range(62)]
    rowmap = words[4960:4988]
    st = {'cx': state['cx'], 'cy': state['cy'], 'cursor': state['tcem'], 'style': state['cur_style'],
          'scnm': state['scnm'], 'blink_off': 0, 'bell': 0, 'theme': 0, 'crt': 0}
    st.update(settings)
    args = [f'+{k}={int(v)}' for k, v in st.items()] + [f'+bank={state["bank"]}']
    subprocess.run(['vvp', '-n', 'tb_frame.vvp'] + args, check=True, capture_output=True)
    got = [int(line, 16) for line in open('tb_frame.hex') if line.strip()]
    want = tm.render(cells, rowmap, state['bank'], st)
    flat = [r << 16 | g << 8 | b for line in want for r, g, b in line]
    w, h = tm.W, tm.H
    if len(got) != w * h:
        print(f'FAIL frame {name}: {len(got)} pixels')
        return False
    img = [[((v >> 16) & 255, (v >> 8) & 255, v & 255) for v in got[y * w:(y + 1) * w]] for y in range(h)]
    tm.save_png(img, f'term_frame_{name}.png')
    bad = [i for i in range(w * h) if got[i] != flat[i]]
    if bad:
        print(f'FAIL frame {name}: {len(bad)} pixels differ' + (f', first at x={bad[0] % w} y={bad[0] // w}: '
              f'verilog {got[bad[0]]:06x} model {flat[bad[0]]:06x}' if bad else f', {len(got)} pixels'))
        return False
    print(f'ok   frame {name}: {w * h} pixels match ({", ".join(f"{k}={v}" for k, v in settings.items())})')
    return True


def run_sim(data, gaps=False):
    with open('tb_stream.hex', 'w') as f:
        f.write('\n'.join(f'{b:02x}' for b in data) + '\n')
    r = subprocess.run(['vvp', '-n', SIM, f'+len={len(data)}', f'+gaps={int(gaps)}'], capture_output=True, text=True)
    if 'FAIL' in r.stdout or r.returncode:
        raise SystemExit(r.stdout + r.stderr)

    def words(path):
        return [int(line, 16) for line in open(path) if line.strip()]
    state = dict(line.split() for line in open('tb_state.txt'))
    return {'screen': words('tb_screen.hex'), 'bars': words('tb_bars.hex'),
            'replies': bytes(words('tb_replies.hex')), 'state': {k: int(v) for k, v in state.items()}}


def expected(term):
    templates = tm.bar_templates()
    st = {'cx': term.cx, 'cy': term.cy, 'rx': 12345, 'hours': 1, 'minutes': 59, 'seconds': 7, 'baud': 460800,
          'spark': [(0x86420135 >> 4 * i) & 15 for i in range(8)], 'active': True, 'theme': 2,
          'title_custom': term.title_custom, 'title': term.title}
    state = {'cx': term.cx, 'cy': term.cy, 'wrap': int(term.wrap), 'bank': term.bank, 'tcem': int(term.tcem),
             'cur_style': term.cur_style, 'cur_blink': int(term.cur_blink), 'scnm': int(term.scnm),
             'title_custom': int(term.title_custom), 'top': term.top, 'bot': term.bot, 'awm': int(term.awm),
             'irm': int(term.irm), 'lnm': int(term.lnm), 'fg': term.fg, 'bg': term.bg, 'fl': term.fl,
             'inv': int(term.inv), 'con': int(term.con), 'g0': term.g[0], 'g1': term.g[1], 'gl': term.gl,
             'pst': term.state, 'local': int(term.local), 'prow': term.prow,
             'themes': term.switches.count('theme'), 'crts': term.switches.count('crt')}
    return {'screen': [w for row in term.scr for w in row],
            'bars': tm.bar_cells(templates[:80], st) + tm.bar_cells(templates[80:], st),
            'replies': bytes(term.out), 'state': state}


def describe(w):
    g, fg, bg, fl = tm.unpack(w)
    ch = chr(g) if 0x20 <= g < 0x7F else f'#{g:03x}'
    return f'{ch!r} fg={fg} bg={bg} fl={fl:02x}'


def compare(name, got, want):
    errors = []
    for k in want['state']:
        if got['state'][k] != want['state'][k]:
            errors.append(f'{k}: verilog {got["state"][k]}, model {want["state"][k]}')
    for i, (a, b) in enumerate(zip(got['screen'], want['screen'])):
        if a != b:
            errors.append(f'cell row {i // 80} col {i % 80}: verilog {describe(a)}, model {describe(b)}')
            if len(errors) > 12:
                break
    for i, (a, b) in enumerate(zip(got['bars'], want['bars'])):
        if a != b:
            errors.append(f'{"title" if i < 80 else "status"} bar col {i % 80}: verilog {describe(a)}, '
                          f'model {describe(b)}')
            if len(errors) > 20:
                break
    if got['replies'] != want['replies']:
        errors.append(f'replies: verilog {got["replies"]!r}\n           model   {want["replies"]!r}')
    if errors:
        print(f'FAIL {name}')
        for e in errors[:25]:
            print('   ', e)
        return False
    return True


# ------------------------------------------------------------------ test streams
def features(split=False):
    """The feature stream, or with split=True its parts (for checking the board part by part)."""
    E = '\x1b'
    parts = [
        # text, wrapping, controls
        f'{E}[H{E}[2Jhello, world\r\nline two\ttab\tstops\b\bBS\r\n',
        'x' * 85 + '\r\n' + 'y' * 80 + 'Z\r\n',
        f'{E}[?7l' + 'n' * 90 + f'{E}[?7h\r\n',
        f'{E}[20h1\n2\n{E}[20l3\n4\r\n',
        # cursor movement
        f'{E}[5;10HA{E}[2AB{E}[3BC{E}[4CD{E}[2DE{E}[2EF{E}[1FG{E}[30GH{E}[99;99HI{E}[H',
        f'{E}[10d{E}[5`J{E}[3aK{E}[2eL{E}[fM{E}[3IN{E}[2ZO{E}[9999;0HP',
        f'{E}[0;0H{E}[999A{E}[999D{E}[999B{E}[999C{E}[H',
        # erasing
        f'{E}[3;1H' + 'abcdefghij' * 8 + f'{E}[3;20H{E}[K{E}[4;1H' + 'klmnop' * 5 + f'{E}[4;10H{E}[1K',
        f'{E}[5;1H' + 'qrstuv' * 5 + f'{E}[5;5H{E}[2K{E}[6;1H' + '0123456789' * 3 + f'{E}[6;5H{E}[4X{E}[6;25H{E}[99X',
        f'{E}[41m{E}[8;30H{E}[J{E}[10;10H{E}[1J{E}[0m{E}[999n',
        # insert / delete characters and lines, insert mode
        f'{E}[H{E}[2J{E}[2;1H' + 'ABCDEFGHIJ' * 8 + f'{E}[2;5H{E}[3@{E}[2;20H{E}[5P{E}[2;79H{E}[9@{E}[2;1H{E}[200P',
        f'{E}[3;1H' + 'insert mode' + f'{E}[3;3H{E}[4hXY{E}[4l' + '中' + f'{E}[3;78H{E}[4h文字{E}[4l',
        ''.join(f'{E}[{r};1Hrow {r}' for r in range(1, 29)) + f'{E}[10;1H{E}[3L{E}[20;1H{E}[2M{E}[27;1H{E}[9M',
        f'{E}[999n{E}[5;20r{E}[20;1H\n\n\n{E}[5;1H{E}M{E}M{E}[2S{E}[3T{E}[4;1HL{E}[5;1H{E}[99L{E}[r{E}[998n',
        f'{E}[3;6r{E}[6;1H\n\n{E}[3;1H{E}M{E}[1;1H{E}M{E}[28;1H\n{E}[r',
        # tabs and REP
        f'{E}[H{E}[2J\tA\t\tB{E}[4IC{E}[9ID{E}[2ZE{E}[20ZF\r\n=-{E}[5b\r\n{E}[b{E}[1000b',
        # SGR
        f'\r\n{E}[1mbold{E}[2mdim{E}[22m{E}[3mital{E}[23m{E}[4mul{E}[24m{E}[5mbl{E}[25m{E}[7minv{E}[27m'
        f'{E}[8mcon{E}[28m{E}[9mstrike{E}[29m{E}[21mdu{E}[0m',
        ''.join(f'{E}[{c}m{c}' for c in list(range(30, 38)) + list(range(40, 48)) + list(range(90, 98)) +
                list(range(100, 108))) + f'{E}[39;49m',
        f'{E}[38;5;196mr{E}[48;5;21mb{E}[38;5;300mX{E}[38;2;255;128;0mo{E}[48;2;40;44;52mg{E}[38;2;10;10;12mk'
        f'{E}[38;2;250;250;250mw{E}[38;2;300;0;0mR{E}[38;7;1mq{E}[48;9;1m{E}[1;31;42;4mmix{E}[m{E}[;1mb{E}[m',
        f'{E}[1;33mbright{E}[7m inv {E}[8mhidden{E}[0m{E}[38;5;4;1mB{E}[0m{E}[1;7;31mbr{E}[0m',
        # charsets
        f'\r\n{E}(0lqqqk\r\nx   x\r\nmqqqj{E}(B plain {E})0\x0eaaa\x0f back{E})B\r\n',
        f'{E}(0' + ''.join(chr(c) for c in range(0x5F, 0x7F)) + f'{E}(B\r\n',
        # UTF-8
        '\r\ncafé naïve Ünïcödé ½ ° ± × — “quotes” … ✓ ✗ ➜ ❯ λ π €\r\n',
        '╭─┬─╮│ ┃ ╞═╪═╡ ╔╗╚╝ ┏━┓ ┗━┛ ░▒▓█ ▁▂▃▄▅▆▇ ▏▎▍▌ ⣿⡀⠁⢸ ■□▲▶●○◆  \r\n',
        '宽字符 😀 emoji 👍🏽 é a​b ️ x\U0001F600y\r\n',
        '\xe2\x94 broken \xc3 \xff \xbf \xe2\x94\x80 ok',
        'x' * 79 + '中文\r\n',
        # OSC titles and strings that must be ignored
        f'{E}]0;my title\x07{E}]2;second title{E}\\{E}]1;icon only\x07{E}]52;c;aGVsbG8=\x07',
        f'{E}]0;{"t" * 70}\x07{E}]7;file://host/dir\x07{E}P+q544e\x1b\\{E}_apc\x07{E}^pm{E}\\{E}Xsos\x07after',
        # modes: cursor, screen reverse, alternate screen, saved cursor
        f'{E}[?25l{E}[?12l{E}[3 q{E}[?5h{E}[?5l{E}[?25h{E}[?12h{E}[6 q{E}[0 q',
        f'{E}[12;40Hsaved{E}7{E}[1;1Hmoved{E}8here{E}[s{E}[20;20H{E}[u!',
        f'{E}[31mmain{E}[?1049h{E}[44malt screen{E}[5;5Hin alt{E}[2;3r{E}[?1049l after alt{E}[0m',
        f'{E}[?47hA47{E}[?47l{E}[?1047hB{E}[?1047l{E}[?1049h{E}[?1049h{E}[?1049l{E}[?1049l{E}[?1048h{E}[5;5H'
        f'{E}[?1048l{E}[?25;1049h{E}[?1049;25l',
        f'{E}[?1049h' + ''.join(f'{E}[{r};1Halt {r}' for r in range(1, 29)) + '\n\n\n' + f'{E}[?1049l',
        # reports
        f'{E}[5n{E}[6n{E}[10;20H{E}[6n{E}[c{E}[0c{E}[>c{E}[?6n{E}[28;80H{E}[6n{E}[999n',
        # parser edge cases
        f'{E}[1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;16;17;18m{E}[99999999999H{E}[?1;2;3$p{E}[=5h{E}[<1m',
        f'{E}[1\x0a2H{E}[3\x18A{E}[4\x1aB{E}[5\x1b[6H{E}#8{E}[2;2H{E}(A{E}%G{E} F{E}=x{E}>y',
        f'{E}[?1;25;7h{E}[>4;1m{E}[?1h{E}[1 q{E}[2 q{E}[4 q{E}[5 q{E}[7 q{E}[!p{E}[2$~{E}[1:2:3m',
        f'\x07\x00\x05\x7f{E}\x7f{E}[\x7fA',
        f'\r\nabcd\x7f\x7fXY\x7f\r\n' + 'w' * 80 + '\x7f\x7f!\r\x7f\x7f{E}[41m q\x7f{E}[0m\r\n',
        # DECSTR, then a full reset and more text
        f'{E}[31;1m{E}[5;10r{E}[?25l{E}[!pafter soft reset{E}[999n{E}c',
        f'fresh screen{E}[999n{E}]0;title again\x07{E}c{E}[5;5Hdone',
    ]
    return [p.encode() for p in parts] if split else ''.join(parts).encode()


def shell_session():
    """Typing at the built-in shell: sums, rubbing out, keys it ignores, leaving and coming back."""
    E = '\x1b'
    keys = ['5 + 5\r', '12-20\r', '\r', '-7 + 3 - 1\r\n', 'abc\r', '5 +\r', '4 4\r', '2147483647+1\r',
            '99\x7f7\r', '\x08\x08\x08\x08x\r', '1+2+3+4+5+6+7+8+9+10\r', '4294967295 + 2\r', '0\r',
            '-0\r', '+5\r', '- - 5\r', '12\x08\x083\r', f'8{E}[D{E}[C{E}[A{E}[B{E}[3~{E}[2~+1\r',
            'x' * 90 + '\r', '7$+$3\r', '5 + 5\n', '6 + 6\n\n', '0012 - 012\r', '1000000000+2000000000\r',
            '\t3\t+\t4\r', 'é+1\r', '9' * 12 + '\r', f'{E}[31mnow a program is talking\r\n', 'plain 1+1\r\n',
            f'{E}[?2112h', '1+1\r', f'{E}c', '2+2\r', f'{E}[?2112h', '3+3\r', f'{E}[?2112l', '4+4\r',
            f'{E}[?25;2112h', '\r' * 30, 'q' * 200 + '\r', '40 + 2\r',
            'help\r', '  help  \r', 'help me\r', 'hel\r', 'helpp\r', 'HELP\r', 'theme\r', 'crt\r', 'crt\r',
            'clearx\r', 'the me\r', 'theme\x08\x08\x08\x08\x08crt\r', 'hello\r', '12 + 30 - 5\r', 'clear\r',
            '7-8\r', f'help{E}[D\r', 'clear  \r', 'help\r', 'help\r', 'help\r', 'help\r']
    return ''.join(keys).encode()


def fuzz(rng, n):
    E = b'\x1b'
    finals = b'@ABCDEFGHIJKLMPSTXZ`abcdefhlmnqrsu' + b'gtxyz'
    utf8 = ['é', 'ß', '─', '│', '┼', '═', '█', '▄', '⣿', '中', '😀', '́', '​', '✓', '€', '', 'λ']
    out = bytearray()
    for i in range(n):
        k = rng.random()
        if k < 0.25:
            out += bytes(rng.choice(range(0x20, 0x7F)) for _ in range(rng.randint(1, 30)))
        elif k < 0.33:
            out += rng.choice(utf8).encode()
        elif k < 0.40:
            out += bytes([rng.choice([7, 8, 9, 10, 11, 12, 13, 14, 15, 0, 5])])
        elif k < 0.70:
            ps = [str(rng.choice([0, 1, 2, 3, 4, 5, 7, 9, 10, 20, 27, 28, 30, 40, 79, 80, 81, 200, 4000]))
                  for _ in range(rng.randint(0, 3))]
            if rng.random() < 0.1:
                ps = [str(rng.randint(0, 99999))]
            final = bytes([rng.choice(finals)])
            priv = rng.choice([b'', b'', b'', b'?', b'>'])
            if priv == b'?':
                ps = [str(rng.choice([1, 5, 7, 12, 25, 47, 1047, 1048, 1049, 2004]))]
                final = rng.choice([b'h', b'l'])
            out += E + b'[' + priv + ';'.join(ps).encode() + final
        elif k < 0.80:
            codes = []
            for _ in range(rng.randint(1, 4)):
                c = rng.choice([0, 1, 2, 3, 4, 5, 7, 8, 9, 22, 23, 24, 27, 31, 39, 42, 49, 93, 104, 38, 48])
                codes.append(str(c))
                if c in (38, 48):
                    if rng.random() < 0.5:
                        codes += ['5', str(rng.randint(0, 260))]
                    else:
                        codes += ['2'] + [str(rng.randint(0, 260)) for _ in range(3)]
            out += E + b'[' + ';'.join(codes).encode() + b'm'
        elif k < 0.86:
            out += E + bytes([rng.choice(b'78DEMc=>')]) if rng.random() < 0.95 else E + b'c'
        elif k < 0.89:
            out += E + rng.choice([b'(0', b'(B', b')0', b')B', b'#8']) + (b'\x0e' if rng.random() < 0.2 else b'')
            out += bytes(rng.choice(range(0x5F, 0x7F)) for _ in range(rng.randint(0, 5))) + b'\x0f'
        elif k < 0.92:
            out += E + b']' + rng.choice([b'0', b'2', b'1', b'']) + b';' + \
                bytes(rng.choice(range(0x20, 0x7F)) for _ in range(rng.randint(0, 60))) + \
                rng.choice([b'\x07', E + b'\\'])
        elif k < 0.95:
            r1 = rng.randint(0, 30)
            out += E + b'[%d;%dr' % (r1, rng.randint(0, 30))
        elif k < 0.97:
            out += bytes([rng.randint(0, 255) for _ in range(rng.randint(1, 4))])
        else:
            out += E + b'[999n'
    return bytes(out) + E + b'[999n'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--fuzz', type=int, default=6, help='number of random streams')
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--keep', action='store_true', help='keep going after a failure')
    ap.add_argument('captures', nargs='*')
    args = ap.parse_args()

    compile_sim()
    tests = [('features', features(), False), ('features (slow input)', features(), True),
             ('shell', shell_session(), False)]
    rng = random.Random(args.seed)
    for i in range(args.fuzz):
        tests.append((f'fuzz-{i}', fuzz(rng, 1500), i % 2 == 1))
    for path in args.captures:
        tests.append((os.path.basename(path), open(path, 'rb').read(), False))

    ok = True
    for name, data, gaps in tests:
        term = boot_term()
        term.feed(data)
        good = compare(name, run_sim(data, gaps), expected(term))
        if good:
            print(f'ok   {name}: {len(data)} bytes, {len(term.out)} reply bytes, {term.scrolls} scrolls')
        ok &= good
        if not good and not args.keep:
            break
    if ok:
        ok &= uart_tests()
    if ok:
        frames = [('boot', b'', {}),
                  ('features', features(), {'crt': 1, 'style': 1}),
                  ('green', features(), {'theme': 1, 'crt': 1, 'scnm': 1, 'bell': 1, 'blink_off': 1, 'style': 2}),
                  ('amber', fuzz(random.Random(5), 400), {'theme': 2})]
        for name, data, settings in frames:
            got = run_sim(data)
            ok &= frame_test(name, got['state'], **settings)
            if not ok and not args.keep:
                break
    if not ok:
        sys.exit(1)
    print('all terminal tests passed')


if __name__ == '__main__':
    main()
