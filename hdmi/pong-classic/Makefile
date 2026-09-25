# Pong on a monochrome arcade CRT (white, green or amber phosphor)
NAME := pong-classic
SRC  := pong.v ../common/gowin_mult.v
DEPS := pong_defs.vh
# Seed 1 misses the HDMI clock's dedicated route for this design
SEED ?= 2
include ../common/rules.mk

# Play thousands of frames of game logic, then render a few frames to PNG
FRAMES := attract:TICKS=230 game:TICKS=1000,PLAYER=2 over:TICKS=20,PLAYER=1,OVER=1 green:TICKS=170,THEME=1
SIMSRC := pong.v ../common/gowin_mult.v
sim:
	iverilog -g2005 -I. -DSIM -s pong_game_tb -o pong_game_tb.vvp pong_game_tb.v $(SIMSRC)
	vvp -n pong_game_tb.vvp
	@for f in $(FRAMES); do \
		name=$${f%%:*}; params=$$(echo $${f#*:} | tr ',' ' ' | sed 's/\([A-Z]*=\)/-P pong_frame_tb.\1/g'); \
		iverilog -g2005 -I. -DSIM -s pong_frame_tb $$params -o pong_frame_tb.vvp pong_frame_tb.v $(SIMSRC) && \
		vvp -n pong_frame_tb.vvp && python3 ../common/frame2png.py pong_frame.hex pong_$$name.png || exit 1; \
	done

.PHONY: sim
