#!/bin/sh
#============================================================================
# run_xrun.sh -- Cadence Xcelium compile+run for the quantized linear layer
#----------------------------------------------------------------------------
# Usage:
#   ./run_xrun.sh              # full layer testbench (1704 checks, 0 fails)
#   ./run_xrun.sh quick        # directed tests T1..T11 only -- SHORT waveform
#   ./run_xrun.sh bug          # inject a bug -> prove the TB catches it
#   ./run_xrun.sh mac          # run the MAC unit testbench only
#   ./run_xrun.sh gui          # QUICK run + open SimVision live (lab record)
#   ./run_xrun.sh gui-full     # full run + open SimVision live
#============================================================================
set -e
mkdir -p sim

RTL="rtl/mac.v rtl/linear_layer.v"
LAYER_TB="tb/tb_linear_layer.v"
MAC_TB="tb/tb_mac.v"

# -access +rwc  : full signal visibility for SimVision waveform debug
# -timescale    : match the `timescale in the sources
COMMON="-access +rwc -timescale 1ns/1ps"

case "$1" in
  mac)
    xrun $COMMON $RTL $MAC_TB
    ;;
  quick)
    xrun $COMMON -define QUICK $RTL $LAYER_TB
    ;;
  bug)
    xrun $COMMON -define INJECT_BUG $RTL $LAYER_TB
    ;;
  gui)
    # QUICK: only the directed cases in the functional table, so the whole
    # simulation is ~9.7 us and fits on one readable SimVision screen.
    xrun -gui $COMMON -define QUICK $RTL $LAYER_TB
    ;;
  gui-full)
    xrun -gui $COMMON $RTL $LAYER_TB
    ;;
  *)
    xrun $COMMON $RTL $LAYER_TB
    ;;
esac
