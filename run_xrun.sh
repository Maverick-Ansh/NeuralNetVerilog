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
#
# This is a thin wrapper around the filelists run.f / run_mac.f. Every target
# below is a single xrun command you can also type by hand -- the equivalent is
# printed in docs/xcelium_simvision.md.
#============================================================================
set -e
mkdir -p sim          # $dumpfile writes into sim/, so it must exist

# -f            : read the source list from a filelist
# -access +rwc  : full signal visibility for SimVision waveform debug
# (-timescale lives inside the filelists)
LAYER="-f run.f"
MAC="-f run_mac.f"
COMMON="-access +rwc"

case "$1" in
  mac)
    xrun $MAC $COMMON
    ;;
  quick)
    xrun $LAYER $COMMON -define QUICK
    ;;
  bug)
    xrun $LAYER $COMMON -define INJECT_BUG
    ;;
  gui)
    # QUICK: only the directed cases in the functional table, so the whole
    # simulation is ~9.7 us and fits on one readable SimVision screen.
    xrun $LAYER $COMMON -define QUICK -gui
    ;;
  gui-full)
    xrun $LAYER $COMMON -gui
    ;;
  *)
    xrun $LAYER $COMMON
    ;;
esac
