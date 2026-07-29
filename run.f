//============================================================================
// run.f -- Xcelium filelist for the quantized linear-layer testbench
//----------------------------------------------------------------------------
// A filelist collects the source files (and any options) so they don't have to
// be retyped on every xrun command line. Invoke it with -f:
//
//   mkdir -p sim                                  <-- REQUIRED, see note below
//
//   xrun -f run.f -access +rwc                    full regression (1704 checks)
//   xrun -f run.f -access +rwc -define QUICK -gui waveform run  (104 checks)
//   xrun -f run.f -access +rwc -define INJECT_BUG bug injection (non-zero fails)
//
// NOTE: the testbench calls $dumpfile("sim/linear_layer.vcd"), so the sim/
// directory must exist before you run or the dump will fail. Run `mkdir -p sim`
// once after creating the files.
//
// Paths are relative to the directory xrun is launched from (the repo root).
//============================================================================

// Match the `timescale directive in the sources
-timescale 1ns/1ps

// ---- RTL (design under test) ----
// mac.v must come before linear_layer.v is elaborated; xrun resolves module
// order automatically, but listing bottom-up keeps the dependency obvious.
rtl/mac.v
rtl/linear_layer.v

// ---- Testbench ----
tb/tb_linear_layer.v
