# Xcelium (xrun) + SimVision — Linux, top to bottom

Cadence Xcelium single-step flow. The RTL is plain Verilog-2001, so `xrun`
compiles, elaborates, and simulates in one command.

## 0. Environment

```sh
# Source your site's Cadence setup (path varies per install)
source /opt/cadence/xcelium/setup.sh      # or module load xcelium
which xrun simvision                        # confirm both are on PATH
cd NeuralNetVerilog
mkdir -p sim
```

## 1. Run the layer testbench (all tests, expect 0 failures)

```sh
xrun -access +rwc -timescale 1ns/1ps \
     rtl/mac.v rtl/linear_layer.v tb/tb_linear_layer.v
```

Flags:
- `-access +rwc` — full read/write/connectivity access so every signal is
  probeable in SimVision.
- `-timescale 1ns/1ps` — matches the `` `timescale `` in the sources.

Expected tail:

```
 RESULT: 1704 checks, 0 failures
 *** ALL TESTS PASSED ***
```

## 2. Run the MAC unit testbench

```sh
xrun -access +rwc -timescale 1ns/1ps \
     rtl/mac.v tb/tb_mac.v
```

Expected: `509 checks, 0 failures  *** MAC TESTS PASSED ***`

## 3. Prove the testbench has teeth (bug injection)

```sh
xrun -access +rwc -timescale 1ns/1ps -define INJECT_BUG \
     rtl/mac.v rtl/linear_layer.v tb/tb_linear_layer.v
```

Expected: `RESULT: 1704 checks, 57 failures` — the checker catches the
corrupted weight. Re-run step 1 to confirm a clean pass.

The helper script `run_xrun.sh` wraps all of the above:

```sh
./run_xrun.sh          # layer TB
./run_xrun.sh mac      # MAC TB
./run_xrun.sh bug      # bug-injection run
./run_xrun.sh gui      # layer TB + open SimVision
```

## 4. Waveforms in SimVision

The testbench writes a VCD via `$dumpfile("sim/linear_layer.vcd")` +
`$dumpvars`. Two ways to view it:

**A. Open the dumped VCD after a run**

```sh
simvision sim/linear_layer.vcd &
```

**B. Native Xcelium waves (SHM database), full-visibility live debug**

```sh
xrun -gui -access +rwc -timescale 1ns/1ps \
     rtl/mac.v rtl/linear_layer.v tb/tb_linear_layer.v
```

In the SimVision GUI:
1. **Design Browser** (left) → expand `tb_linear_layer` → `u_relu`.
2. Select signals `state`, `i_cnt`, `j_cnt`, `mac_acc`, `busy`, `done`,
   `y_flat` → right-click → **Send to Waveform**.
3. Also add `u_mac` → `acc`, `clr`, `en`, `a`, `b` to watch the MAC accumulate.
4. Click **Run** (or `run` in the console) to simulate to `$finish`.
5. **Zoom Fit** (or `F` key). Each neuron shows: `i_cnt` sweeping 0→NIN−1 in
   `S_COMPUTE` while `mac_acc` builds up, then one `S_REQUANT` cycle where
   `y_flat` updates.

Useful signals to trace one dot product:
- `state` — IDLE → COMPUTE (×NIN) → REQUANT, per neuron.
- `mac_acc` — should equal Σ W[j][i]·x[i] at the end of each neuron's COMPUTE.
- `biased`, `shifted`, `q`, `act` (combinational requant chain) — the
  shift/round/clamp/ReLU pipeline for the current neuron.
- `done` — 1-cycle pulse when the last neuron is stored.
