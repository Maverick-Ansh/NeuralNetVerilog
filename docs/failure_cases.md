# Failure-case table

Each test in `tb/tb_linear_layer.v` targets a specific failure bucket. Every
output is checked bit-for-bit against the pure-Verilog golden model. The `lin`
DUT (EN_RELU=0) exists so clamp-low (`-128`) is observable — ReLU would mask it
as `0`.

| Test | Stimulus | Failure bucket | What it proves |
|------|----------|----------------|----------------|
| **T1-basic** | small signed W, mixed-sign X, zero bias | functional baseline | dot product + requant path correct for ordinary values |
| **T2-zero-input** | X = all 0 | all-zero input | acc = 0 → output = bias-only path; no spurious accumulation |
| **T3-maxmag-neg** | W = −128, X = 127 | max-magnitude weights, overflow-forcing, clamp low | large negative sum saturates: `lin → −128`, `relu → 0` |
| **T4-maxmag-pos** | W = 127, X = 127 | max-magnitude weights, overflow-forcing, clamp high | large positive sum saturates to `+127` |
| **T5-sat-high** | bias = +1,000,000 | saturation / clamp high (bias path) | requant clamps huge positive to `+127` |
| **T6-sat-low** | bias = −1,000,000 | saturation / clamp low + ReLU on negative | `lin → −128` (clamp low), `relu → 0` (ReLU zeroes it) |
| **T7-relu-neg** | bias = −300 (≈ −1 after >>8) | ReLU on negative values | `lin → −1`, `relu → 0`; ReLU acts on a *mild* negative, not just a clamp |
| **T8-round-edge** | s = 128 vs s = 127 across neurons | requantize rounding boundary | round-half-up: `(128+128)>>8 = 1`, `(127+128)>>8 = 0` — exact tie boundary |
| **T9a/T9b-b2b** | two random ops, no reset between | back-to-back operations | second op starts after `done` with correct state; no stale accumulator |
| **T10a/T10b** | preload weights, run, mutate 4 weights, re-run | weight-load timing | re-run reflects new weights → no stale data, load path timing correct |
| **T11-reset** | `start`, interrupt after 3 cycles, assert reset mid-op | reset mid-operation | DUT returns to idle (`busy=0`); a clean op afterward is still correct |
| **T12-rand-small** | bounded W,X ∈ [−40,40], bias ∈ [−4096,4096], ×100 | mid-range regression | exercises non-saturating requant, rounding, ReLU on real negatives |
| **T12-rand-full** | full-width random W,X,bias, ×100 | saturation regression | exercises clamp high/low under adversarial random vectors |

## Bug-injection proof (TB has teeth)

Compile with `+define+INJECT_BUG` (`make bug`). The testbench corrupts **DUT
weight[0]** on load while the golden model keeps the correct value. Result:

```
RESULT: 1704 checks, 57 failures
*** 57 FAILURE(S) DETECTED ***
```

Every test whose neuron 0 depends on weight[0] flags a mismatch — proving the
checker actually compares and would catch a real RTL defect. The clean run
(`make`) reports `1704 checks, 0 failures`.

## Coverage summary

| Requirement | Covered by |
|-------------|-----------|
| reset mid-op | T11 |
| requantize rounding boundary | T8 |
| saturation / clamp high | T4, T5 |
| saturation / clamp low | T3, T6 (observed on `lin` DUT) |
| ReLU on negative values | T6, T7, T12-rand-small |
| overflow-forcing values | T3, T4, T12-rand-full |
| all-zero input | T2 |
| max-magnitude weights | T3, T4 |
| back-to-back operations | T9 |
| weight-load timing | T10 |
| MAC primitive (clr/en/hold/reset, signed extremes) | `tb/tb_mac.v` |
