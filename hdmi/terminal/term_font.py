"""Font, colours and character tables for NANO TERM (terminal.v).

All glyphs are original: ASCII and Latin-1 are drawn by hand below (8x16 cells, two-pixel
stems in the style of PC text mode), accented letters are composed from a base letter and
an accent, and box drawing, block elements, braille, geometric shapes and powerline
separators are drawn by code.

Glyph numbers (10 bits, stored in each screen cell):
  0x000-0x0FF  Unicode U+0000-00FF (ASCII and Latin-1); unused control slots hold symbols
  0x100-0x17F  box drawing U+2500-257F
  0x180-0x19F  block elements U+2580-259F
  0x1A0-0x1FF  more symbols (arrows, shapes, check marks, powerline, ...)
  0x200-0x2FF  braille U+2800-28FF, drawn by the renderer from the dot pattern
Only glyphs below 0x200 are stored in the font ROM (512 x 16 rows).
"""
import unicodedata

W, H = 8, 16
REPLACEMENT, WIDE_L, WIDE_R = 0x01, 0x02, 0x03      # unknown character, double-width unknown


def art(start, text):
    """Rows of '#'/'.' art (space separated) placed from row `start` -> 16 row bytes."""
    rows = [0] * H
    for i, line in enumerate(text.split()):
        assert len(line) == 8, (start, line)
        rows[start + i] = int(line.replace('#', '1').replace('.', '0'), 2)
    return rows


def from_pixels(on):
    """on(x, y) -> bool for each pixel -> 16 row bytes."""
    return [sum(0x80 >> x for x in range(W) if on(x, y)) for y in range(H)]


def pixel(rows, x, y):
    return 0 <= x < W and 0 <= y < H and bool(rows[y] & (0x80 >> x))


# ------------------------------------------------------------------ ASCII (hand drawn)
# Caps sit on rows 2-11, lowercase x-height is rows 5-11, descenders reach row 14.
ASCII = {
    ' ': (2, ''),
    '!': (2, '...##... ...##... ...##... ...##... ...##... ...##... ...##... ........ ...##... ...##...'),
    '"': (2, '.##..##. .##..##. .##..##.'),
    '#': (4, '..#..#.. ..#..#.. .######. ..#..#.. ..#..#.. .######. ..#..#.. ..#..#..'),
    '$': (1, '...#.... .#####.. ##...##. ##...... ##...... .#####.. .....##. .....##. ##...##. .#####.. ...#....'),
    '%': (4, '##....#. ##...##. ....##.. ...##... ..##.... .##..... ##...##. #....##.'),
    '&': (2, '..###... .##.##.. .##.##.. ..###... .###.##. ##.###.. ##..##.. ##..##.. ##.###.. .###.##.'),
    "'": (2, '...##... ...##... ..##....'),
    '(': (2, '....##.. ...##... ..##.... ..##.... ..##.... ..##.... ..##.... ..##.... ...##... ....##..'),
    ')': (2, '..##.... ...##... ....##.. ....##.. ....##.. ....##.. ....##.. ....##.. ...##... ..##....'),
    '*': (5, '.#.#.#.. ..###... #######. ..###... .#.#.#..'),
    '+': (5, '...##... ...##... .######. ...##... ...##...'),
    ',': (10, '...##... ...##... ..##....'),
    '-': (7, '.######.'),
    '.': (10, '...##... ...##...'),
    '/': (2, '.....##. .....##. ....##.. ....##.. ...##... ...##... ..##.... ..##.... .##..... .##.....'),
    '0': (2, '.#####.. ##...##. ##...##. ##...##. ##.#.##. ##.#.##. ##...##. ##...##. ##...##. .#####..'),
    '1': (2, '...##... ..###... .####... ...##... ...##... ...##... ...##... ...##... ...##... .######.'),
    '2': (2, '.#####.. ##...##. .....##. ....##.. ...##... ..##.... .##..... ##...... ##...##. #######.'),
    '3': (2, '.#####.. ##...##. .....##. .....##. ..####.. .....##. .....##. .....##. ##...##. .#####..'),
    '4': (2, '....##.. ...###.. ..####.. .##.##.. ##..##.. #######. ....##.. ....##.. ....##.. ...####.'),
    '5': (2, '#######. ##...... ##...... ##...... ######.. .....##. .....##. .....##. ##...##. .#####..'),
    '6': (2, '..###... .##..... ##...... ##...... ######.. ##...##. ##...##. ##...##. ##...##. .#####..'),
    '7': (2, '#######. .....##. .....##. ....##.. ...##... ..##.... ..##.... ..##.... ..##.... ..##....'),
    '8': (2, '.#####.. ##...##. ##...##. ##...##. .#####.. ##...##. ##...##. ##...##. ##...##. .#####..'),
    '9': (2, '.#####.. ##...##. ##...##. ##...##. ##...##. .######. .....##. .....##. ....##.. .####...'),
    ':': (5, '...##... ...##... ........ ........ ........ ...##... ...##...'),
    ';': (5, '...##... ...##... ........ ........ ........ ...##... ...##... ..##....'),
    '<': (3, '.....##. ....##.. ...##... ..##.... .##..... ..##.... ...##... ....##.. .....##.'),
    '=': (6, '.######. ........ ........ .######.'),
    '>': (3, '.##..... ..##.... ...##... ....##.. .....##. ....##.. ...##... ..##.... .##.....'),
    '?': (2, '.#####.. ##...##. ##...##. .....##. ....##.. ...##... ...##... ........ ...##... ...##...'),
    '@': (4, '.#####.. ##...##. ##.####. ##.#.##. ##.#.##. ##.####. ##...... .#####..'),
    'A': (2, '..###... .##.##.. ##...##. ##...##. ##...##. #######. ##...##. ##...##. ##...##. ##...##.'),
    'B': (2, '######.. ##...##. ##...##. ##...##. ######.. ##...##. ##...##. ##...##. ##...##. ######..'),
    'C': (2, '.#####.. ##...##. ##...... ##...... ##...... ##...... ##...... ##...... ##...##. .#####..'),
    'D': (2, '#####... ##..##.. ##...##. ##...##. ##...##. ##...##. ##...##. ##...##. ##..##.. #####...'),
    'E': (2, '#######. ##...... ##...... ##...... ######.. ##...... ##...... ##...... ##...... #######.'),
    'F': (2, '#######. ##...... ##...... ##...... ######.. ##...... ##...... ##...... ##...... ##......'),
    'G': (2, '.#####.. ##...##. ##...... ##...... ##...... ##.####. ##...##. ##...##. ##...##. .#####..'),
    'H': (2, '##...##. ##...##. ##...##. ##...##. #######. ##...##. ##...##. ##...##. ##...##. ##...##.'),
    'I': (2, '..####.. ...##... ...##... ...##... ...##... ...##... ...##... ...##... ...##... ..####..'),
    'J': (2, '...####. ....##.. ....##.. ....##.. ....##.. ....##.. ....##.. ##..##.. ##..##.. .####...'),
    'K': (2, '##...##. ##...##. ##..##.. ##.##... ####.... ####.... ##.##... ##..##.. ##...##. ##...##.'),
    'L': (2, '##...... ##...... ##...... ##...... ##...... ##...... ##...... ##...... ##...... #######.'),
    'M': (2, '##...##. ###.###. #######. ##.#.##. ##...##. ##...##. ##...##. ##...##. ##...##. ##...##.'),
    'N': (2, '##...##. ###..##. ###..##. ####.##. ##.####. ##..###. ##..###. ##...##. ##...##. ##...##.'),
    'O': (2, '.#####.. ##...##. ##...##. ##...##. ##...##. ##...##. ##...##. ##...##. ##...##. .#####..'),
    'P': (2, '######.. ##...##. ##...##. ##...##. ######.. ##...... ##...... ##...... ##...... ##......'),
    'Q': (2, '.#####.. ##...##. ##...##. ##...##. ##...##. ##...##. ##...##. ##.#.##. ##..##.. .###.##.'),
    'R': (2, '######.. ##...##. ##...##. ##...##. ######.. ##.##... ##..##.. ##..##.. ##...##. ##...##.'),
    'S': (2, '.#####.. ##...##. ##...... ##...... .#####.. .....##. .....##. .....##. ##...##. .#####..'),
    'T': (2, '.######. ...##... ...##... ...##... ...##... ...##... ...##... ...##... ...##... ...##...'),
    'U': (2, '##...##. ##...##. ##...##. ##...##. ##...##. ##...##. ##...##. ##...##. ##...##. .#####..'),
    'V': (2, '##...##. ##...##. ##...##. ##...##. ##...##. ##...##. .##.##.. .##.##.. ..###... ...#....'),
    'W': (2, '##...##. ##...##. ##...##. ##...##. ##...##. ##.#.##. ##.#.##. #######. ###.###. ##...##.'),
    'X': (2, '##...##. ##...##. .##.##.. .##.##.. ..###... ..###... .##.##.. .##.##.. ##...##. ##...##.'),
    'Y': (2, '.##..##. .##..##. .##..##. .##..##. ..####.. ...##... ...##... ...##... ...##... ...##...'),
    'Z': (2, '#######. .....##. ....##.. ....##.. ...##... ..##.... ..##.... .##..... ##...... #######.'),
    '[': (2, '..####.. ..##.... ..##.... ..##.... ..##.... ..##.... ..##.... ..##.... ..##.... ..####..'),
    '\\': (2, '.##..... .##..... ..##.... ..##.... ...##... ...##... ....##.. ....##.. .....##. .....##.'),
    ']': (2, '..####.. ....##.. ....##.. ....##.. ....##.. ....##.. ....##.. ....##.. ....##.. ..####..'),
    '^': (1, '...#.... ..###... .##.##.. ##...##.'),
    '_': (13, '########'),
    '`': (1, '..##.... ...##... ....##..'),
    'a': (5, '.#####.. .....##. .######. ##...##. ##...##. ##..###. .###.##.'),
    'b': (2, '##...... ##...... ##...... ######.. ##...##. ##...##. ##...##. ##...##. ##...##. ######..'),
    'c': (5, '.#####.. ##...##. ##...... ##...... ##...... ##...##. .#####..'),
    'd': (2, '.....##. .....##. .....##. .######. ##...##. ##...##. ##...##. ##...##. ##...##. .######.'),
    'e': (5, '.#####.. ##...##. ##...##. #######. ##...... ##...##. .#####..'),
    'f': (2, '...####. ..##.... ..##.... ######.. ..##.... ..##.... ..##.... ..##.... ..##.... ..##....'),
    'g': (5, '.######. ##...##. ##...##. ##...##. ##...##. ##...##. .######. .....##. ##...##. .#####..'),
    'h': (2, '##...... ##...... ##...... ######.. ##...##. ##...##. ##...##. ##...##. ##...##. ##...##.'),
    'i': (3, '...##... ........ ..###... ...##... ...##... ...##... ...##... ...##... ..####..'),
    'j': (3, '....##.. ........ ...###.. ....##.. ....##.. ....##.. ....##.. ....##.. ....##.. ....##.. .##.##.. ..###...'),
    'k': (2, '##...... ##...... ##...... ##...##. ##..##.. ##.##... ####.... ##.##... ##..##.. ##...##.'),
    'l': (2, '..###... ...##... ...##... ...##... ...##... ...##... ...##... ...##... ...##... ..####..'),
    'm': (5, '######.. ##.#.##. ##.#.##. ##.#.##. ##.#.##. ##.#.##. ##.#.##.'),
    'n': (5, '######.. ##...##. ##...##. ##...##. ##...##. ##...##. ##...##.'),
    'o': (5, '.#####.. ##...##. ##...##. ##...##. ##...##. ##...##. .#####..'),
    'p': (5, '######.. ##...##. ##...##. ##...##. ##...##. ##...##. ######.. ##...... ##...... ##......'),
    'q': (5, '.######. ##...##. ##...##. ##...##. ##...##. ##...##. .######. .....##. .....##. .....##.'),
    'r': (5, '##.###.. ###..##. ##...... ##...... ##...... ##...... ##......'),
    's': (5, '.#####.. ##...##. ##...... .#####.. .....##. ##...##. .#####..'),
    't': (3, '..##.... ..##.... ######.. ..##.... ..##.... ..##.... ..##.... ..##.##. ...###..'),
    'u': (5, '##...##. ##...##. ##...##. ##...##. ##...##. ##...##. .######.'),
    'v': (5, '##...##. ##...##. ##...##. .##.##.. .##.##.. ..###... ...#....'),
    'w': (5, '##...##. ##...##. ##.#.##. ##.#.##. ##.#.##. #######. .##.##..'),
    'x': (5, '##...##. ##...##. .##.##.. ..###... .##.##.. ##...##. ##...##.'),
    'y': (5, '##...##. ##...##. ##...##. ##...##. ##...##. ##...##. .######. .....##. ....##.. #####...'),
    'z': (5, '#######. .....##. ....##.. ...##... ..##.... .##..... #######.'),
    '{': (2, '....###. ...##... ...##... ...##... .###.... ...##... ...##... ...##... ...##... ....###.'),
    '|': (1, '...##... ...##... ...##... ...##... ...##... ...##... ...##... ...##... ...##... ...##... ...##... ...##... ...##...'),
    '}': (2, '.###.... ...##... ...##... ...##... ....###. ...##... ...##... ...##... ...##... .###....'),
    '~': (5, '.###.##. ##.###..'),
}

# ------------------------------------------------------------------ Latin-1 symbols (hand drawn)
LATIN1 = {
    0xA0: (2, ''),
    0xA1: (4, '...##... ...##... ........ ...##... ...##... ...##... ...##... ...##... ...##... ...##...'),
    0xA2: (3, '...#.... .#####.. ##.#.##. ##.#.... ##.#.... ##.#.##. .#####.. ...#....'),
    0xA3: (2, '..####.. .##..##. .##..... .##..... #####... .##..... .##..... .##..... .##..... #######.'),
    0xA4: (4, '#.....#. .#####.. .#...#.. .#...#.. .#...#.. .#####.. #.....#.'),
    0xA5: (2, '.##..##. .##..##. ..####.. ...##... .######. ...##... .######. ...##... ...##... ...##...'),
    0xA6: (1, '...##... ...##... ...##... ...##... ...##... ........ ........ ...##... ...##... ...##... ...##... ...##...'),
    0xA7: (2, '.#####.. ##...##. .##..... ..###... .##.##.. ##...##. .##.##.. ..###... ....##.. ##...##. .#####..'),
    0xA8: (2, '.##.##..'),
    0xA9: (3, '.#####.. #.....#. #.###.#. #.#...#. #.#...#. #.###.#. #.....#. .#####..'),
    0xAA: (2, '.####... ....##.. .#####.. ##..##.. .###.##. ........ .######.'),
    0xAB: (5, '..##.##. .##.##.. ##.##... .##.##.. ..##.##.'),
    0xAC: (6, '#######. .....##. .....##.'),
    0xAD: (7, '..####..'),
    0xAE: (3, '.#####.. #.....#. #.##..#. #.#.#.#. #.##..#. #.#.#.#. #.....#. .#####..'),
    0xAF: (1, '#######.'),
    0xB0: (2, '..###... .##.##.. .##.##.. ..###...'),
    0xB1: (3, '...##... ...##... .######. ...##... ...##... ........ .######.'),
    0xB2: (2, '.###.... ##.##... ..##.... .##..... #####...'),
    0xB3: (2, '####.... ...##... .###.... ...##... ####....'),
    0xB4: (1, '....##.. ...##...'),
    0xB5: (5, '##...##. ##...##. ##...##. ##...##. ##...##. ##..###. ######.. ##...... ##......'),
    0xB6: (2, '.######. ####.##. ####.##. .###.##. ...#.##. ...#.##. ...#.##. ...#.##. ...#.##. ...#.##.'),
    0xB7: (7, '...##... ...##...'),
    0xB8: (12, '....##.. ..###...'),
    0xB9: (2, '..#..... .##..... ..#..... ..#..... .###....'),
    0xBA: (2, '.###.... ##.##... ##.##... .###.... ........ #####...'),
    0xBB: (5, '##.##... .##.##.. ..##.##. .##.##.. ##.##...'),
    0xBC: (2, '##...... .#...... .#...#.. .#..#... ...#.... ..#..#.. .#..##.. #..#.#.. ...####. .....#..'),
    0xBD: (2, '##...... .#...... .#...#.. .#..#... ...#.... ..#.##.. .#.#..#. #....#.. ....#... ...####.'),
    0xBE: (2, '##...... ..#..... .#...#.. ..#.#... ##.#.... ..#..#.. .#..##.. #..#.#.. ...####. .....#..'),
    0xBF: (5, '...##... ...##... ........ ...##... ..##.... .##..... ##...##. ##...##. .#####..'),
    0xC6: (2, '.######. ##.##... ##.##... ##.##... ######.. ##.##... ##.##... ##.##... ##.##... ##.####.'),
    0xD0: (2, '#####... .##.##.. .##..##. .##..##. ####.##. .##..##. .##..##. .##..##. .##.##.. #####...'),
    0xD7: (5, '##...##. .##.##.. ..###... .##.##.. ##...##.'),
    0xD8: (2, '.######. ##...##. ##..###. ##..###. ##.#.##. ##.#.##. ###..##. ###..##. ##...##. ######..'),
    0xDE: (2, '##...... ######.. ##...##. ##...##. ##...##. ######.. ##...... ##...... ##...... ##......'),
    0xDF: (2, '.####... ##..##.. ##..##.. ##.##... ##..##.. ##...##. ##...##. ##...##. ##..##.. ##.##...'),
    0xE6: (5, '.##.##.. ...#..#. .######. #..#.... #..#.... #..#..#. .##.##..'),
    0xF0: (2, '.##.#... ..##.... .#.##... ....##.. .######. ##...##. ##...##. ##...##. ##...##. .#####..'),
    0xF7: (4, '...##... ...##... ........ .######. ........ ...##... ...##...'),
    0xF8: (4, '......#. .#####.. ##..###. ##.#.##. ##.#.##. ##.#.##. ###..##. .#####.. #.......'),
    0xFE: (2, '##...... ##...... ##...... ######.. ##...##. ##...##. ##...##. ##...##. ##...##. ######.. ##...... ##...... ##......'),
}

# Accents: (rows above a capital, rows above a lowercase letter)
ACCENTS = {
    'grave': ('..##.... ...##...', '..##.... ...##...'),
    'acute': ('....##.. ...##...', '....##.. ...##...'),
    'circ':  ('..###... .##.##..', '..###... .##.##..'),
    'tilde': ('.###.##. ##.###..', '.###.##. ##.###..'),
    'diaer': ('........ .##.##..', '........ .##.##..'),
    'ring':  ('..###... ..#.#... ..###...', '..###... ..#.#... ..###...'),
}
COMPOSED = {}
for base, first, accents in (
        ('A', 0xC0, ('grave', 'acute', 'circ', 'tilde', 'diaer', 'ring')),
        ('E', 0xC8, ('grave', 'acute', 'circ', 'diaer')),
        ('I', 0xCC, ('grave', 'acute', 'circ', 'diaer')),
        ('O', 0xD2, ('grave', 'acute', 'circ', 'tilde', 'diaer')),
        ('U', 0xD9, ('grave', 'acute', 'circ', 'diaer')),
        ('a', 0xE0, ('grave', 'acute', 'circ', 'tilde', 'diaer', 'ring')),
        ('e', 0xE8, ('grave', 'acute', 'circ', 'diaer')),
        ('i', 0xEC, ('grave', 'acute', 'circ', 'diaer')),
        ('o', 0xF2, ('grave', 'acute', 'circ', 'tilde', 'diaer')),
        ('u', 0xF9, ('grave', 'acute', 'circ', 'diaer'))):
    for i, acc in enumerate(accents):
        COMPOSED[first + i] = (base, acc)
COMPOSED.update({0xD1: ('N', 'tilde'), 0xDD: ('Y', 'acute'), 0xF1: ('n', 'tilde'),
                 0xFD: ('y', 'acute'), 0xFF: ('y', 'diaer'), 0xC7: ('C', 'cedilla'), 0xE7: ('c', 'cedilla')})
DOTLESS_I = (5, '..###... ...##... ...##... ...##... ...##... ...##... ..####..')


def compose(base, accent):
    if base == 'i':
        rows = art(*DOTLESS_I)
    else:
        rows = art(*ASCII[base])
    if accent == 'cedilla':
        rows[12:14] = art(12, '....##.. ..###...')[12:14]
        return rows
    capital = base.isupper()
    top_rows = ACCENTS[accent][0 if capital else 1].split()
    if capital:
        # squeeze the 10-row capital (rows 2-11) to fit the accent above it
        body = rows[2:12]
        order = sorted(range(len(body) - 1), key=lambda k: abs(k - len(body) / 2))
        k = next((k for k in order if body[k] == body[k + 1]), len(body) // 2)   # drop a repeated row
        del body[k]
        rows = [0] * H
        rows[12 - len(body):12] = body
        rows[0:len(top_rows)] = art(0, ' '.join(top_rows))[0:len(top_rows)]
    else:
        start = 4 - len(top_rows)
        for i, line in enumerate(top_rows):
            rows[start + i] = art(0, line)[0]
    return rows


# ------------------------------------------------------------------ box drawing and blocks (drawn by code)
CX, CY = 3, 7          # light lines: column 3, row 7; heavy lines add column 4 / row 8
NONE, LIGHT, HEAVY, DOUBLE = 0, 1, 2, 3


def box_arms(name):
    words = {'LIGHT': LIGHT, 'SINGLE': LIGHT, 'HEAVY': HEAVY, 'DOUBLE': DOUBLE}
    dirs_of = {'LEFT': 'L', 'RIGHT': 'R', 'UP': 'U', 'DOWN': 'D', 'HORIZONTAL': 'LR', 'VERTICAL': 'UD'}
    parsed = []
    for clause in name.split(' AND '):
        dirs, weight = '', None
        for word in clause.split():
            if word in words:
                weight = words[word]
            elif word in dirs_of:
                dirs += dirs_of[word]
        parsed.append((dirs, weight))
    default = next(w for _, w in parsed if w is not None)
    arms = dict.fromkeys('LRUD', NONE)
    for dirs, weight in parsed:
        for d in dirs:
            arms[d] = weight or default
    return arms


def box_glyph(cp):
    name = unicodedata.name(chr(cp))[len('BOX DRAWINGS '):]
    px = [[False] * W for _ in range(H)]

    def hline(y, x0, x1):
        for x in range(max(0, x0), min(W - 1, x1) + 1):
            px[y][x] = True

    def vline(x, y0, y1):
        for y in range(max(0, y0), min(H - 1, y1) + 1):
            px[y][x] = True

    heavy = name.startswith('HEAVY')
    if 'DASH' in name:
        n = {'DOUBLE': 2, 'TRIPLE': 3, 'QUADRUPLE': 4}[name.split()[1]]
        if name.endswith('HORIZONTAL'):
            on = {2: '###.###.', 3: '##.##.##', 4: '#.#.#.#.'}[n]
            for y in (CY, CY + 1) if heavy else (CY,):
                for x in range(W):
                    px[y][x] = on[x] == '#'
        else:
            on = {2: '######..######..', 3: '####..####..####', 4: '##..##..##..##..'}[n]
            for x in (CX, CX + 1) if heavy else (CX,):
                for y in range(H):
                    px[y][x] = on[y] == '#'
        return from_pixels(lambda x, y: px[y][x])
    if 'ARC' in name:
        # a rounded corner: DOWN AND RIGHT, mirrored for the other three
        fx, fy = 'LEFT' in name, 'UP' in name
        for x, y in [(5, CY), (6, CY), (7, CY), (4, CY + 1)] + [(CX, y) for y in range(CY + 2, H)]:
            x, y = (2 * CX - x) if fx else x, (2 * CY - y) if fy else y
            if 0 <= x < W and 0 <= y < H:
                px[y][x] = True
        return from_pixels(lambda x, y: px[y][x])
    if 'DIAGONAL' in name:
        a = 'UPPER RIGHT' in name or 'CROSS' in name
        b = 'UPPER LEFT' in name or 'CROSS' in name
        return from_pixels(lambda x, y: (a and x == W - 1 - y // 2) or (b and x == y // 2))

    arms = box_arms(name)
    L, R, U, D = arms['L'], arms['R'], arms['U'], arms['D']
    hdbl = DOUBLE in (L, R)
    vdbl = DOUBLE in (U, D)
    # light and heavy arms
    for arm, weight in arms.items():
        if weight in (LIGHT, HEAVY):
            thick = 2 if weight == HEAVY else 1
            if arm in 'LR':
                x0, x1 = (0, CX - 1 if vdbl else CX) if arm == 'L' else (CX + 1 if vdbl else CX, W - 1)
                for y in range(CY, CY + thick):
                    hline(y, x0, x1)
            else:
                y0, y1 = (0, CY - 1 if hdbl else CY) if arm == 'U' else (CY + 1 if hdbl else CY, H - 1)
                for x in range(CX, CX + thick):
                    vline(x, y0, y1)
    # the centre block joins light and heavy arms into square corners
    hv = 1 if HEAVY in (U, D) else 0
    hh = 1 if HEAVY in (L, R) else 0
    if not hdbl and not vdbl:
        for y in range(CY, CY + 1 + hh):
            for x in range(CX, CX + 1 + hv):
                px[y][x] = True
    elif hdbl and U in (LIGHT,) and D in (LIGHT,):
        px[CY][CX] = True                 # a single line crossing a double one
    # double arms: two lines, one pixel either side of the light line
    lo, hi = CX - 1, CX + 1               # columns of a double vertical
    top, bot = CY - 1, CY + 1             # rows of a double horizontal

    def start(near, far):
        """Where a double line starts, given the perpendicular arm on its side and the other."""
        if near:
            return 'inner' if near == DOUBLE else 'centre'
        if far:
            return 'outer' if far == DOUBLE else 'centre'
        return 'outer'

    pos = {'inner': 1, 'centre': 0, 'outer': -1}
    if R == DOUBLE:
        hline(top, CX + pos[start(U, D)], W - 1)
        hline(bot, CX + pos[start(D, U)], W - 1)
    if L == DOUBLE:
        hline(top, 0, CX - pos[start(U, D)])
        hline(bot, 0, CX - pos[start(D, U)])
    if D == DOUBLE:
        vline(lo, CY + pos[start(L, R)], H - 1)
        vline(hi, CY + pos[start(R, L)], H - 1)
    if U == DOUBLE:
        vline(lo, 0, CY - pos[start(L, R)])
        vline(hi, 0, CY - pos[start(R, L)])
    return from_pixels(lambda x, y: px[y][x])


def block_glyph(cp):
    i = cp - 0x2580
    quad = {0x16: 'L', 0x17: 'R', 0x18: 'l', 0x1D: 'r', 0x19: 'lLR', 0x1A: 'lR', 0x1B: 'lrL',
            0x1C: 'lrR', 0x1E: 'rL', 0x1F: 'rLR'}
    if i == 0x00:
        return from_pixels(lambda x, y: y < 8)                      # upper half
    if 0x01 <= i <= 0x08:
        return from_pixels(lambda x, y: y >= H - 2 * i)             # lower 1/8 .. full
    if 0x09 <= i <= 0x0F:
        return from_pixels(lambda x, y: x < 8 - (i - 0x08))         # left 7/8 .. 1/8
    if i == 0x10:
        return from_pixels(lambda x, y: x >= 4)                     # right half
    if i == 0x11:
        return from_pixels(lambda x, y: (y % 2 == 0 and x % 4 == 0) or (y % 2 == 1 and x % 4 == 2))
    if i == 0x12:
        return from_pixels(lambda x, y: (x + y) % 2 == 0)
    if i == 0x13:
        return from_pixels(lambda x, y: not ((y % 2 == 0 and x % 4 == 0) or (y % 2 == 1 and x % 4 == 2)))
    if i == 0x14:
        return from_pixels(lambda x, y: y < 2)                      # upper 1/8
    if i == 0x15:
        return from_pixels(lambda x, y: x == 7)                     # right 1/8
    parts = quad[i]                                                 # l/r upper quadrants, L/R lower
    return from_pixels(lambda x, y: ('l' in parts and x < 4 and y < 8) or ('r' in parts and x >= 4 and y < 8)
                       or ('L' in parts and x < 4 and y >= 8) or ('R' in parts and x >= 4 and y >= 8))


def braille_glyph(pattern):
    """What the renderer draws for braille U+2800 + pattern: 2x2-pixel dots on a 2x4 grid."""
    bits = ((0, 1, 2, 6), (3, 4, 5, 7))
    return from_pixels(lambda x, y: x % 4 in (1, 2) and y % 4 in (1, 2) and bool(pattern >> bits[x // 4][y // 4] & 1))


# ------------------------------------------------------------------ other symbols
def shape(inside):
    """Fill by testing pixel centres."""
    return from_pixels(lambda x, y: inside(x + 0.5, y + 0.5))


def outline(rows):
    """Keep only the edge pixels of a filled shape."""
    return from_pixels(lambda x, y: pixel(rows, x, y) and not all(
        pixel(rows, x + dx, y + dy) for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))))


def mirror_x(rows, width=7):
    return from_pixels(lambda x, y: pixel(rows, width - 1 - x, y))


def two_letters(a, b):
    """A DEC control picture such as HT: two tiny letters on a diagonal."""
    mini = {'H': '#.# #.# ### #.# #.#', 'T': '### .#. .#. .#. .#.', 'F': '### #.. ##. #.. #..',
            'C': '.## #.. #.. #.. .##', 'R': '##. #.# ##. #.# #.#', 'L': '#.. #.. #.. #.. ###',
            'N': '##. #.# #.# #.# #.#', 'V': '#.# #.# #.# #.# .#.'}

    def put(rows, letter, x0, y0):
        for dy, line in enumerate(mini[letter].split()):
            for dx, c in enumerate(line):
                if c == '#':
                    rows[y0 + dy] |= 0x80 >> (x0 + dx)
    rows = [0] * H
    put(rows, a, 0, 3)
    put(rows, b, 4, 9)
    return rows


FILLED_BOX = shape(lambda x, y: 1 <= x <= 7 and 5 <= y <= 11)
TRI_UP = shape(lambda x, y: y <= 11 and abs(x - 4) <= (y - 4.5) * 3.5 / 6.5)
TRI_RIGHT = shape(lambda x, y: x >= 1 and abs(y - 8) <= (7.5 - x) * 4.5 / 6.5)
SMALL_UP = shape(lambda x, y: 6 <= y <= 10.5 and abs(x - 4) <= (y - 6) * 2.5 / 4.5)
SMALL_RIGHT = shape(lambda x, y: x >= 2 and abs(y - 8) <= (6.5 - x) * 2.5 / 4.5)
DISC = shape(lambda x, y: (x - 4) ** 2 + (y - 8) ** 2 <= 3.2 ** 2)
DIAMOND = shape(lambda x, y: abs(x - 4) + abs(y - 8) * 0.9 <= 3.6)
HALF_DISC = shape(lambda x, y: (x / 8) ** 2 + ((y - 8) / 8) ** 2 <= 1)
STAR = art(4, '...#.... ...#.... ..###... #######. .#####.. ..###... .##.##.. .#...#..')
POWER_TRI = shape(lambda x, y: x <= 8 - abs(y - 8))


def flip_y(rows, height=H):
    return [rows[height - 1 - y] for y in range(H)]


MISC = {   # code point -> 16 row bytes
    0x2190: art(5, '..#..... .##..... #######. #######. .##..... ..#.....'),             # ←
    0x2191: art(2, '...##... ..####.. .######. ...##... ...##... ...##... ...##... ...##... ...##... ...##...'),
    0x2192: art(5, '....#... ....##.. #######. #######. ....##.. ....#...'),             # →
    0x2193: art(2, '...##... ...##... ...##... ...##... ...##... ...##... ...##... .######. ..####.. ...##...'),
    0x2194: art(5, '..#..#.. .##..##. ######## ######## .##..##. ..#..#..'),             # ↔
    0x21B5: art(4, '......#. ......#. ..#...#. .##...#. #######. .##..... ..#.....'),    # ↵
    0x23CE: art(4, '......#. ......#. ..#...#. .##...#. #######. .##..... ..#.....'),    # ⏎
    0x2022: art(6, '..###... .#####.. .#####.. .#####.. ..###...'),                      # •
    0x2026: art(10, '#..#..#. #..#..#.'),                                               # …
    0x2018: art(2, '....##.. ...##... ...##...'),
    0x2019: art(2, '...##... ...##... ..##....'),
    0x201C: art(2, '..##.##. .##.##.. .##.##..'),
    0x201D: art(2, '.##.##.. .##.##.. ##.##...'),
    0x2013: art(7, '.######.'),
    0x2014: art(7, '########'),
    0x2039: art(5, '...##... ..##.... .##..... ..##.... ...##...'),
    0x203A: art(5, '.##..... ..##.... ...##... ..##.... .##.....'),
    0x20AC: art(2, '..####.. .##..##. ##...... #####... ##...... #####... ##...... ##...... .##..##. ..####..'),
    0x2264: art(3, '.....##. ...##... .##..... ...##... .....##. ........ .######.'),
    0x2265: art(3, '.##..... ...##... .....##. ...##... .##..... ........ .######.'),
    0x2260: art(4, '.....#.. .######. ....#... ...#.... .######. ..#.....'),
    0x2248: art(5, '.###.##. ##.###.. ........ .###.##. ##.###..'),
    0x221E: art(6, '.##.##.. #..#..#. #..#..#. .##.##..'),
    0x03C0: art(5, '#######. .##.##.. .##.##.. .##.##.. .##.##.. .##.##.. .##.##..'),
    0x03BB: art(2, '##...... .##..... .##..... ..##.... ..##.... .####... .##.##.. ##..##.. ##...##. ##...##.'),
    0x2713: art(4, '......#. .....##. .....#.. ....##.. #..##... ##.#.... .###.... ..#.....'),
    0x2714: art(4, '.....##. ....###. ....##.. #..###.. ##.##... #####... .###.... ..#.....'),
    0x2717: art(4, '#.....#. .#...#.. ..#.#... ...#.... ..#.#... .#...#.. #.....#.'),
    0x2718: art(4, '##...##. ###.###. .#####.. ..###... .#####.. ###.###. ##...##.'),
    0x2665: art(5, '.##.##.. #######. #######. #######. .#####.. ..###... ...#....'),
    0x2660: art(4, '...#.... ..###... .#####.. #######. #######. .#.#.#.. ...#.... ..###...'),
    0x2663: art(4, '..###... ..###... #.###.#. #######. #.#.#.#. ...#.... ..###...'),
    0x2666: DIAMOND,
    0x266A: art(3, '...###.. ...#.##. ...#..#. ...#.... ...#.... .###.... ####.... .##.....'),
    0x266B: art(3, '..#####. ..#...#. ..#####. ..#...#. ..#...#. ###.###. ###.###.'),
    0x263A: art(4, '.#####.. #.....#. #.#.#.#. #.....#. #.#.#.#. #..#..#. #.....#. .#####..'),
    0x276F: art(4, '##...... ###..... .###.... ..###... .###.... ###..... ##......'),   # ❯
    0x276E: art(4, '....##.. ...###.. ..###... .###.... ..###... ...###.. ....##..'),   # ❮
    0x279C: art(4, '....#... ....##.. ######.. #######. ######.. ....##.. ....#...'),   # ➜
    0x25A0: FILLED_BOX,                                                                  # ■
    0x25A1: outline(FILLED_BOX),                                                         # □
    0x25AA: shape(lambda x, y: 2 <= x <= 6 and 6 <= y <= 10),                            # ▪
    0x25AB: outline(shape(lambda x, y: 2 <= x <= 6 and 6 <= y <= 10)),                   # ▫
    0x25B2: TRI_UP, 0x25B3: outline(TRI_UP),                                             # ▲ △
    0x25BC: flip_y(TRI_UP), 0x25BD: outline(flip_y(TRI_UP)),                             # ▼ ▽
    0x25B6: TRI_RIGHT, 0x25B7: outline(TRI_RIGHT), 0x25BA: TRI_RIGHT,                    # ▶ ▷ ►
    0x25C0: mirror_x(TRI_RIGHT, 8), 0x25C1: outline(mirror_x(TRI_RIGHT, 8)),             # ◀ ◁
    0x25C4: mirror_x(TRI_RIGHT, 8),                                                      # ◄
    0x25B4: SMALL_UP, 0x25BE: flip_y(SMALL_UP),                                          # ▴ ▾
    0x25B8: SMALL_RIGHT, 0x25C2: mirror_x(SMALL_RIGHT, 8),                               # ▸ ◂
    0x25C6: DIAMOND, 0x25C7: outline(DIAMOND),                                           # ◆ ◇
    0x25CF: DISC, 0x25CB: outline(DISC),                                                 # ● ○
    0x25C9: from_pixels(lambda x, y: pixel(outline(DISC), x, y) or (x - 3.5) ** 2 + (y - 7.5) ** 2 <= 1.6),
    0x25E2: shape(lambda x, y: x / 8 + y / 16 >= 1), 0x25E3: shape(lambda x, y: (8 - x) / 8 + y / 16 >= 1),
    0x25E4: shape(lambda x, y: x / 8 + y / 16 <= 1), 0x25E5: shape(lambda x, y: (8 - x) / 8 + y / 16 <= 1),
    0x2605: STAR, 0x2606: outline(STAR),                                                 # ★ ☆
    0x2409: two_letters('H', 'T'), 0x240C: two_letters('F', 'F'), 0x240D: two_letters('C', 'R'),
    0x240A: two_letters('L', 'F'), 0x2424: two_letters('N', 'L'), 0x240B: two_letters('V', 'T'),
    0x23BA: from_pixels(lambda x, y: y == 1), 0x23BB: from_pixels(lambda x, y: y == 4),  # scan lines
    0x23BC: from_pixels(lambda x, y: y == 10), 0x23BD: from_pixels(lambda x, y: y == 14),
    0xE0B0: POWER_TRI, 0xE0B2: mirror_x(POWER_TRI, 8),                                   # powerline
    0xE0B1: from_pixels(lambda x, y: x == min(y, 15 - y) // 2 or x == (min(y, 15 - y) + 1) // 2),
    0xE0B3: from_pixels(lambda x, y: 7 - x == min(y, 15 - y) // 2 or 7 - x == (min(y, 15 - y) + 1) // 2),
    0xE0B4: HALF_DISC, 0xE0B6: mirror_x(HALF_DISC, 8),
    0xE0B5: outline(HALF_DISC), 0xE0B7: outline(mirror_x(HALF_DISC, 8)),
    0xE0A0: art(2, '.#...... .#...... .#...#.. .#...#.. .#..#... .#.#.... .##..... .#...... .#...... .#......'),
    0xE0A2: art(3, '..###... .#...#.. .#...#.. #######. #######. ###.###. ###.###. #######. #######.'),
}
MISC[0x2023] = MISC[0x25B8]                                                          # ‣
UNKNOWN = art(3, '.#####.. .#...#.. .#...#.. .#...#.. .#...#.. .#...#.. .#...#.. .#...#.. .#...#.. .#####..')
WIDE_BOX_L = art(3, '.####### .#...... .#...... .#...... .#..#### .#..#... .#...... .#...... .#...... .#######')
WIDE_BOX_R = art(3, '#######. ......#. ......#. ......#. ##....#. ......#. ......#. ......#. ......#. #######.')

# DEC special graphics (ESC ( 0): bytes 0x5F-0x7E -> code points
DEC_GRAPHICS = [0x00A0, 0x25C6, 0x2592, 0x2409, 0x240C, 0x240D, 0x240A, 0x00B0, 0x00B1, 0x2424, 0x240B,
                0x2518, 0x2510, 0x250C, 0x2514, 0x253C, 0x23BA, 0x23BB, 0x2500, 0x23BC, 0x23BD, 0x251C,
                0x2524, 0x2534, 0x252C, 0x2502, 0x2264, 0x2265, 0x03C0, 0x2260, 0x00A3, 0x00B7]

# Characters that take no cell, and characters that take two (a pragmatic subset of wcwidth)
ZERO_WIDTH = [(0x0300, 0x036F), (0x1AB0, 0x1AFF), (0x1DC0, 0x1DFF), (0x200B, 0x200F), (0x2028, 0x202E),
              (0x2060, 0x2064), (0x20D0, 0x20FF), (0xFE00, 0xFE0F), (0xFE20, 0xFE2F), (0xFEFF, 0xFEFF),
              (0xE0000, 0xE01EF)]
WIDE = [(0x1100, 0x115F), (0x231A, 0x231B), (0x2329, 0x232A), (0x23E9, 0x23EC), (0x23F0, 0x23F0),
        (0x23F3, 0x23F3), (0x25FD, 0x25FE), (0x2614, 0x2615), (0x2648, 0x2653), (0x267F, 0x267F),
        (0x2693, 0x2693), (0x26A1, 0x26A1), (0x26AA, 0x26AB), (0x26BD, 0x26BE), (0x26C4, 0x26C5),
        (0x26CE, 0x26CE), (0x26D4, 0x26D4), (0x26EA, 0x26EA), (0x26F2, 0x26F3), (0x26F5, 0x26F5),
        (0x26FA, 0x26FA), (0x26FD, 0x26FD), (0x2705, 0x2705), (0x270A, 0x270B), (0x2728, 0x2728),
        (0x274C, 0x274C), (0x274E, 0x274E), (0x2753, 0x2755), (0x2757, 0x2757), (0x2795, 0x2797),
        (0x27B0, 0x27B0), (0x27BF, 0x27BF), (0x2B1B, 0x2B1C), (0x2B50, 0x2B50), (0x2B55, 0x2B55),
        (0x2E80, 0x303E), (0x3041, 0x33FF), (0x3400, 0x4DBF), (0x4E00, 0x9FFF), (0xA000, 0xA4CF),
        (0xA960, 0xA97F), (0xAC00, 0xD7A3), (0xF900, 0xFAFF), (0xFE10, 0xFE19), (0xFE30, 0xFE6F),
        (0xFF00, 0xFF60), (0xFFE0, 0xFFE6), (0x1F004, 0x1F004), (0x1F0CF, 0x1F0CF), (0x1F18E, 0x1F18E),
        (0x1F191, 0x1F19A), (0x1F200, 0x1F251), (0x1F300, 0x1F64F), (0x1F680, 0x1F6FF),
        (0x1F7E0, 0x1F7EB), (0x1F90C, 0x1F9FF), (0x1FA70, 0x1FAFF), (0x20000, 0x2FFFD), (0x30000, 0x3FFFD)]


def build_font():
    """-> (glyphs, misc_slot): glyphs[0..511] are 16 row bytes each; misc_slot maps code points."""
    glyphs = [[0] * H for _ in range(512)]
    for ch, (start, text) in ASCII.items():
        glyphs[ord(ch)] = art(start, text)
    for cp, (start, text) in LATIN1.items():
        glyphs[cp] = art(start, text)
    for cp, (base, accent) in COMPOSED.items():
        glyphs[cp] = compose(base, accent)
    for cp in range(0x2500, 0x2580):
        glyphs[0x100 + cp - 0x2500] = box_glyph(cp)
    for cp in range(0x2580, 0x25A0):
        glyphs[0x180 + cp - 0x2580] = block_glyph(cp)
    glyphs[REPLACEMENT], glyphs[WIDE_L], glyphs[WIDE_R] = UNKNOWN, WIDE_BOX_L, WIDE_BOX_R
    free = [g for g in list(range(0x04, 0x20)) + list(range(0x7F, 0xA0)) + list(range(0x1A0, 0x200))]
    misc_slot = {}
    for cp in sorted(MISC):
        misc_slot[cp] = free.pop(0)
        glyphs[misc_slot[cp]] = MISC[cp]
    return glyphs, misc_slot


GLYPHS, MISC_SLOT = build_font()


def uni_glyph(cp):
    """Code point -> (glyph, width); width 0 means the character takes no cell."""
    if cp < 0x20 or 0x7F <= cp < 0xA0:
        return 0, 0
    if cp < 0x100:
        return cp, 1
    if 0x2500 <= cp < 0x2580:
        return 0x100 + cp - 0x2500, 1
    if 0x2580 <= cp < 0x25A0:
        return 0x180 + cp - 0x2580, 1
    if 0x2800 <= cp < 0x2900:
        return 0x200 + cp - 0x2800, 1
    if cp in MISC_SLOT:
        return MISC_SLOT[cp], 1
    if any(lo <= cp <= hi for lo, hi in ZERO_WIDTH):
        return 0, 0
    if any(lo <= cp <= hi for lo, hi in WIDE):
        return WIDE_L, 2
    return REPLACEMENT, 1


def dec_glyph(b):
    """Byte 0x5F-0x7E in the DEC special graphics set -> glyph."""
    return uni_glyph(DEC_GRAPHICS[b - 0x5F])[0]


def glyph_rows(g):
    """16 row bytes of glyph g (0-0x2FF) as the renderer draws it."""
    return braille_glyph(g & 0xFF) if g >= 0x200 else GLYPHS[g]


# ------------------------------------------------------------------ colours
BASE16 = [
    (0x0C, 0x0F, 0x14),  # 0 black (the default background)
    (0xE0, 0x50, 0x58),  # 1 red
    (0x7D, 0xC8, 0x5A),  # 2 green
    (0xE5, 0xB5, 0x58),  # 3 yellow
    (0x4E, 0x8E, 0xE6),  # 4 blue
    (0xC1, 0x6C, 0xDE),  # 5 magenta
    (0x46, 0xB9, 0xC8),  # 6 cyan
    (0xC8, 0xCD, 0xD6),  # 7 white (the default text colour)
    (0x58, 0x60, 0x70),  # 8 bright black
    (0xFF, 0x6E, 0x76),  # 9 bright red
    (0xA0, 0xE6, 0x78),  # 10 bright green
    (0xFF, 0xD6, 0x6E),  # 11 bright yellow
    (0x6E, 0xAF, 0xFF),  # 12 bright blue
    (0xDE, 0x8C, 0xFF),  # 13 bright magenta
    (0x64, 0xDC, 0xEB),  # 14 bright cyan
    (0xF5, 0xF7, 0xFA),  # 15 bright white
]
CUBE = [0, 95, 135, 175, 215, 255]
PALETTE = BASE16 + [(CUBE[i // 36], CUBE[i // 6 % 6], CUBE[i % 6]) for i in range(216)] + \
          [(8 + 10 * i,) * 3 for i in range(24)]


def rgb256(r, g, b):
    """Truecolour -> nearest-ish xterm-256 index, exactly as terminal.v does it."""
    if max(r, g, b) - min(r, g, b) < 16:
        v = (r + 2 * g + b) >> 2
        if v < 8:
            return 16
        if v > 238:
            return 231
        return 232 + (((v - 3) * 13) >> 7)

    def q(c):
        return 0 if c < 48 else 1 if c < 115 else 2 if c < 155 else 3 if c < 195 else 4 if c < 235 else 5
    return 16 + 36 * q(r) + 6 * q(g) + q(b)
