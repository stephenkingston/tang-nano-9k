# Parallax pixel-art sunset over a lake
NAME := sunset
SRC  := scene.v scene_render.v
DATA := scene_params.vh $(addprefix scene_,$(addsuffix .hex,palette stars clouds mountains hills front sky ripple bird))
include ../common/rules.mk

$(DATA) &: scene_gen.py
	python3 scene_gen.py

# Render frame FRAME in simulation and compare it with the Python model
FRAME ?= 1200
sim: $(DATA)
	iverilog -g2005 -I. -s scene_tb -P scene_tb.FRAME=$(FRAME) -o scene_tb.vvp scene_tb.v scene_render.v
	vvp -n scene_tb.vvp
	python3 scene_gen.py --check scene_frame.hex --frame $(FRAME)

# Render the animation with the reference model: an MP4 (needs ffmpeg) and a GIF
video:
	python3 scene_video.py --seconds 30 --out ../../media/scene.mp4

gif:
	python3 scene_video.py --seconds 12 --scale 2 --step 3 --out ../../media/scene.gif

.PHONY: sim video gif
