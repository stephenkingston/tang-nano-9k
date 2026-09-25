TOP     := top
DEVICE  := GW1NR-LV9QN88PC6/I5
FAMILY  := GW1N-9C
BOARD   := tangnano9k
CST     := tangnano9k.cst
SRC     := blink.v

all: blink.fs

blink.json: $(SRC)
	yosys -q -l yosys.log -p "read_verilog $(SRC); synth_gowin -top $(TOP) -json $@"

blink_pnr.json: blink.json $(CST)
	nextpnr-himbaechel-gowin -q -l nextpnr.log --json $< --write $@ \
		--device $(DEVICE) --vopt family=$(FAMILY) --vopt cst=$(CST)

blink.fs: blink_pnr.json
	gowin_pack -d $(FAMILY) -o $@ $<

# Load into SRAM (lost on power cycle)
load: blink.fs
	openFPGALoader -b $(BOARD) $<

# Write to on-board flash (persists across power cycles)
flash: blink.fs
	openFPGALoader -b $(BOARD) -f $<

clean:
	rm -f blink.json blink_pnr.json blink.fs *.log

.PHONY: all load flash clean
