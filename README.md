# Tang Nano 9K experiments

FPGA designs for the Sipeed Tang Nano 9K (Gowin GW1NR-9C), built entirely with the open-source
toolchain. They go from blinking LEDs up to a full-screen animated pixel-art scene that the
FPGA renders live over HDMI.

![Pixel-art sunset rendered by the FPGA](media/scene.png)

**[Watch 30 seconds of the animation (media/scene.mp4)](media/scene.mp4).** The video was rendered
with the Python reference model, which matches the hardware pixel for pixel, so it is exactly
what the board shows from power-up.

## Designs

| Where | What it does |
|---|---|
| `blink/` | The six onboard LEDs fill up one at a time, then empty in reverse |
| `hdmi/`, `DESIGN=bars` | 640×480 colour bars |
| `hdmi/`, `DESIGN=logo` | An anti-aliased logo bouncing around the screen; the LEDs flash on a perfect corner hit |
| `hdmi/`, `DESIGN=scene` (default) | A parallax pixel-art sunset over a lake |

### The scene

The scene is 320×240 pixels, each drawn as a 2×2 block on a 640×480 @ 60 Hz screen. There is no
frame buffer: the FPGA computes the colour of every pixel as the screen is scanned out, 25.2
million times a second.

- **Sky:** Bayer-dithered sunset gradient, a sun with a dithered glow, and a star map with twinkling stars.
- **Layers:** clouds, mountains, forested hills and a foreground shore are 512-pixel-wide strips in
  block RAM (2 bits per pixel). Each scrolls at its own speed for parallax depth.
- **Water:** the bottom third mirrors everything above the horizon. A ripple table shifts each row
  sideways by an amount that grows towards the viewer, and hashed sparkles glitter under the sun.
- **Birds:** a flock of three two-frame sprites flaps across the sky.
- **Colour:** every layer resolves to one of 64 palette entries; the water uses darker, bluer copies
  of the scene colours.

It uses 23 of the 26 block RAMs and about 11% of the logic, and meets timing at 43 MHz against
the 25.2 MHz pixel clock.

### HDMI output

`hdmi/dvi_tx.v` generates DVI (which every HDMI monitor accepts) with no external video chip. The
PLL turns the 27 MHz oscillator into a 126 MHz serial clock, `CLKDIV` divides it by 5 to the
25.2 MHz pixel clock, `tmds_encoder.v` does the TMDS 8b/10b encoding, and `OSER10` serialisers
drive the HDMI pins through emulated-LVDS buffers. A design only supplies a colour for each
`(x, y)` a fixed number of clocks later.

## Toolchain

Tested on Ubuntu 26.04, which packages everything:

```sh
sudo apt install make yosys nextpnr-himbaechel nextpnr-himbaechel-gowin-chipdb python3-apycula \
    openfpgaloader iverilog python3-pil fonts-dejavu-core ffmpeg
sudo usermod -aG dialout $USER     # for the board's serial port
```

The place-and-route binary is called `nextpnr-himbaechel-gowin`. openFPGALoader installs a udev
rule that gives the `plugdev` group access to the board.

## Building

```sh
cd hdmi
make                      # build the scene (DESIGN=scene)
make load                 # load into SRAM (lost at power-off)
make flash                # write to flash (survives power-off)
make DESIGN=logo load     # or DESIGN=bars
```

`blink/` has the same `make`, `make load` and `make flash` targets.

The placer seed is fixed (`SEED=1`) because some placements stop the 126 MHz clock from reaching
`CLKDIV` over its dedicated route, which can break the video. The build checks for this and fails
with a message; rebuild with another `SEED=n` if it happens.

## Verification

- `make sim`: the TMDS encoder against an independent decoder: every byte value plus about 175,000
  random words, exact control tokens, and bounded DC balance.
- `make sim-scene FRAME=n`: renders frame `n` of `scene.v` in Icarus Verilog and compares all
  307,200 pixels with the Python model. Frames 7, 1200 and 23456 match exactly.
- `make video`: renders `media/scene.mp4` from the model.

## Files in `hdmi/`

| File | Purpose |
|---|---|
| `dvi_tx.v` | Clocks, 640×480 timing, TMDS encoding and serialisation |
| `tmds_encoder.v`, `tmds_encoder_tb.v` | DVI 8b/10b encoder and its testbench |
| `bars.v`, `logo.v`, `scene.v` | The three designs (`top` module in each) |
| `logo_gen.py` | Draws the logo bitmap from DejaVu Sans Bold |
| `scene_gen.py` | Scene art, palette and layout, plus the reference model of `scene.v` |
| `scene_tb.v` | Dumps one simulated frame of `scene.v` for comparison with the model |
| `scene_video.py` | Renders the animation to MP4 with the model |
| `tangnano9k.cst` | Pin constraints: clock, HDMI pairs, LEDs |
