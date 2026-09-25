# Build one of the HDMI designs:  make [DESIGN=scene|pong|logo|bars] [load|flash]
DESIGN  ?= scene

TOP     := top
DEVICE  := GW1NR-LV9QN88PC6/I5
FAMILY  := GW1N-9C
BOARD   := tangnano9k
CST     := tangnano9k.cst
# Placer seed; change it if the HDMI clock check below fails
SEED    ?= 1

EXTRA_pong := gowin_mult.v
SRC     := $(DESIGN).v dvi_tx.v tmds_encoder.v $(EXTRA_$(DESIGN))
DATA_logo := logo.hex
SCENE_DATA := scene_params.vh $(addprefix scene_,$(addsuffix .hex,palette stars clouds mountains hills front sky ripple bird))
DATA_scene := $(SCENE_DATA)
DATA_pong := pong_defs.vh

all: $(DESIGN).fs

$(DESIGN).json: $(SRC) $(DATA_$(DESIGN))
	yosys -q -l $(DESIGN)-yosys.log -p "read_verilog $(SRC); synth_gowin -top $(TOP) -json $@"

$(DESIGN)_pnr.json: $(DESIGN).json $(CST)
	nextpnr-himbaechel-gowin -q -l $(DESIGN)-nextpnr.log --seed $(SEED) --freq 25.2 --json $< --write $@ \
		--device $(DEVICE) --vopt family=$(FAMILY) --vopt cst=$(CST)
	@# The 126 MHz serial clock must reach CLKDIV over its dedicated route, or the
	@# serialisers' fast and pixel clocks can end up misaligned.
	@if grep -q "using dedicated routing" $(DESIGN)-nextpnr.log; then \
		rm -f $@; echo "ERROR: HDMI clock missed its dedicated route; rebuild with another SEED=n"; exit 1; fi

$(DESIGN).fs: $(DESIGN)_pnr.json
	gowin_pack -d $(FAMILY) -o $@ $<

logo.hex: logo_gen.py
	python3 logo_gen.py

$(SCENE_DATA) &: scene_gen.py
	python3 scene_gen.py

# Load into SRAM (lost on power cycle)
load: $(DESIGN).fs
	openFPGALoader -b $(BOARD) $<

# Write to on-board flash (persists across power cycles)
flash: $(DESIGN).fs
	openFPGALoader -b $(BOARD) -f $<

# Simulate the TMDS encoder against a reference decoder
sim:
	iverilog -g2005 -o tb.vvp tmds_encoder_tb.v tmds_encoder.v && vvp -n tb.vvp

# Render frame FRAME of the scene in simulation and compare it with the Python model
FRAME ?= 1200
sim-scene: $(SCENE_DATA)
	iverilog -g2005 -s scene_tb -P scene_tb.FRAME=$(FRAME) -o scene_tb.vvp scene_tb.v scene.v
	vvp -n scene_tb.vvp
	python3 scene_gen.py --check scene_frame.hex --frame $(FRAME)

# Play thousands of frames of Pong game logic, then render a few frames to PNG
PONG_FRAMES := attract:TICKS=230 game:TICKS=1000,PLAYER=2 over:TICKS=20,PLAYER=1,OVER=1 green:TICKS=170,THEME=1
sim-pong: pong_defs.vh
	iverilog -g2005 -DSIM -s pong_game_tb -o pong_game_tb.vvp pong_game_tb.v pong.v gowin_mult.v
	vvp -n pong_game_tb.vvp
	@for f in $(PONG_FRAMES); do \
		name=$${f%%:*}; params=$$(echo $${f#*:} | tr ',' ' ' | sed 's/\([A-Z]*=\)/-P pong_frame_tb.\1/g'); \
		iverilog -g2005 -DSIM -s pong_frame_tb $$params -o pong_frame_tb.vvp pong_frame_tb.v pong.v gowin_mult.v && \
		vvp -n pong_frame_tb.vvp && python3 frame2png.py pong_frame.hex pong_$$name.png || exit 1; \
	done

# Render the scene animation to an MP4 with the reference model (needs ffmpeg)
video:
	python3 scene_video.py --seconds 30 --out ../media/scene.mp4

clean:
	rm -f *.json *.fs *.log *.vvp logo.hex logo_preview.png $(SCENE_DATA) scene_frame.* scene_preview.png pong_frame.hex pong_*.png

.PHONY: all load flash sim sim-scene sim-pong video clean
