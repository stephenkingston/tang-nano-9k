#!/usr/bin/env python3
"""Host side of NANO TERM: talk to the Tang Nano 9K terminal over its USB serial port.

  ./nanoterm.py shell            run your shell on the HDMI screen, typed from this keyboard
  ./nanoterm.py type             type at the board's built-in shell (sums like 5 + 5; Ctrl-] quits)
  ./nanoterm.py demo             an animated demo: dashboard, colours, braille plots, rain
  ./nanoterm.py send [FILE]      send a file (or stdin) as it is
  ./nanoterm.py check [FILE...]  test the board: stream test data (and any recorded sessions) and
                                 compare the screen checksums the FPGA reports with the Python model

Options: --port (default /dev/ttyUSB1), --baud (default 2000000; the board follows any speed
from 9600 to 3000000). Only the Python standard library is needed (Linux or macOS).
"""
import argparse
import math
import os
import pty
import random
import select
import signal
import struct
import sys
import termios
import time
import tty

COLS, ROWS = 80, 28
E = '\x1b'
SHELL = f'{E}[?2112h'                                  # back to the board's built-in shell


def open_port(path, baud):
    # The board's USB bridge (a BL702 posing as an FTDI chip) switches to a new baud rate only
    # when the port is next opened, so set it, close, and open again.
    os.close(configure(os.open(path, os.O_RDWR | os.O_NOCTTY), baud))
    return configure(os.open(path, os.O_RDWR | os.O_NOCTTY), baud)


def configure(fd, baud):
    attrs = termios.tcgetattr(fd)
    speed = getattr(termios, f'B{baud}', None)
    if speed is None:
        raise SystemExit(f'unsupported baud rate {baud}')
    attrs[0] = 0                                        # iflag: raw
    attrs[1] = 0                                        # oflag: no newline translation
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[3] = 0                                        # lflag: no echo, no signals
    attrs[4] = attrs[5] = speed
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def write_all(fd, data):
    view = memoryview(data)
    while view:
        _, w, _ = select.select([], [fd], [])
        n = os.write(fd, view)
        view = view[n:]


# ------------------------------------------------------------------ shell
def shell(port, args):
    """Run a shell in an 80x28 pty: keys from here go to it, its output goes to the board."""
    pid, master = pty.fork()
    if pid == 0:
        os.environ.update(TERM='xterm-256color', COLUMNS=str(COLS), LINES=str(ROWS), NANOTERM='1')
        cmd = args.command or [os.environ.get('SHELL', '/bin/sh')]
        os.execvp(cmd[0], cmd)
    import fcntl
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))
    stdin = sys.stdin.fileno()
    old = termios.tcgetattr(stdin) if os.isatty(stdin) else None
    if old:
        tty.setraw(stdin)
    write_all(port, f'{E}c{E}]0;{os.environ.get("USER", "")} shell\x07'.encode())
    try:
        while True:
            r, _, _ = select.select([master, stdin, port], [], [])
            if master in r:
                try:
                    data = os.read(master, 4096)
                except OSError:
                    break
                if not data:
                    break
                write_all(port, data)
                if args.mirror:
                    os.write(sys.stdout.fileno(), data)
            if stdin in r:
                data = os.read(stdin, 1024)
                if not data:
                    break
                os.write(master, data)
            if port in r:
                data = os.read(port, 1024)              # reports from the terminal (cursor position ...)
                if data:
                    os.write(master, data)
    finally:
        if old:
            termios.tcsetattr(stdin, termios.TCSADRAIN, old)
        try:
            os.kill(pid, signal.SIGHUP)
        except ProcessLookupError:
            pass
    write_all(port, f'\r\n{E}[0m{E}]0;NANO TERM\x07[shell ended]{SHELL}'.encode())


def typewriter(port, args):
    """Keys go straight to the board's built-in shell, as minicom would send them."""
    stdin = sys.stdin.fileno()
    old = termios.tcgetattr(stdin)
    tty.setraw(stdin)
    print('typing at the board\'s shell on the HDMI screen: Ctrl-] quits\r')
    write_all(port, SHELL.encode())
    try:
        while True:
            r, _, _ = select.select([stdin, port], [], [])
            if port in r:
                os.read(port, 1024)                     # the board has nothing to say here
            if stdin in r:
                keys = os.read(stdin, 1024)
                if b'\x1d' in keys:
                    break
                write_all(port, keys)
    finally:
        termios.tcsetattr(stdin, termios.TCSADRAIN, old)


# ------------------------------------------------------------------ demo
def at(row, col, text=''):
    return f'{E}[{row};{col}H{text}'


def fg(c):
    return f'{E}[38;5;{c}m'


def bg(c):
    return f'{E}[48;5;{c}m'


RST = f'{E}[0m'


def box(row, col, h, w, title, colour=67):
    out = at(row, col, fg(colour) + '╭─ ' + fg(222) + title + fg(colour) + ' ' + '─' * (w - 5 - len(title)) + '╮')
    for r in range(row + 1, row + h - 1):
        out += at(r, col, '│') + at(r, col + w - 1, '│')
    return out + at(row + h - 1, col, '╰' + '─' * (w - 2) + '╯') + RST


def braille_plot(width, height, funcs):
    """Plot functions of x in [0, 1) into a width x height grid of braille cells, one colour each."""
    dots = [[0] * width for _ in range(height)]
    owner = [[None] * width for _ in range(height)]
    bits = ((0x01, 0x08), (0x02, 0x10), (0x04, 0x20), (0x40, 0x80))
    for k, f in enumerate(funcs):
        for px in range(width * 2):
            v = f(px / (width * 2))
            py = int((1 - (v + 1) / 2) * (height * 4 - 1) + 0.5)
            if 0 <= py < height * 4:
                cx, cy = px // 2, py // 4
                dots[cy][cx] |= bits[py % 4][px % 2]
                owner[cy][cx] = k
    return dots, owner


def demo(port, args):
    colours = [81, 213, 221]
    rnd = random.Random(1)
    write = lambda s: write_all(port, s.encode())
    write(f'{E}c{E}[?25l{E}]0;NANO TERM demo\x07')
    t0 = time.time()
    scene_time = 30
    try:
        while True:
            scene = int((time.time() - t0) // scene_time) % 3
            if scene == 0:
                dashboard(write, rnd, colours, t0, scene_time, args.baud // 10)
            elif scene == 1:
                palette(write)
                time.sleep(4)
                gradients(write)
                time.sleep(scene_time - 4)
            else:
                rain(write, rnd, scene_time)
    except KeyboardInterrupt:
        write(f'{RST}{E}[?25h{E}c{SHELL}')


def dashboard(write, rnd, colours, t0, seconds, rate):
    write(f'{RST}{E}[2J' + box(1, 1, 12, 52, 'signals') + box(1, 54, 12, 27, 'load') +
          box(13, 1, 9, 40, 'bytes/s') + box(13, 42, 9, 39, 'log') + box(22, 1, 7, 80, 'about'))
    write(at(23, 3, fg(250) + 'An 80x28 terminal drawn by an FPGA, with no CPU and no frame buffer: every') +
          at(24, 3, 'pixel is computed as the HDMI beam scans. Text arrives over the USB serial') +
          at(25, 3, 'port and is parsed in hardware, escapes and UTF-8 and all.  ' + fg(81) + 'Tang Nano 9K') +
          at(26, 3, fg(245) + 'Braille ⣿ packs 2x4 dots in a cell; eighths ▁▂▃▄▅▆▇█ and ▏▎▍▌ make meters.') + RST)
    hist = [0] * 36
    log = []
    loads = [0.3, 0.5, 0.7, 0.2]
    start = time.time()
    frame = 0
    while time.time() - start < seconds:
        t = time.time() - t0
        dots, owner = braille_plot(50, 10, [lambda x: math.sin(2 * math.pi * (x * 2 + t * 0.3)),
                                            lambda x: 0.6 * math.sin(2 * math.pi * (x * 3 - t * 0.5)) *
                                            math.cos(2 * math.pi * x),
                                            lambda x: math.exp(-((x - (t * 0.1) % 1) * 8) ** 2) * 1.6 - 0.8])
        out = ''
        for r in range(10):
            out += at(2 + r, 2)
            last = None
            for c in range(50):
                k = owner[r][c]
                colour = colours[k] if k is not None else 238
                if colour != last:
                    out += fg(colour)
                    last = colour
                out += chr(0x2800 + dots[r][c]) if dots[r][c] else ' '
        for i in range(4):
            loads[i] = min(1.0, max(0.02, loads[i] + rnd.uniform(-0.15, 0.15)))
            n = loads[i] * 13
            bar = '█' * int(n) + (' ▏▎▍▌▋▊▉'[int((n % 1) * 8)] if n < 13 else '')
            colour = 114 if loads[i] < 0.6 else 221 if loads[i] < 0.85 else 203
            out += at(3 + 2 * i, 56, fg(245) + f'cpu{i} ' + fg(colour) + bar.ljust(13) + fg(250) +
                      f' {int(loads[i] * 100):3d}%')
        hist = hist[1:] + [max(0.0, min(1.0, 0.5 + 0.4 * math.sin(t * 1.3) + rnd.uniform(-0.2, 0.2)))]
        out += at(14, 3, fg(81) + ''.join(' ▁▂▃▄▅▆▇█'[int(h * 8)] for h in hist))
        for r in range(4):
            out += at(15 + r, 3, fg(81 if r < 3 else 67) + ''.join(
                '█' if h * 5 > 4 - r else '▄' if h * 5 > 3.5 - r else ' ' for h in hist))
        out += at(19, 3, fg(245) + f'peak {int(max(hist) * rate):6d} B/s   now {int(hist[-1] * rate):6d} B/s')
        if frame % 8 == 0:
            words = ['boot', 'scroll', 'glyph', 'braille', 'utf-8', 'sgr', 'csi', 'hdmi', 'tmds', 'uart']
            log = (log + [(time.strftime('%H:%M:%S'), rnd.choice(['ok', 'ok', 'ok', 'warn']),
                           ' '.join(rnd.sample(words, 3)))])[-6:]
            for i, (ts, lvl, msg) in enumerate(log):
                out += at(14 + i, 44, fg(245) + ts + ' ' + (fg(114) + ' ok ' if lvl == 'ok' else fg(221) + 'warn') +
                          fg(250) + ' ' + msg.ljust(20))
        out += at(1, 64, fg(245) + '┤ ' + fg(222) + time.strftime('%H:%M:%S') + fg(245) + ' ├') + RST
        write(out)
        frame += 1
        time.sleep(0.05)


def palette(write):
    out = f'{RST}{E}[2J' + at(1, 3, fg(222) + '256 colours' + RST)
    for i in range(16):
        out += at(3, 3 + i * 4, bg(i) + fg(15 if i in (0, 8) else 0) + f' {i:2d} ' + RST)
    for g in range(6):
        for r in range(6):
            for b in range(6):
                c = 16 + 36 * r + 6 * g + b
                out += at(5 + g, 3 + r * 13 + b * 2, bg(c) + '  ')
    out += RST
    for i in range(24):
        out += at(12, 3 + i * 3, bg(232 + i) + '   ')
    write(out + RST)


def gradients(write):
    out = at(14, 3, fg(222) + 'truecolour (rounded to 256)' + RST)
    for row in range(10):
        out += at(16 + row, 3)
        for col in range(76):
            h = col / 76 * 6
            f = h - int(h)
            v = 1 - row / 12
            rgb = [(1, f, 0), (1 - f, 1, 0), (0, 1, f), (0, 1 - f, 1), (f, 0, 1), (1, 0, 1 - f)][int(h) % 6]
            r, g, b = [int(255 * v * c) for c in rgb]
            out += f'{E}[48;2;{r};{g};{b}m '
        out += RST
    write(out)


def rain(write, rnd, seconds):
    write(f'{RST}{E}[2J{E}]0;wake up\x07')
    drops = [rnd.randint(-28, 0) for _ in range(COLS)]
    speed = [rnd.choice([1, 1, 2]) for _ in range(COLS)]
    chars = '01234567890abcdef$#%&*+=<>λπ░▒▓'
    start = time.time()
    while time.time() - start < seconds:
        out = ''
        for x in range(COLS):
            if rnd.random() < 0.5:
                continue
            y = drops[x]
            if 0 <= y < ROWS:
                out += at(y + 1, x + 1, f'{E}[1;97m' + rnd.choice(chars))
            if 1 <= y <= ROWS:
                out += at(y, x + 1, f'{E}[0;32m' + rnd.choice(chars))
            if 0 <= y - 10 < ROWS:
                out += at(y - 9, x + 1, ' ')
            drops[x] += speed[x]
            if drops[x] - 10 > ROWS:
                drops[x] = rnd.randint(-10, 0)
        write(out + RST)
        time.sleep(0.04)


# ------------------------------------------------------------------ send / check
def send(port, args):
    data = open(args.file, 'rb').read() if args.file else sys.stdin.buffer.read()
    write_all(port, data)
    termios.tcdrain(port)


def dump_diff(got, want):
    """Where the board's screen dump (CSI 998 n) differs from the model's, row by row."""
    def dump(reply):
        k = reply.rfind(b'\x1b[?999;')
        return reply[k - ROWS * COLS:k] if k >= ROWS * COLS else None
    g, w = dump(got), dump(want)
    if g is None or w is None:
        return [f'     board: {got[-60:]!r}', f'     model: {want[-60:]!r}']
    text = lambda cells: ''.join(chr(c) if 32 <= c < 127 else '\u00b7' for c in cells)
    report = lambda reply: reply[reply.rfind(b'\x1b[?999;'):]
    lines = [f'     board: {report(got)!r}  model: {report(want)!r}']
    for r in range(ROWS):
        a, b = g[r * COLS:(r + 1) * COLS], w[r * COLS:(r + 1) * COLS]
        if a != b:
            lines += [f'     row {r + 1:2} board |{text(a)}|', f'            model |{text(b)}|']
    return lines


def check(port, args):
    """Stream test data at full speed and compare the FPGA's screen with the model's: after each
    part of the feature stream, and at the end of the shell session and each random stream, the
    board sends every cell (CSI 998 n) and its checksum report."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import term_model as tm
    import term_test
    rng = random.Random(args.seed)
    streams = [('features', term_test.features(split=True)),
               ('shell', [b'\x1b[?2112h' + term_test.shell_session()])] + \
              [(f'fuzz-{i}', [term_test.fuzz(rng, 1500)]) for i in range(args.count)] + \
              [(os.path.basename(f), [open(f, 'rb').read()]) for f in args.files]
    failed = 0
    for name, parts in streams:
        model = tm.Term()
        model.feed(b'\x1bc')
        write_all(port, b'\x1bc')
        t, size = time.time(), 0
        for i, part in enumerate(parts):
            data = part.replace(b'\x1b[999n', b'').replace(b'\x1b[998n', b'') + b'\x1b[998n'
            model.out = bytearray()
            model.feed(data)
            want = bytes(model.out)
            termios.tcflush(port, termios.TCIFLUSH)
            write_all(port, data)
            size += len(data)
            got = b''
            end = time.time() + 5 + (len(data) + len(want)) * 10 / args.baud
            while time.time() < end and len(got) < len(want):
                r, _, _ = select.select([port], [], [], 0.1)
                if r:
                    got += os.read(port, 4096)
            if got != want:
                break
        ok = got == want
        failed += not ok
        where = '' if ok or len(parts) == 1 else f' (part {i + 1} of {len(parts)})'
        print(f'{"ok  " if ok else "FAIL"} {name}{where}: {size} bytes in {time.time() - t:.2f} s')
        if not ok:
            print('\n'.join(dump_diff(got, want)))
    write_all(port, f'{E}c{SHELL}'.encode())            # leave the board at its shell prompt
    print('all checks passed' if not failed else f'{failed} checks failed')
    return failed == 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--port', default='/dev/ttyUSB1')
    ap.add_argument('--baud', type=int, default=2000000)
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('shell', help='run a shell (or COMMAND) on the screen')
    p.add_argument('--mirror', action='store_true', help='also show the output here')
    p.add_argument('command', nargs=argparse.REMAINDER)
    sub.add_parser('type', help='type straight onto the screen')
    sub.add_parser('demo', help='animated demo')
    p = sub.add_parser('send', help='send a file or stdin')
    p.add_argument('file', nargs='?')
    p = sub.add_parser('check', help='compare the board with the model')
    p.add_argument('--count', type=int, default=4, help='random streams')
    p.add_argument('--seed', type=int, default=7)
    p.add_argument('files', nargs='*', help='recorded sessions to replay as well')
    args = ap.parse_args()
    port = open_port(args.port, args.baud)
    if args.cmd == 'check':
        sys.exit(0 if check(port, args) else 1)
    {'shell': shell, 'type': typewriter, 'demo': demo, 'send': send}[args.cmd](port, args)


if __name__ == '__main__':
    main()
