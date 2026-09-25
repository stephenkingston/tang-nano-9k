# Neon Pong over the pixel-art sunset, on a curved CRT
NAME := pong-sunset
SRC  := pong.v ../common/gowin_mult.v ../sunset/scene_render.v
DEPS := pong_defs.vh
PONG_DATA  := pong_pal.vh $(addprefix pong_,$(addsuffix .hex,solid add glow flash grid div6))
SCENE_DATA := scene_params.vh $(addprefix scene_,$(addsuffix .hex,palette stars clouds mountains hills front sky ripple bird))
DATA := $(PONG_DATA) $(SCENE_DATA)
include ../common/rules.mk

$(PONG_DATA) &: pong_gen.py
	python3 pong_gen.py

# The sunset's art, generated here so its ROM files sit next to this build
$(SCENE_DATA) &: ../sunset/scene_gen.py
	python3 ../sunset/scene_gen.py

# Play thousands of frames of game logic, then render a few frames to PNG
FRAMES := attract:TICKS=230 hit:TICKS=700,PLAYER=2,HIT=1 point:TICKS=20,PLAYER=1,POINT=1 \
	over:TICKS=20,PLAYER=1,OVER=1 neon:TICKS=150,THEMES=1 green:TICKS=150,THEMES=2
SIMSRC := pong.v ../common/gowin_mult.v ../sunset/scene_render.v
sim: $(DATA)
	iverilog -g2005 -I. -DSIM -s pong_game_tb -o pong_game_tb.vvp pong_game_tb.v $(SIMSRC)
	vvp -n pong_game_tb.vvp
	@for f in $(FRAMES); do \
		name=$${f%%:*}; params=$$(echo $${f#*:} | tr ',' ' ' | sed 's/\([A-Z]*=\)/-P pong_frame_tb.\1/g'); \
		iverilog -g2005 -I. -DSIM -s pong_frame_tb $$params -o pong_frame_tb.vvp pong_frame_tb.v $(SIMSRC) && \
		vvp -n pong_frame_tb.vvp && python3 ../common/frame2png.py pong_frame.hex pong_$$name.png || exit 1; \
	done

.PHONY: sim
