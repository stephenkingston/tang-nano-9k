# Bouncing anti-aliased logo
NAME := logo
SRC  := logo.v
DATA := logo.hex
include ../common/rules.mk

logo.hex: logo_gen.py
	python3 logo_gen.py
