# Shared build rules for the HDMI designs. A design's Makefile sets
#   NAME  output file name        SRC   its Verilog files (besides the shared HDMI core)
#   DEPS  files it `includes      DATA  files generated before synthesis
# and then includes this file. Run make from the design's folder:
#   make          build NAME.fs          make load    load into SRAM (lost on power cycle)
#   make flash    write to flash         make clean   remove build and generated files
COMMON  := ../common
DEVICE  := GW1NR-LV9QN88PC6/I5
FAMILY  := GW1N-9C
BOARD   := tangnano9k
CST     := $(COMMON)/tangnano9k.cst
CORE    := $(COMMON)/dvi_tx.v $(COMMON)/tmds_encoder.v
# Placer seed; change it if the HDMI clock check below fails
SEED    ?= 1
# Pixel clock in MHz, for timing analysis
FREQ    ?= 25.2
# Extra synth_gowin options
SYNTH_OPTS ?=

all: $(NAME).fs

$(NAME).json: $(SRC) $(CORE) $(DEPS) $(DATA)
	yosys -q -l $(NAME)-yosys.log -p "read_verilog -I. $(SRC) $(CORE); synth_gowin -top top $(SYNTH_OPTS) -json $@"

$(NAME)_pnr.json: $(NAME).json $(CST)
	nextpnr-himbaechel-gowin -q -l $(NAME)-nextpnr.log --seed $(SEED) --freq $(FREQ) --json $< --write $@ \
		--device $(DEVICE) --vopt family=$(FAMILY) --vopt cst=$(CST)
	@# The 126 MHz serial clock must reach CLKDIV over its dedicated route, or the
	@# serialisers' fast and pixel clocks can end up misaligned.
	@if grep -q "using dedicated routing" $(NAME)-nextpnr.log; then \
		rm -f $@; echo "ERROR: HDMI clock missed its dedicated route; rebuild with another SEED=n"; exit 1; fi

$(NAME).fs: $(NAME)_pnr.json
	gowin_pack -d $(FAMILY) -o $@ $<

load: $(NAME).fs
	openFPGALoader -b $(BOARD) $<

flash: $(NAME).fs
	openFPGALoader -b $(BOARD) -f $<

# Check the TMDS encoder against an independent decoder
sim-tmds:
	iverilog -g2005 -o tmds_tb.vvp $(COMMON)/tmds_encoder_tb.v $(COMMON)/tmds_encoder.v && vvp -n tmds_tb.vvp

clean:
	rm -f *.json *.fs *.log *.vvp *.hex *.png $(DATA)

.PHONY: all load flash sim-tmds clean
