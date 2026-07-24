#!/bin/sh
#============================================================================
# run_xrun.sh -- Cadence Xcelium compile+run for the quantized linear layer
#----------------------------------------------------------------------------
# Usage:
#   ./run_xrun.sh              # run the layer testbench (all tests, 0 fails)
#   ./run_xrun.sh bug          # inject a bug -> prove the TB catches it
#   ./run_xrun.sh mac          # run the MAC unit testbench only
#   ./run_xrun.sh gui          # run layer TB and open SimVision on the VCD
#============================================================================
set -e
mkdir -p sim

RTL="rtl/mac.v rtl/linear_layer.v"
LAYER_TB="tb/tb_linear_layer.v"
MAC_TB="tb/tb_mac.v"

# -sv           : allow the (Verilog-2001) sources, tolerant parse
# -access +rwc  : full signal visibility for SimVision waveform debug
# -timescale    : match the `timescale in the sources
COMMON="-access +rwc -timescale 1ns/1ps"

case "$1" in
  mac)
    xrun $COMMON $RTL $MAC_TB
    ;;
  bug)
    xrun $COMMON -define INJECT_BUG $RTL $LAYER_TB
    ;;
  gui)
    xrun $COMMON $RTL $LAYER_TB
    simvision sim/linear_layer.vcd &
    ;;
  *)
    xrun $COMMON $RTL $LAYER_TB
    ;;
esac
