# NANO TERM: a serial terminal on the HDMI port
NAME := terminal
SRC  := terminal.v
DATA := term_params.vh term_uni.vh $(addprefix term_,$(addsuffix .hex,font palette bars cells uni say))
# Serial speed at power-up; the board then follows whatever speed the sender uses
BAUD ?= 2000000
# 720x480 needs a 27 MHz pixel clock
FREQ := 27
# Without the wide-LUT muxes the engine maps to far fewer LUTs, which it needs to fit
SYNTH_OPTS := -nowidelut
# A placer seed whose placement gives the HDMI clock its dedicated route (many do not), and
# whose build passed `make check` on the board
SEED ?= 2
PORT ?= /dev/ttyUSB1
include ../common/rules.mk

# Regenerate when BAUD changes
.baud-$(BAUD):
	rm -f .baud-*
	touch $@

$(DATA) &: term_gen.py term_font.py term_model.py .baud-$(BAUD)
	python3 term_gen.py $(BAUD)

# The engine against the Python model (features, random streams), the serial port at the
# bit level, and frames compared pixel for pixel with the model's renderer
sim: $(DATA)
	python3 term_test.py

# With the board loaded: your shell on the screen, the demo, or a check against the model
shell type demo check:
	./nanoterm.py --port $(PORT) --baud $(BAUD) $@

# The README pictures, rendered by the model
media: $(DATA)
	python3 term_media.py --baud $(BAUD) --out ../../media

.PHONY: sim shell type demo check media
