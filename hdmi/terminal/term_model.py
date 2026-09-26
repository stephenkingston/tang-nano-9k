#!/usr/bin/env python3
"""Reference model of NANO TERM (terminal.v): the terminal emulator and the renderer.

The Verilog must leave exactly the same screen as this model for any byte stream (the
simulations check this), and must draw exactly the frames `render` draws. Render an ANSI
file to a PNG preview with:

  python3 term_model.py some.ans out.png
"""
import sys

import term_font as tf

COLS, ROWS = 80, 28                 # the terminal area; the screen has a title and a status bar too
TITLE_COL, TITLE_LEN = 8, 54        # where OSC window titles go in the title bar
BAR_TITLE, BAR_STATUS = 60, 61      # physical screen rows holding the two bars

# Cell word: glyph[9:0] fg[17:10] bg[25:18] bold dim italic underline blink strike
BOLD, DIM, ITALIC, UNDERLINE, BLINK, STRIKE = 1, 2, 4, 8, 16, 32
FG0, BG0 = 7, 0                     # default colours


def word(glyph, fg=FG0, bg=BG0, flags=0):
    return glyph | fg << 10 | bg << 18 | flags << 26


def unpack(w):
    return w & 0x3FF, (w >> 10) & 255, (w >> 18) & 255, (w >> 26) & 63


GROUND, ESC, ESC_INT, CSI, CSI_IGNORE, OSC, OSC_ESC, STR, STR_ESC = range(9)


class Term:
    def __init__(self):
        self.screens = [[[self.blank_word(0)] * COLS for _ in range(ROWS)] for _ in range(2)]
        self.out = bytearray()          # bytes the terminal sends back (reports)
        self.scrolls = 0
        self.bells = 0
        # the built-in shell (see local_key): its prompt row, whether the last byte typed was a
        # carriage return, and what it has still to print
        self.prow = 0
        self.last_cr = False
        self.saying = False
        self.pending = b''
        self.switches = []              # theme and crt commands, which the display carries out
        self.reset()

    # ---------------------------------------------------------------- state
    def reset(self):
        """Power-on state, also what ESC c (RIS) restores; clears the main screen."""
        self.cx = self.cy = 0
        self.wrap = False
        self.sgr_reset()
        self.top, self.bot = 0, ROWS - 1
        self.awm, self.irm, self.lnm, self.tcem, self.scnm = True, False, False, True, False
        self.cur_style, self.cur_blink = 0, True       # 0 block, 1 underline, 2 bar
        self.g = [0, 0]                                # G0/G1: 0 ASCII, 1 DEC graphics
        self.gl = 0
        self.bank = 0
        self.saved = [self.cursor_state(0, 0, True) for _ in range(2)]
        self.last = None
        self.state = GROUND
        self.need = self.cp = 0
        self.title_custom = False
        self.title = []
        self.local = False              # the built-in shell is up (it is at power-up)
        self.screens[0] = [[self.blank_word(0)] * COLS for _ in range(ROWS)]

    def sgr_reset(self):
        self.fg, self.bg, self.fl, self.inv, self.con = FG0, BG0, 0, False, False

    def cursor_state(self, cx=None, cy=None, default=False):
        if default:
            return (cx, cy, FG0, BG0, 0, False, False, 0, 0, 0)
        return (self.cx, self.cy, self.fg, self.bg, self.fl, self.inv, self.con, self.g[0], self.g[1], self.gl)

    def save_cursor(self, slot=None):
        self.saved[self.bank if slot is None else slot] = self.cursor_state()

    def restore_cursor(self, slot=None):
        (self.cx, self.cy, self.fg, self.bg, self.fl, self.inv, self.con,
         self.g[0], self.g[1], self.gl) = self.saved[self.bank if slot is None else slot]
        self.wrap = False

    @property
    def scr(self):
        return self.screens[self.bank]

    def blank_word(self, bg=None):
        return word(0x20, FG0, self.bg if bg is None else bg)

    def pen(self, glyph):
        f, b = self.fg, self.bg
        if self.fl & BOLD and f < 8:
            f += 8
        if self.inv:
            f, b = b, f
        if self.con:
            f = b
        return word(glyph, f, b, self.fl)

    # ---------------------------------------------------------------- screen operations
    def scroll_up(self, top, bot, n):
        for _ in range(n):
            row = self.scr.pop(top)
            self.scr.insert(bot, [self.blank_word()] * COLS)
            self.scrolls += 1

    def scroll_down(self, top, bot, n):
        for _ in range(n):
            self.scr.pop(bot)
            self.scr.insert(top, [self.blank_word()] * COLS)
            self.scrolls += 1

    def erase(self, r0, c0, r1, c1, w=None):
        """Blank from (r0, c0) to (r1, c1) inclusive, in reading order."""
        w = self.blank_word() if w is None else w
        for r in range(r0, r1 + 1):
            for c in range(c0 if r == r0 else 0, (c1 if r == r1 else COLS - 1) + 1):
                self.scr[r][c] = w

    def index(self):
        if self.cy == self.bot:
            self.scroll_up(self.top, self.bot, 1)
        elif self.cy < ROWS - 1:
            self.cy += 1

    def rindex(self):
        if self.cy == self.top:
            self.scroll_down(self.top, self.bot, 1)
        elif self.cy > 0:
            self.cy -= 1

    def insert_chars(self, n):
        row = self.scr[self.cy]
        n = min(n, COLS - self.cx)
        row[self.cx + n:] = row[self.cx:COLS - n]
        row[self.cx:self.cx + n] = [self.blank_word()] * n

    def delete_chars(self, n):
        row = self.scr[self.cy]
        n = min(n, COLS - self.cx)
        row[self.cx:COLS - n] = row[self.cx + n:]
        row[COLS - n:] = [self.blank_word()] * n

    def rubout(self):
        """DEL, which terminals usually ignore, rubs out the character before the cursor: it is
        what a keyboard's Backspace sends when typing straight at the terminal (minicom)."""
        if self.wrap:
            self.wrap = False
        elif self.cx > 0:
            self.cx -= 1
        else:
            return
        self.scr[self.cy][self.cx] = self.blank_word()

    def put(self, glyph, width):
        if self.wrap:
            self.cx = 0
            self.index()
            self.wrap = False
        if width == 2 and self.cx == COLS - 1:
            if not self.awm:
                return
            self.cx = 0
            self.index()
        if self.irm:
            self.insert_chars(width)
        self.scr[self.cy][self.cx] = self.pen(glyph)
        if width == 2:
            self.scr[self.cy][self.cx + 1] = self.pen(tf.WIDE_R)
        self.last = (glyph, width)
        if self.cx + width <= COLS - 1:
            self.cx += width
        else:
            self.cx = COLS - 1
            self.wrap = self.awm

    def switch_screen(self, on, save):
        if on and self.bank == 0:
            if save:
                self.save_cursor(0)
            self.bank = 1
            self.screens[1] = [[self.blank_word()] * COLS for _ in range(ROWS)]
        elif not on and self.bank == 1:
            self.bank = 0
            if save:
                self.restore_cursor(0)

    def checksum(self):
        s = 0
        for row in self.scr:
            for w in row:
                s = ((s << 1 | s >> 31) & 0xFFFFFFFF) ^ w          # rotate left, then XOR
        return s

    # ---------------------------------------------------------------- the parser
    def feed(self, data):
        for b in data:
            self.byte(b)
            while self.pending:                         # what the shell prints, as if received
                text, self.pending = self.pending, b''
                self.saying = True
                for c in text:
                    self.byte(c)
                self.saying = False
                self.prow = self.cy

    # ---------------------------------------------------------------- the built-in shell
    # At power-up the terminal is a tiny shell for typing at it directly (from minicom, say):
    # a "$ " prompt, Backspace (BS or DEL) rubs out, and Enter runs the line: one of COMMANDS,
    # or a sum like 5 + 5 or 7 - 12 (32-bit integers), whose value is printed on the next line.
    # Arrow and editing keys are ignored. Any other escape sequence means a program is driving
    # the terminal, and the shell steps aside until CSI ? 2112 h (or S1 held down) brings it back.
    def local_key(self, b, was_cr):
        """A key typed at the shell: True if the shell dealt with it."""
        if b in (0x08, 0x7F):
            if self.cy != self.prow or self.cx > 2:     # not into the prompt
                self.rubout()
            return True
        if b == 0x0D or (b == 0x0A and not was_cr):
            row = self.scr[self.cy]
            word, v = command(row), evaluate(row)
            if word in ('help', 'clear'):
                self.pending += SAY[word] + b'$ '
            elif word:                                  # theme, crt: the display does those
                self.switches.append(word)
                self.pending += b'\r\n$ '
            elif v is not None:
                self.pending += b'\r\n%d\r\n$ ' % v
            elif all((w & 0x3FF) in BLANKS for w in row):
                self.pending += b'\r\n$ '
            else:
                self.pending += SAY['unknown'] + b'$ '
            return True
        return b == 0x0A                                # the line feed after a carriage return

    def control(self, b):
        if b == 0x07:
            self.bells += 1
        elif b == 0x08:
            self.wrap = False
            self.cx = max(self.cx - 1, 0)
        elif b == 0x09:
            self.wrap = False
            self.cx = min(COLS - 1, (self.cx | 7) + 1)
        elif b in (0x0A, 0x0B, 0x0C):
            self.wrap = False
            if self.lnm:
                self.cx = 0
            self.index()
        elif b == 0x0D:
            self.wrap = False
            self.cx = 0
        elif b == 0x0E:
            self.gl = 1
        elif b == 0x0F:
            self.gl = 0

    def byte(self, b):
        st = self.state
        if st == GROUND:
            if self.need:
                if 0x80 <= b < 0xC0:
                    self.cp = self.cp << 6 | (b & 0x3F)
                    self.need -= 1
                    if self.need == 0:
                        glyph, width = tf.uni_glyph(self.cp)
                        if width:
                            self.put(glyph, width)
                    return
                self.need = 0
            if not self.saying:
                was_cr, self.last_cr = self.last_cr, b == 0x0D
                if self.local and self.local_key(b, was_cr):
                    return
            if b < 0x20:
                if b == 0x1B:
                    self.state = ESC
                else:
                    self.control(b)
            elif b < 0x7F:
                glyph = tf.dec_glyph(b) if self.g[self.gl] and b >= 0x5F else b
                self.put(glyph, 1)
            elif b == 0x7F:
                self.rubout()
            elif b < 0xC0 or b >= 0xF8:
                self.put(tf.REPLACEMENT, 1)
            elif b < 0xE0:
                self.need, self.cp = 1, b & 0x1F
            elif b < 0xF0:
                self.need, self.cp = 2, b & 0x0F
            else:
                self.need, self.cp = 3, b & 0x07
            return

        # every other state: ESC restarts, CAN and SUB abort, other C0 controls still work
        if st not in (OSC, STR):
            if b == 0x1B:
                self.state = ESC
                return
            if b in (0x18, 0x1A):
                self.state = GROUND
                return
            if b < 0x20 and st not in (OSC_ESC, STR_ESC):
                self.control(b)
                return

        if st == ESC:
            self.state = GROUND
            if self.local and not self.saying and b != ord('['):
                self.local = False                      # a program is driving the terminal
            if 0x20 <= b < 0x30:
                self.inter, self.state = b, ESC_INT
            elif b == ord('['):
                self.params, self.np, self.ovf, self.priv, self.inter, self.fresh = [0] * 16, 0, False, 0, 0, True
                self.state = CSI
            elif b == ord(']'):
                self.osc_num, self.osc_phase = 0, 0
                self.state = OSC
            elif b in b'PX^_':
                self.state = STR
            elif b == ord('7'):
                self.save_cursor()
            elif b == ord('8'):
                self.restore_cursor()
            elif b == ord('D'):
                self.wrap = False
                self.index()
            elif b == ord('E'):
                self.wrap = False
                self.cx = 0
                self.index()
            elif b == ord('M'):
                self.wrap = False
                self.rindex()
            elif b == ord('c'):
                self.reset()
        elif st == ESC_INT:
            if 0x20 <= b < 0x30:
                self.inter = b
            elif 0x30 <= b < 0x7F:
                self.state = GROUND
                if self.inter == ord('('):
                    self.g[0] = int(b == ord('0'))
                elif self.inter == ord(')'):
                    self.g[1] = int(b == ord('0'))
                elif self.inter == ord('#') and b == ord('8'):
                    self.top, self.bot = 0, ROWS - 1
                    self.cx = self.cy = 0
                    self.wrap = False
                    self.erase(0, 0, ROWS - 1, COLS - 1, word(ord('E')))
        elif st == CSI:
            fresh, self.fresh = self.fresh, False
            if 0x30 <= b <= 0x39:
                if not self.ovf:
                    self.params[self.np] = min(4095, self.params[self.np] * 10 + b - 0x30)
            elif b in (0x3A, 0x3B):
                if self.np < 15:
                    self.np += 1
                else:
                    self.ovf = True
            elif 0x3C <= b <= 0x3F:
                if fresh:
                    self.priv = b
                else:
                    self.state = CSI_IGNORE
            elif 0x20 <= b < 0x30:
                self.inter = b
            elif 0x40 <= b < 0x7F:
                self.state = GROUND
                if self.local and not self.saying:
                    if not self.inter and not self.priv and chr(b) in 'ABCD~':
                        return                          # an arrow or editing key typed at the shell
                    self.local = False
                self.csi(b)
        elif st == CSI_IGNORE:
            if 0x40 <= b < 0x7F:
                self.state = GROUND
        elif st == OSC:
            if b == 0x07 or b in (0x18, 0x1A):
                self.state = GROUND
            elif b == 0x1B:
                self.state = OSC_ESC
            elif self.osc_phase == 0:
                if 0x30 <= b <= 0x39:
                    self.osc_num = min(255, self.osc_num * 10 + b - 0x30)
                elif b == 0x3B and self.osc_num in (0, 2):
                    self.title_custom, self.title, self.osc_phase = True, [], 1
                else:
                    self.osc_phase = 2
            elif self.osc_phase == 1 and 0x20 <= b < 0x7F and len(self.title) < TITLE_LEN:
                self.title.append(b)
        elif st == STR:
            if b == 0x07 or b in (0x18, 0x1A):
                self.state = GROUND
            elif b == 0x1B:
                self.state = STR_ESC
        elif st in (OSC_ESC, STR_ESC):
            self.state = GROUND

    def P(self, i):
        return self.params[i] if i <= self.np else 0

    def N(self, i):
        return max(1, self.P(i))

    def csi(self, f):
        f = chr(f)
        if self.inter:
            if self.inter == 0x20 and f == 'q' and not self.priv:
                v = self.P(0)
                if v <= 6:
                    self.cur_style = (0, 0, 0, 1, 1, 2, 2)[v]
                    self.cur_blink = v in (0, 1, 3, 5)
            elif self.inter == 0x21 and f == 'p':          # DECSTR soft reset
                self.tcem, self.irm, self.awm = True, False, True
                self.top, self.bot = 0, ROWS - 1
                self.sgr_reset()
                self.g, self.gl = [0, 0], 0
                self.saved[self.bank] = self.cursor_state(0, 0, True)
                self.wrap = False
            return
        if self.priv == 0x3F:
            if f in 'hl':
                for i in range(self.np + 1):
                    self.decset(self.P(i), f == 'h')
            return
        if self.priv:
            return
        n = self.N(0)
        if f in '@ABCDEFGHIJKLMPSTXZ`adefru':
            self.wrap = False
        if f == '@':
            self.insert_chars(n)
        elif f == 'A':
            self.cy = max(self.top, self.cy - n) if self.cy >= self.top else max(0, self.cy - n)
        elif f in 'Be':
            self.cy = min(self.bot, self.cy + n) if self.cy <= self.bot else min(ROWS - 1, self.cy + n)
        elif f in 'Ca':
            self.cx = min(COLS - 1, self.cx + n)
        elif f == 'D':
            self.cx = max(0, self.cx - n)
        elif f == 'E':
            self.cy = min(self.bot, self.cy + n) if self.cy <= self.bot else min(ROWS - 1, self.cy + n)
            self.cx = 0
        elif f == 'F':
            self.cy = max(self.top, self.cy - n) if self.cy >= self.top else max(0, self.cy - n)
            self.cx = 0
        elif f in 'G`':
            self.cx = min(COLS - 1, n - 1)
        elif f in 'Hf':
            self.cy = min(ROWS - 1, n - 1)
            self.cx = min(COLS - 1, self.N(1) - 1)
        elif f == 'I':
            for _ in range(min(n, 10)):
                self.cx = min(COLS - 1, (self.cx | 7) + 1)
        elif f == 'Z':
            for _ in range(min(n, 10)):
                self.cx = 0 if self.cx == 0 else (self.cx - 1) & ~7
        elif f == 'J':
            if self.P(0) == 0:
                self.erase(self.cy, self.cx, ROWS - 1, COLS - 1)
            elif self.P(0) == 1:
                self.erase(0, 0, self.cy, self.cx)
            elif self.P(0) in (2, 3):
                self.erase(0, 0, ROWS - 1, COLS - 1)
        elif f == 'K':
            if self.P(0) == 0:
                self.erase(self.cy, self.cx, self.cy, COLS - 1)
            elif self.P(0) == 1:
                self.erase(self.cy, 0, self.cy, self.cx)
            elif self.P(0) == 2:
                self.erase(self.cy, 0, self.cy, COLS - 1)
        elif f in 'LM':
            if self.top <= self.cy <= self.bot:
                k = min(n, self.bot - self.cy + 1)
                (self.scroll_down if f == 'L' else self.scroll_up)(self.cy, self.bot, k)
                self.cx = 0
        elif f == 'P':
            self.delete_chars(n)
        elif f == 'S':
            self.scroll_up(self.top, self.bot, min(n, self.bot - self.top + 1))
        elif f == 'T':
            if self.np == 0:
                self.scroll_down(self.top, self.bot, min(n, self.bot - self.top + 1))
        elif f == 'X':
            self.erase(self.cy, self.cx, self.cy, min(COLS - 1, self.cx + n - 1))
        elif f == 'b':
            if self.last:
                for _ in range(n):
                    self.put(*self.last)
        elif f == 'c':
            if self.P(0) == 0:
                self.out += b'\x1b[?1;2c'
        elif f == 'd':
            self.cy = min(ROWS - 1, n - 1)
        elif f in 'hl':
            for i in range(self.np + 1):
                if self.P(i) == 4:
                    self.irm = f == 'h'
                elif self.P(i) == 20:
                    self.lnm = f == 'h'
        elif f == 'm':
            self.sgr()
        elif f == 'n':
            if self.P(0) == 5:
                self.out += b'\x1b[0n'
            elif self.P(0) == 6:
                self.out += b'\x1b[%d;%dR' % (self.cy + 1, self.cx + 1)
            elif self.P(0) in (998, 999):
                if self.P(0) == 998:                        # every cell's glyph byte first
                    self.out += bytes(w & 0xFF for row in self.scr for w in row)
                self.out += b'\x1b[?999;%d;%d;%08xn' % (self.cy + 1, self.cx + 1, self.checksum())
        elif f == 'r':
            t = self.N(0) - 1
            b = (ROWS if self.P(1) == 0 else min(ROWS, self.P(1))) - 1
            if t < b:
                self.top, self.bot = t, b
                self.cx = self.cy = 0
        elif f == 's':
            if self.np == 0:
                self.save_cursor()
        elif f == 'u':
            self.restore_cursor()

    def decset(self, m, on):
        if m == 5:
            self.scnm = on
        elif m == 7:
            self.awm = on
            if not on:
                self.wrap = False
        elif m == 12:
            self.cur_blink = on
        elif m == 25:
            self.tcem = on
        elif m in (47, 1047):
            self.switch_screen(on, False)
        elif m == 1048:
            self.save_cursor() if on else self.restore_cursor()
        elif m == 1049:
            self.switch_screen(on, True)
        elif m == 2112:                                 # the built-in shell
            self.local = on
            if on:
                self.pending += b'\r\n$ '

    def sgr(self):
        mode = 0
        r = g = 0
        for i in range(self.np + 1):
            v = self.P(i)
            c = min(v, 255)
            if mode == 0:
                if v == 0:
                    self.sgr_reset()
                elif 1 <= v <= 9 and v != 7 and v != 8:
                    self.fl |= {1: BOLD, 2: DIM, 3: ITALIC, 4: UNDERLINE, 5: BLINK, 6: BLINK, 9: STRIKE}[v]
                elif v == 7:
                    self.inv = True
                elif v == 8:
                    self.con = True
                elif v == 21:
                    self.fl |= UNDERLINE
                elif v == 22:
                    self.fl &= ~(BOLD | DIM)
                elif v in (23, 24, 25, 29):
                    self.fl &= ~{23: ITALIC, 24: UNDERLINE, 25: BLINK, 29: STRIKE}[v]
                elif v == 27:
                    self.inv = False
                elif v == 28:
                    self.con = False
                elif 30 <= v <= 37:
                    self.fg = v - 30
                elif v == 38:
                    mode = 1
                elif v == 39:
                    self.fg = FG0
                elif 40 <= v <= 47:
                    self.bg = v - 40
                elif v == 48:
                    mode = 2
                elif v == 49:
                    self.bg = BG0
                elif 90 <= v <= 97:
                    self.fg = v - 82
                elif 100 <= v <= 107:
                    self.bg = v - 92
            elif mode in (1, 2):
                mode = {5: mode + 2, 2: 5 if mode == 1 else 8}.get(v, 0)
            elif mode == 3:
                self.fg, mode = c, 0
            elif mode == 4:
                self.bg, mode = c, 0
            elif mode in (5, 8):
                r, mode = c, mode + 1
            elif mode in (6, 9):
                g, mode = c, mode + 1
            elif mode == 7:
                self.fg, mode = tf.rgb256(r, g, c), 0
            elif mode == 10:
                self.bg, mode = tf.rgb256(r, g, c), 0


# the built-in shell's commands, and what it prints (from a ROM in terminal.v)
COMMANDS = ['help', 'clear', 'theme', 'crt']
BLANKS = (0x00, 0x20, 0x24)                             # blank, space, the prompt's $
_Y, _D, _R = '\x1b[38;5;221m', '\x1b[38;5;245m', '\x1b[0m'
SAY = {
    'help': ('\r\n' + '\r\n'.join([
        f'  {_Y}help{_R}            this list',
        f'  {_Y}clear{_R}           clear the screen',
        f'  {_Y}theme{_R}           the next colour theme: colour, green or amber',
        f'  {_Y}crt{_R}             CRT scanlines on or off',
        f'  {_Y}12 + 30 - 5{_R}     add and subtract whole numbers',
        f'  {_D}Programs that send escape sequences take over the screen;{_R}',
        f'  {_D}hold S1 to come back to this shell.{_R}']) + '\r\n').encode(),
    'clear': b'\x1b[H\x1b[2J',
    'unknown': f'\r\n{_D}not a sum or a command: try{_R} {_Y}help{_R}\r\n'.encode(),
}


def command(row):
    """The command typed on a row: its only word, if that is one of COMMANDS."""
    word, ended = '', False
    for w in row:
        g = w & 0x3FF
        if g in BLANKS:
            ended = ended or bool(word)
        elif ended:
            return None                                 # a second word
        else:
            word += chr(g)
    return word if word in COMMANDS else None


def evaluate(row):
    """The value of a line typed at the shell: a sum of 32-bit integers, or None."""
    mask = 0xFFFFFFFF
    total = num = 0
    minus = in_num = any_token = False
    expect = True                                       # a number must come next
    for w in row:
        g = w & 0x3FF
        if g in (0x00, 0x20, 0x24):                     # blank, space, the prompt's $
            in_num = False
        elif 0x30 <= g <= 0x39:
            if in_num:
                num = (num * 10 + g - 0x30) & mask
            elif expect:
                num, in_num, expect, any_token = g - 0x30, True, False, True
            else:
                return None                             # two numbers in a row
        elif g in (0x2B, 0x2D):
            if expect and any_token:
                return None                             # two operators in a row
            if not expect:
                total = (total - num if minus else total + num) & mask
            minus, expect, in_num, any_token = g == 0x2D, True, False, True
        else:
            return None
    if expect:
        return None
    total = (total - num if minus else total + num) & mask
    return total - (1 << 32) if total >> 31 else total


# ------------------------------------------------------------------ the title and status bars
# Bar template word: like a cell word, but bits 31:29 say what goes in the cell
T_STATIC, T_TITLE, T_DIGIT, T_SPARK, T_DOT, T_THEME = range(6)
THEMES = ['COLOR', 'GREEN', 'AMBER']
IDLE_DOT = 238


def tword(kind, glyph, fg, bg, bold=False):
    return glyph | fg << 10 | bg << 18 | int(bold) << 26 | kind << 29


def glyph_of(ch):
    return tf.uni_glyph(ord(ch))[0]


def bar_templates():
    """The title bar (80 cells) then the status bar (80 cells), as template words."""
    tb = 235
    title = [tword(T_STATIC, 0x20, 250, tb)] * COLS
    for col, fg in ((1, 203), (3, 221), (5, 114)):
        title[col] = tword(T_STATIC, glyph_of('●'), fg, tb)
    default = 'NANO TERM — Tang Nano 9K'
    for i in range(TITLE_LEN):
        g = glyph_of(default[i]) if i < len(default) else 0x20
        title[TITLE_COL + i] = tword(T_TITLE, g, 252, tb, bold=True)
    for i, ch in enumerate('RX'):
        title[63 + i] = tword(T_STATIC, glyph_of(ch), 245, tb)
    for i in range(8):
        title[66 + i] = tword(T_SPARK, i, 80, tb)
    title[75] = tword(T_DOT, glyph_of('●'), 83, tb)

    def text(s, fg, bg, fields=(), bold=False):
        cells = []
        for ch in s:
            if ch == '#':
                cells.append(tword(T_DIGIT, fields[len([c for c in cells if c >> 29 == T_DIGIT])], fg, bg, bold))
            elif ch == '$':
                cells.append(tword(T_THEME, len([c for c in cells if c >> 29 == T_THEME]), fg, bg, bold))
            else:
                cells.append(tword(T_STATIC, glyph_of(ch), fg, bg, bold))
        return cells

    mid = 234
    left = [(' NANO TERM ', 16, 38, (), True), (' ####### 8N1 ', 252, 238, tuple(range(17, 24)), False),
            (' Ln ## Col ## ', 250, 236, (0, 1, 2, 3), False)]
    right = [(' RX ####### ', 250, 236, tuple(range(4, 11)), False),
             (' ##:##:## ', 252, 238, tuple(range(11, 17)), False),
             (' $$$$$ ', 16, 38, (), True)]
    status = []
    for i, (s, fg, bg, fields, bold) in enumerate(left):
        status += text(s, fg, bg, fields, bold)
        nxt = left[i + 1][2] if i + 1 < len(left) else mid
        status.append(tword(T_STATIC, tf.MISC_SLOT[0xE0B0], bg, nxt))
    tail = []
    prev = mid
    for s, fg, bg, fields, bold in right:
        tail.append(tword(T_STATIC, tf.MISC_SLOT[0xE0B2], bg, prev))
        tail += text(s, fg, bg, fields, bold)
        prev = bg
    status += [tword(T_STATIC, 0x20, 250, mid)] * (COLS - len(status) - len(tail)) + tail
    assert len(status) == COLS, len(status)
    return title + status


def bar_cells(templates, st):
    """What the bar updater writes, given the live values in st (a dict)."""
    def digits(v, n):
        return [(v // 10 ** (n - 1 - i)) % 10 for i in range(n)]
    d = digits(st['cy'] + 1, 2) + digits(st['cx'] + 1, 2) + digits(st['rx'], 7) + \
        digits(st['hours'], 2) + digits(st['minutes'], 2) + digits(st['seconds'], 2) + digits(st['baud'], 7)
    blank = set()
    if d[0] == 0:
        blank.add(0)
    if d[2] == 0:
        blank.add(2)
    for first, last in ((4, 10), (17, 23)):          # leading zeros of the byte count and the speed
        for i in range(first, last):
            if d[i] != 0:
                break
            blank.add(i)
    cells = []
    for col, t in enumerate(templates):
        kind, g = t >> 29, t & 0x3FF
        fg, bg, bold = (t >> 10) & 255, (t >> 18) & 255, (t >> 26) & 1
        if kind == T_TITLE and st['title_custom']:
            i = col - TITLE_COL
            g = st['title'][i] if i < len(st['title']) else 0x20
        elif kind == T_DIGIT:
            g = 0x20 if g in blank else 0x30 + d[g]
        elif kind == T_SPARK:
            level = st['spark'][g]
            g = 0x20 if level == 0 else 0x180 + level
        elif kind == T_DOT:
            fg = fg if st['active'] else IDLE_DOT
        elif kind == T_THEME:
            g = ord(THEMES[st['theme']][g])
        cells.append(word(g, fg, bg, bold))
    return cells


def spark_level(count):
    """Bytes received in one second -> sparkline height 0-8."""
    if count == 0:
        return 0
    return min(8, 1 + (count.bit_length() - 1) // 2)


# ------------------------------------------------------------------ the renderer
W, H = 720, 480                    # the screen: 80 cells of 9 pixels, 30 rows of 16
EXTENDED = range(0x100, 0x1A0)      # box drawing and blocks continue into the 9th column


def gradient(x):
    """The accent lines under the title bar and over the status bar: cyan to purple."""
    t = x >> 2
    return (t, 255 - t, 255 - (t >> 2))


def italic_shift(fy):
    return 2 if fy < 6 else 1 if fy < 10 else 0


def theme_rgb(rgb, theme):
    r, g, b = rgb
    if theme == 0:
        return rgb
    lum = (2 * r + 5 * g + b) >> 3
    if theme == 1:
        return (lum >> 2, lum, lum >> 2)
    return (lum, (lum >> 1) + (lum >> 3) + (lum >> 4), lum >> 4)


def render(cells, rowmap, bank, st):
    """One 720x480 frame, exactly as terminal.v draws it.

    cells: 62 x 80 physical cell words; rowmap: physical row (0-27) of each terminal row
    st: cx, cy, cursor (drawn this frame), style, scnm, blink_off, bell, theme, crt
    """
    font = [tf.glyph_rows(g) for g in range(0x300)]
    img = []
    for y in range(480):
        row, fy = y >> 4, y & 15
        phys = BAR_TITLE if row == 0 else BAR_STATUS if row == 29 else bank * 32 + rowmap[row - 1]
        line = []
        for x in range(W):
            col, fx = divmod(x, 9)
            g, fg, bg, fl = unpack(cells[phys][col])
            bits = font[g][fy]
            if fl & ITALIC:
                bits >>= italic_shift(fy)
            bits = bits << 1 | (bits & 1 if g in EXTENDED else 0)
            if (fl & UNDERLINE and fy == 14) or (fl & STRIKE and fy == 8):
                bits = 0x1FF
            on = bits >> (8 - fx) & 1
            if fl & BLINK and st['blink_off']:
                on = 0
            text = 0 < row < 29
            if text and st['cursor'] and row - 1 == st['cy'] and col == st['cx']:
                style = st['style']
                if style == 0 or (style == 1 and fy >= 14) or (style == 2 and fx < 2):
                    on ^= 1
            if text and st['scnm']:
                on ^= 1
            rgb = tf.PALETTE[fg if on else bg]
            if fl & DIM and on:
                rgb = tuple(c >> 1 for c in rgb)
            if (row == 0 and fy == 15) or (row == 29 and fy == 0):
                rgb = gradient(x)
            elif row == 0 and st['bell']:
                rgb = tuple(255 - c for c in rgb)
            line.append(theme_rgb(rgb, st['theme']))
        if st['crt'] and y & 1:                        # scanlines: odd lines a little darker
            line = [tuple(c - (c >> 2) for c in p) for p in line]
        img.append(line)
    return img


def default_bars(term, baud=2000000, theme=0):
    t = bar_templates()
    st = {'cx': term.cx, 'cy': term.cy, 'rx': 0, 'hours': 0, 'minutes': 0, 'seconds': 0, 'baud': baud,
          'spark': [0] * 8, 'active': False, 'theme': theme, 'title_custom': term.title_custom,
          'title': term.title}
    return bar_cells(t[:COLS], st), bar_cells(t[COLS:], st)


def physical(term, bars):
    """The terminal's screens laid out as the 62 physical rows of cell RAM (identity row maps)."""
    blank = [word(0x20)] * COLS
    cells = [list(r) for r in term.screens[0]] + [blank] * 4 + [list(r) for r in term.screens[1]] + [blank] * 4
    cells[BAR_TITLE], cells[BAR_STATUS] = bars
    return cells[:62]


def render_term(term, theme=0, crt=False, cursor=True, bars=None, baud=2000000):
    cells = physical(term, bars or default_bars(term, baud, theme=theme))
    st = {'cx': term.cx, 'cy': term.cy, 'cursor': cursor and term.tcem, 'style': term.cur_style,
          'scnm': term.scnm, 'blink_off': False, 'bell': False, 'theme': theme, 'crt': crt}
    return render(cells, list(range(ROWS)), term.bank, st)


def save_png(img, path, scale=1):
    from PIL import Image
    im = Image.new('RGB', (len(img[0]), len(img)))
    im.putdata([p for line in img for p in line])
    if scale != 1:
        im = im.resize((im.width * scale, im.height * scale), Image.NEAREST)
    im.save(path)


if __name__ == '__main__':
    t = Term()
    t.feed(open(sys.argv[1], 'rb').read())
    theme = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    save_png(render_term(t, theme=theme, crt=len(sys.argv) > 4), sys.argv[2])
