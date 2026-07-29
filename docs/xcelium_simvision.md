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

Expected: `RESULT: 1704 checks, N failures` with **N > 0** — the checker catches
the corrupted weight. Re-run step 1 to confirm a clean pass.

`N` is not a fixed number: it depends on how many random vectors involve the
corrupted weight and on the simulator's `$random`. Record whatever your run
reports; the criterion is zero vs non-zero.

The helper script `run_xrun.sh` wraps all of the above:

```sh
./run_xrun.sh          # full layer TB    (1704 checks)
./run_xrun.sh quick    # directed T1..T11 (104 checks, ~9.7 us -- for waveforms)
./run_xrun.sh mac      # MAC TB
./run_xrun.sh bug      # bug-injection run
./run_xrun.sh gui      # quick run + SimVision live
./run_xrun.sh gui-full # full run + SimVision live
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
xrun -gui -access +rwc -timescale 1ns/1ps -define QUICK \
     rtl/mac.v rtl/linear_layer.v tb/tb_linear_layer.v
```

> **Use `-define QUICK` for waveform capture.** Without it the 200-vector random
> sweep runs and the simulation is ~150 µs long — the directed tests are then a
> 5% sliver at the far left and the screenshot is unreadable. With `QUICK` the
> whole run is **~9.7 µs** and contains exactly the cases in
> `functional_table.md`, so Zoom Fit gives a usable picture.

In the SimVision GUI:
1. **Design Browser** (left) → expand `tb_linear_layer` → `u_relu`.
2. Select signals `state`, `i_cnt`, `j_cnt`, `mac_acc`, `busy`, `done`,
   `y_flat` → right-click → **Send to Waveform**.
3. Also add `u_mac` → `acc`, `clr`, `en`, `a`, `b` to watch the MAC accumulate.
4. Click **Run** (or `run` in the console) to simulate to `$finish`.
5. **Zoom Fit** (or `F` key). Each neuron shows: `i_cnt` sweeping 0→NIN−1 in
   `S_COMPUTE` while `mac_acc` builds up, then one `S_REQUANT` cycle where
   `y_flat` updates.

### Setting up the waveform for the record

Right-click `y_flat` → **Set Radix → Signed** on both `u_relu` and `u_lin`, and
set `mac_acc` to signed as well. Without this the outputs display as unsigned
hex and `−4` reads as `fc`, which will not match the functional table.

Add a second group with `tb_linear_layer.u_lin.y_flat` alongside
`u_relu.y_flat` so the ReLU-vs-identity difference is visible in one shot — that
is the pair that demonstrates clamp-low `−128` being zeroed by ReLU.

One `run_case` takes ≈ 705 ns: 24 load writes (≈480 ns) + start pulse + 21
compute clocks (≈210 ns). So test *k* starts at roughly `30 + 705·k` ns.

Good screenshot windows:

| Window | Shows |
|---|---|
| `0 – 800 ns` | T1: one full 4-neuron pass, `mac_acc` building each dot product |
| around T3/T4 | saturation: `mac_acc` huge, `y_flat` pinned at `−128` / `+127` |
| around T8 | the rounding boundary: `y_lin` = `1,0,1,0` across the four neurons |

Use the **console log** to locate each test — every case prints its name and
outputs, so you can match a `[T3-maxmag-neg]` line to its time marker.

Useful signals to trace one dot product:
- `state` — IDLE → COMPUTE (×NIN) → REQUANT, per neuron.
- `mac_acc` — should equal Σ W[j][i]·x[i] at the end of each neuron's COMPUTE.
- `biased`, `shifted`, `q`, `act` (combinational requant chain) — the
  shift/round/clamp/ReLU pipeline for the current neuron.
- `done` — 1-cycle pulse when the last neuron is stored.
