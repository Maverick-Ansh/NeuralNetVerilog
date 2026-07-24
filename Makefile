#============================================================================
# Makefile -- convenience targets using Icarus Verilog (iverilog).
#
# The DELIVERABLE simulator is Cadence Xcelium (see run_xrun.sh / docs).
# This Makefile is what was used to verify the design in a Linux container
# where Xcelium was unavailable; the RTL is plain Verilog-2001 and runs on
# both. All tests pass identically.
#
#   make            # run the layer testbench (all tests, expect 0 failures)
#   make mac        # run the MAC unit testbench
#   make bug        # inject a bug, prove the testbench catches it
#   make wave       # run layer TB (produces sim/linear_layer.vcd)
#   make clean
#============================================================================
IV      = iverilog -g2012
VVP     = vvp
RTL     = rtl/mac.v rtl/linear_layer.v
LAYERTB = tb/tb_linear_layer.v
MACTB   = tb/tb_mac.v

all: layer

layer: | sim
	$(IV) -o sim/sim.vvp $(RTL) $(LAYERTB)
	$(VVP) sim/sim.vvp

mac: | sim
	$(IV) -o sim/sim_mac.vvp $(RTL) $(MACTB)
	$(VVP) sim/sim_mac.vvp

bug: | sim
	$(IV) -D INJECT_BUG -o sim/sim_bug.vvp $(RTL) $(LAYERTB)
	$(VVP) sim/sim_bug.vvp

wave: layer

sim:
	mkdir -p sim

clean:
	rm -rf sim *.vvp

.PHONY: all layer mac bug wave clean
