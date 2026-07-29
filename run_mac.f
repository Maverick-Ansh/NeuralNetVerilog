//============================================================================
// run_mac.f -- Xcelium filelist for the MAC primitive unit testbench
//----------------------------------------------------------------------------
//   mkdir -p sim
//   xrun -f run_mac.f -access +rwc              expect 509 checks, 0 failures
//   xrun -f run_mac.f -access +rwc -gui         with SimVision
//
// The MAC is verified in isolation BEFORE it is trusted inside the layer core.
// Its control inputs (rst_n / clr / en) are few enough to enumerate exhaustively
// -- see the truth table in docs/functional_table.md, Part A.
//============================================================================

-timescale 1ns/1ps

// ---- RTL ----
rtl/mac.v

// ---- Testbench ----
tb/tb_mac.v
