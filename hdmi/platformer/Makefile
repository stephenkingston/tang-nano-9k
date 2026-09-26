# NANO QUEST: an NES-style platformer
NAME := platformer
SRC  := platformer.v
DATA := plat_params.vh $(addprefix plat_,$(addsuffix .hex,palette tiles slots sprites font logo rows text level spawns))
include ../common/rules.mk

$(DATA) &: platformer_gen.py
	python3 platformer_gen.py

# The bot plays the game (it must reach the flag), then a few screens are rendered to PNG
FRAMES := title:TICKS=60 card:START=1,TICKS=40 play:START=1,TICKS=400 later:START=1,TICKS=1500 \
	break:START=1,SFX=8 mushroom:START=1,FETCH=1,SFX=9,AFTER=40 big:START=1,FETCH=1,SFX=10,AFTER=200 \
	clear:START=1,UNTIL=4
sim: $(DATA)
	iverilog -g2005 -I. -s plat_game_tb -o plat_game_tb.vvp plat_game_tb.v platformer.v
	vvp -n plat_game_tb.vvp
	@for f in $(FRAMES); do \
		name=$${f%%:*}; params=$$(echo $${f#*:} | tr ',' ' ' | sed 's/\([A-Z]*=\)/-P plat_frame_tb.\1/g'); \
		iverilog -g2005 -I. -s plat_frame_tb $$params -o plat_frame_tb.vvp plat_frame_tb.v platformer.v && \
		vvp -n plat_frame_tb.vvp && python3 ../common/frame2png.py plat_frame.hex plat_$$name.png || exit 1; \
	done

# Record a gameplay GIF from the Verilog (the bot plays), using all CPU cores
gif: $(DATA)
	python3 plat_gif.py --out ../../media/nano-quest.gif

.PHONY: sim gif
