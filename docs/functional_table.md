# Functional Table

This is the reference table the simulated outputs are compared against, as
required by the functional-verification procedure (step 9: *"Compare the
simulated outputs with the expected outputs obtained from the functional
table"*).

## Why this is a functional table and not a truth table

A truth table enumerates every input combination. That is possible for
combinational logic with a handful of inputs; it is **not** possible here. This
design takes 16 weights + 4 inputs at 8 bits each plus 4 biases at 32 bits:

```
input space = 2^(16·8) × 2^(4·8) × 2^(4·32)  =  2^1152 combinations
```

Enumerating that is physically impossible. For an arithmetic datapath the
correct equivalent is a **functional table**: a set of applied input vectors
chosen to cover every distinct behaviour of the design, each with its expected
output **derived by hand from the defining equations** — not read back from the
simulator. That is what follows.

The defining equations (`DW=8`, `SHIFT=8`, so `MAXV=+127`, `MINV=−128`):

```
acc[j] = Σ_{i=0..3} W[j][i] · x[i]
s[j]   = acc[j] + b[j]
r[j]   = clamp( (s[j] + 128) >>> 8 ,  −128 .. +127 )      // round-half-up
y[j]   = EN_RELU ? max(0, r[j]) : r[j]
```

`>>>` is an **arithmetic** shift, so it rounds toward −∞ (floor), not toward
zero. This matters for every negative row below.

Two DUT instances receive identical stimulus:

| Instance | `EN_RELU` | Purpose |
|---|---|---|
| `u_relu` | 1 | production configuration |
| `u_lin`  | 0 | identity — makes clamp-low (`−128`) observable, which ReLU would otherwise mask as `0` |

---

## Part A — MAC primitive control table (`tb/tb_mac.v`)

The MAC's control inputs *are* few enough to enumerate. This is a genuine truth
table of the control decode:

| `rst_n` | `clr` | `en` | Action | Next `acc` |
|:---:|:---:|:---:|---|---|
| 0 | × | × | asynchronous reset | `0` |
| 1 | 1 | 1 | load first product of a new dot product | `a·b` |
| 1 | 0 | 1 | accumulate | `acc + a·b` |
| 1 | 1 | 0 | clear only | `0` |
| 1 | 0 | 0 | hold | `acc` |

Applied directed sequence and hand-computed expected accumulator:

| # | `clr` | `en` | `a` | `b` | `a·b` | Expected `acc` | Bucket |
|---|:---:|:---:|---:|---:|---:|---:|---|
| 1 | 1 | 1 | 10 | 3 | 30 | **30** | load |
| 2 | 0 | 1 | 5 | −4 | −20 | **10** | accumulate, mixed sign |
| 3 | 0 | 1 | −8 | 8 | −64 | **−54** | accumulate to negative |
| 4 | 0 | 0 | 0 | 0 | — | **−54** | hold (unchanged) |
| 5 | 1 | 0 | 99 | 99 | — | **0** | clear-only overrides operands |
| 6 | 1 | 1 | −128 | −128 | 16384 | **16384** | min × min → positive |
| 7 | 0 | 1 | 127 | 127 | 16129 | **32513** | max × max |
| 8 | 0 | 1 | −128 | 127 | −16256 | **16257** | mixed extreme |
| 9 | 0 | 1 | 127 | −128 | −16256 | **1** | mixed extreme, other order |
| 10 | `rst_n`→0 | | | | — | **0** | async reset mid-stream |

Followed by 500 randomized accumulate steps checked every cycle against a
64-bit golden accumulator.

---

## Part B — Linear-layer functional table (`tb/tb_linear_layer.v`)

Every row below is hand-derived from the equations above. `y_lin` is the
`EN_RELU=0` instance, `y_relu` the `EN_RELU=1` instance.

### T1 — basic mixed-sign values

`X = [100, −50, 25, −10]`, `B = [0,0,0,0]`

| j | `W[j][·]` | `acc[j]` | `(acc+128) >>> 8` | `y_lin[j]` | `y_relu[j]` |
|---|---|---:|---:|---:|---:|
| 0 | `1, 2, 3, −4` | 100−100+75+40 = **115** | 243 ≫ 8 = 0 | **0** | **0** |
| 1 | `5, −6, 7, 8` | 500+300+175−80 = **895** | 1023 ≫ 8 = 3 | **3** | **3** |
| 2 | `−1, −2, −3, −4` | −100+100−75+40 = **−35** | 93 ≫ 8 = 0 | **0** | **0** |
| 3 | `10, 20, −30, 40` | 1000−1000−750−400 = **−1150** | −1022 ≫ 8 = **−4** | **−4** | **0** |

Row 3 is the important one: `−1022/256 = −3.99`, and an arithmetic shift floors
it to **−4**, not −3. It also shows ReLU zeroing a mild negative.

### T2 — all-zero input

`W` as T1, `X = [0,0,0,0]`, `B = 0` → `acc = 0`, `(0+128)≫8 = 0`.

| | j0 | j1 | j2 | j3 |
|---|---:|---:|---:|---:|
| `y_lin` / `y_relu` | 0 | 0 | 0 | 0 |

Proves no spurious accumulation and that the accumulator is properly cleared.

### T3 — max-magnitude weights, negative (clamp low)

`W = −128` (all), `X = 127` (all), `B = 0`

```
acc = 4 × (−128 × 127) = −65024
(−65024 + 128) >>> 8 = −64896 >>> 8 = −254      (floor of −253.5)
clamp(−254) = −128
```

| | j0 | j1 | j2 | j3 |
|---|---:|---:|---:|---:|
| `y_lin` | −128 | −128 | −128 | −128 |
| `y_relu` | 0 | 0 | 0 | 0 |

### T4 — max-magnitude weights, positive (clamp high)

`W = 127`, `X = 127`, `B = 0`

```
acc = 4 × 16129 = 64516
(64516 + 128) >>> 8 = 252      →  clamp(252) = 127
```

| | j0 | j1 | j2 | j3 |
|---|---:|---:|---:|---:|
| `y_lin` / `y_relu` | 127 | 127 | 127 | 127 |

### T5 — saturation high via bias

`W = 0`, `X = 0`, `B = +1,000,000` → `acc = 0`

```
(1000000 + 128) >>> 8 = 3906   →  clamp = 127
```

| | j0 | j1 | j2 | j3 |
|---|---:|---:|---:|---:|
| `y_lin` / `y_relu` | 127 | 127 | 127 | 127 |

### T6 — saturation low via bias

`W = 0`, `X = 0`, `B = −1,000,000`

```
(−1000000 + 128) >>> 8 = −3906  →  clamp = −128
```

| | j0 | j1 | j2 | j3 |
|---|---:|---:|---:|---:|
| `y_lin` | −128 | −128 | −128 | −128 |
| `y_relu` | 0 | 0 | 0 | 0 |

### T7 — ReLU on a mild negative

`W = 0`, `X = 0`, `B = −300`

```
(−300 + 128) >>> 8 = −172 >>> 8 = −1     (floor of −0.67)
```

| | j0 | j1 | j2 | j3 |
|---|---:|---:|---:|---:|
| `y_lin` | −1 | −1 | −1 | −1 |
| `y_relu` | 0 | 0 | 0 | 0 |

Distinct from T6: here ReLU acts on a value that is **not** clamped, proving the
activation is separate from saturation.

### T8 — requantize rounding boundary

`X = [1,0,0,0]`, all `W = 0` except the one weight shown. Constructed so `s`
lands exactly on the round-half-up tie.

| j | `W[j][0]` | `B[j]` | `s = acc + b` | `(s + 128) >>> 8` | `y_lin` / `y_relu` |
|---|---:|---:|---:|---|---:|
| 0 | 127 | 1 | **128** | 256 ≫ 8 = 1 | **1** |
| 1 | 127 | 0 | **127** | 255 ≫ 8 = 0 | **0** |
| 2 | 100 | 28 | **128** | 256 ≫ 8 = 1 | **1** |
| 3 | 100 | 27 | **127** | 255 ≫ 8 = 0 | **0** |

`s = 128` is the exact half-way point (`128/256 = 0.5`) and must round **up** to
1; `s = 127` is one below the tie and must round **down** to 0. Neurons 2 and 3
repeat the boundary with a different acc/bias split to show it is the *sum* that
matters, not either term.

### T10 — weight-load timing

**T10a:** `W = 1` (all), `X = 10` (all), `B = 0` → `acc = 4×10 = 40`,
`(40+128)≫8 = 0` → all outputs **0**.

**T10b:** mutate four weights only (`W[0]=50, W[5]=−40, W[10]=30, W[15]=−20`),
re-run without reloading anything else:

| j | Row weights | `acc[j]` | `(acc+128) >>> 8` | `y_lin[j]` | `y_relu[j]` |
|---|---|---:|---:|---:|---:|
| 0 | `50, 1, 1, 1` | 10×53 = **530** | 658 ≫ 8 = 2 | **2** | **2** |
| 1 | `1, −40, 1, 1` | 10×(−37) = **−370** | −242 ≫ 8 = −1 | **−1** | **0** |
| 2 | `1, 1, 30, 1` | 10×33 = **330** | 458 ≫ 8 = 1 | **1** | **1** |
| 3 | `1, 1, 1, −20` | 10×(−17) = **−170** | −42 ≫ 8 = −1 | **−1** | **0** |

Outputs change from all-zero to `{2,−1,1,−1}`, proving fresh weights are used —
no stale data and no load-path timing bug.

### T11 — reset during an operation

Not an output row — a **state** check. `start` is pulsed, the operation is
interrupted after 3 clocks, and `rst_n` is asserted mid-compute.

| Signal | Expected after reset |
|---|---|
| `busy_relu` | `0` |
| `busy_lin` | `0` |
| FSM `state` | `S_IDLE` |

A clean operation is then run to confirm the DUT recovers and still computes
correctly.

### T9, T12 — randomized vectors

`T9a`/`T9b` (back-to-back operations) and the `T12` sweep use `$random`, so
their vectors are not hand-tabulated. They are checked **bit-for-bit against the
golden model** on every output, which is a stronger check than a fixed table —
but the table above is what is compared by hand against the waveform.

---

## Expected console output

| Run | Command | Checks | Failures |
|---|---|---:|---:|
| Directed only | `./run_xrun.sh quick` | 104 | **0** |
| Full regression | `./run_xrun.sh` | 1704 | **0** |
| MAC unit | `./run_xrun.sh mac` | 509 | **0** |
| Bug injected | `./run_xrun.sh bug` | 1704 | **non-zero** |

The check counts are deterministic (`213 cases × 4 neurons × 2 instances =
1704`). The **bug-run failure count is not** — it depends on how many random
vectors happen to involve the corrupted weight, and `$random` may differ between
simulators. The pass criterion is **zero vs non-zero**, not a specific number.
