# NeuralNetVerilog — Quantized Linear-Layer Core

Parameterized Verilog implementation of one neural-network linear layer in
hardware, verified end-to-end against a pure-Verilog golden model.

```
y = activation( requantize( W·x + b ) )
```

Target: Cadence Xcelium + SimVision on Linux. RTL is plain Verilog-2001
(also runs on Icarus Verilog, which is how CI verification here was done).

---

## 1. What it computes (first principles)

A linear layer maps an input vector `x` (length `NIN`) to an output vector `y`
(length `NOUT`). For each output neuron `j`:

```
acc[j] = Σ_{i=0..NIN-1}  W[j][i] · x[i]        (integer dot product, wide accumulator)
s[j]   = acc[j] + b[j]                          (add bias)
r[j]   = clamp( round( s[j] >> SHIFT ) )        (requantize back to DW bits)
y[j]   = activation( r[j] )                     (ReLU = max(0, r))
```

- **W, x** are signed `DW`-bit integers (INT8 by default). Their product is
  `2·DW` bits; summing `NIN` of them needs a wide accumulator, so `acc` is
  `ACCW` bits (32 by default).
- **Requantize** brings the wide accumulator back down to `DW` bits:
  arithmetic shift-right by `SHIFT`, **round half-up** (add `1<<(SHIFT-1)`
  first), then **clamp** to the signed `DW` range `[-2^(DW-1), 2^(DW-1)-1]`.
- **ReLU** zeroes negatives: `max(0, r)`.

Everything is **signed** and the hardware path handles **overflow by
saturation** (clamp), which is what a real quantized inference core does.

---

## 2. Datapath (build up from the primitive)

The compute primitive is **one** signed multiply-accumulate (`mac.v`). It is
**time-multiplexed**: a single MAC instance is run `NIN × NOUT` times instead
of building `NOUT` parallel dot-product trees — cheap in gates, which is the
point for an ASIC.

```
                        ┌──────────────────────── linear_layer.v ───────────────────────┐
   load port  ───────►  │  w_mem[NOUT*NIN]   x_mem[NIN]   b_mem[NOUT]                     │
   (W / X / B)          │        │               │            │                          │
                        │        │  W[j][i]      │ x[i]       │ b[j]                      │
                        │        ▼               ▼            │                          │
                        │      ┌───────────────────┐          │                          │
   start ─────────────► │      │   MAC (1 instance)│          │                          │
                        │      │  acc += a*b       │          │                          │
   FSM + counters ────► │      └─────────┬─────────┘          │                          │
   (i over inputs,      │                │ acc (ACCW)         ▼                          │
    j over neurons)     │                └──────► (+) ──► >>SHIFT+round ──► clamp ──► ReLU│──► y_flat
                        │                       biased        requantize         activate │    (NOUT*DW)
                        └────────────────────────────────────────────────────────────────┘
```

**Control:** an FSM (`IDLE → COMPUTE → REQUANT`) with two counters —
`i` loops over inputs (inner), `j` loops over neurons (outer). Address
generation indexes `w_mem[j*NIN + i]` and `x_mem[i]`. The MAC is cleared on
the first input of each neuron (`clr` loads the first product), accumulates
the rest, then the `REQUANT` state adds bias, requantizes, activates, and
stores `y_mem[j]`.

---

## 3. Parameters

| Param | Default | Meaning |
|-------|---------|---------|
| `NIN` | 4 | number of inputs |
| `NOUT` | 4 | number of neurons / outputs |
| `DW` | 8 | operand width, signed (INT8) |
| `ACCW` | 32 | accumulator / bias width, signed |
| `SHIFT` | 8 | requantize arithmetic right-shift |
| `EN_RELU` | 1 | 1 = ReLU activation, 0 = identity |

Small 4×4 default keeps weights in registers cheap. All widths and loop bounds
derive from the params (address widths via a `clog2` function), so it scales.

---

## 4. Files

```
rtl/mac.v                 signed MAC primitive (the reused compute unit)
rtl/linear_layer.v        layer core: storage + FSM + requantize + ReLU
tb/tb_linear_layer.v      self-checking TB: golden model + all failure cases
tb/tb_mac.v               MAC unit testbench (primitive tested in isolation)
run_xrun.sh               Xcelium compile/run wrapper
Makefile                  Icarus Verilog convenience targets (used for CI here)
docs/failure_cases.md     failure-case table (test → what it proves)
docs/xcelium_simvision.md xrun commands + SimVision steps, top to bottom
```

---

## 5. How to run

### Cadence Xcelium (the deliverable simulator)

```sh
./run_xrun.sh          # layer testbench — expect: 1704 checks, 0 failures
./run_xrun.sh quick    # directed tests T1..T11 only — 104 checks, short waveform
./run_xrun.sh mac      # MAC unit testbench
./run_xrun.sh bug      # inject a bug → expect NON-ZERO failures (TB has teeth)
./run_xrun.sh gui      # quick run + SimVision live (use this for waveforms)
```

Full command detail and SimVision waveform steps: **`docs/xcelium_simvision.md`**.
Hand-derived expected outputs: **`docs/functional_table.md`**.

### Icarus Verilog (how it was verified in this container)

```sh
make        # layer TB     -> *** ALL TESTS PASSED ***  (1704 checks, 0 failures)
make quick  # directed TB  -> *** ALL TESTS PASSED ***  (104 checks, 0 failures)
make mac    # MAC TB       -> *** MAC TESTS PASSED ***  (509 checks, 0 failures)
make bug    # bug inject   -> *** N FAILURE(S) DETECTED ***  (N > 0)
```

---

## 6. Verification

Self-checking testbench with an **independent pure-Verilog golden model** — a
nested-loop reference using a 64-bit accumulator and plain math, computed
separately from the DUT and compared **bit-for-bit**. Stimulus via `$random`.
No Python.

Two DUT instances share every stimulus: `EN_RELU=1` (production) and
`EN_RELU=0` (identity), so clamp-low (`−128`) is directly observable instead of
being hidden by ReLU.

Failure buckets — reset mid-op, requant rounding boundary, saturation high/low,
ReLU on negatives, overflow-forcing values, all-zero input, max-magnitude
weights, back-to-back ops, weight-load timing — plus a 200-vector random sweep.
Full mapping in **`docs/failure_cases.md`**.

**Teeth:** `make bug` corrupts one DUT weight (not the golden copy); the checker
reports mismatches. Clean run reports 0. The *number* of mismatches depends on
how many random vectors involve the corrupted weight and on the simulator's
`$random`, so the pass criterion is **zero vs non-zero**, not a fixed count.

VCD (`sim/linear_layer.vcd`) is dumped for SimVision.

---

## 7. Results

```
Layer TB   : 1704 checks, 0 failures   *** ALL TESTS PASSED ***
Directed   :  104 checks, 0 failures   *** ALL TESTS PASSED ***  (make quick)
MAC TB     :  509 checks, 0 failures   *** MAC TESTS PASSED ***
Bug run    : 1704 checks, N > 0        *** caught ***
```

Check counts are deterministic (`213 cases × 4 neurons × 2 DUT instances =
1704`). Verified on Icarus Verilog; the RTL is plain Verilog-2001 and runs
identically under Xcelium.
