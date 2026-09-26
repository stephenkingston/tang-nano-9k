#!/usr/bin/env python3
"""Record the README pictures of NANO TERM with the Python model (which the simulations show
matches the hardware pixel for pixel).

  python3 term_media.py [--baud 2000000] [--out ../../media]

The demo (nanoterm.py demo) runs against a virtual clock and its bytes are delivered at the
serial port's real speed, so the GIF shows what the board shows, as fast as it shows it.
"""
import argparse
import os

import nanoterm
import term_model as tm
import term_test


class Link:
    """A virtual serial line: writes block for as long as the bytes take to send."""

    def __init__(self, baud):
        self.now = 0.0
        self.byte_time = 10.0 / baud
        self.events = []                                # (arrival time, bytes)

    def time(self):
        return self.now

    def sleep(self, s):
        self.now += s

    def write(self, fd, data):
        for i in range(0, len(data), 64):
            chunk = bytes(data[i:i + 64])
            self.now += len(chunk) * self.byte_time
            self.events.append((self.now, chunk))


def record_demo(baud, seconds):
    link = Link(baud)

    class Stop(Exception):
        pass

    class Clock:                                        # stands in for the time module
        @staticmethod
        def time():
            return link.now

        @staticmethod
        def sleep(s):
            link.now += s
            if link.now > seconds:
                raise Stop

        @staticmethod
        def strftime(fmt):
            m, s = divmod(int(link.now), 60)
            return f'12:{34 + m:02d}:{s:02d}'

    nanoterm.time = Clock
    nanoterm.write_all = link.write
    try:
        nanoterm.demo(None, argparse.Namespace(baud=baud))
    except Stop:
        pass
    return link.events


def frames(events, fps, start, stop, baud, theme=0, crt=False):
    term = tm.Term()                                    # the demo starts with a reset anyway
    out = []
    i = 0
    t = start
    while t < stop:
        while i < len(events) and events[i][0] <= t:
            term.feed(events[i][1])
            i += 1
        if t >= start:
            out.append(tm.render_term(term, theme=theme, crt=crt, cursor=False, baud=baud))
        t += 1.0 / fps
    return out


def save_gif(imgs, path, fps):
    from PIL import Image
    ims = []
    for img in imgs:
        im = Image.new('RGB', (tm.W, tm.H))
        im.putdata([p for line in img for p in line])
        ims.append(im.convert('P', palette=Image.ADAPTIVE, colors=128))
    ims[0].save(path, save_all=True, append_images=ims[1:], duration=int(1000 / fps), loop=0, optimize=True)
    print(f'wrote {path}: {len(ims)} frames')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--baud', type=int, default=2000000)
    ap.add_argument('--out', default=os.path.join('..', '..', 'media'))
    args = ap.parse_args()
    events = record_demo(args.baud, 70)
    b = args.baud
    save_gif(frames(events, 8, 1.0, 9.0, b), os.path.join(args.out, 'nano-term.gif'), 8)
    tm.save_png(frames(events, 1, 45.0, 46.0, b)[0], os.path.join(args.out, 'nano-term-colours.png'))
    tm.save_png(frames(events, 1, 66.0, 67.0, b, theme=1, crt=True)[0], os.path.join(args.out, 'nano-term-rain.png'))
    term = tm.Term()
    term.feed(term_test.term_gen.boot_ansi(args.baud).encode())
    tm.save_png(tm.render_term(term, baud=args.baud), os.path.join(args.out, 'nano-term-boot.png'))


if __name__ == '__main__':
    main()
