# tb/ — verification

| File | Tests | Notes |
|------|-------|-------|
| `tb_linear_layer.v` | Full layer core | Pure-Verilog golden model (nested loop, 64-bit acc). Two DUTs (`EN_RELU=1`/`0`) share stimulus so clamp-low is observable. All failure buckets + 200-vector random sweep. `+define+INJECT_BUG` proves the checker has teeth. |
| `tb_mac.v` | MAC primitive in isolation | Golden 64-bit accumulator; checks `clr`/`en`/hold/async-reset, signed extremes, 500 random accumulate cycles. |

Both are self-checking: they compare the DUT bit-for-bit against an
independent golden reference and print a pass/fail summary. Run via the
top-level `Makefile` (Icarus) or `run_xrun.sh` (Xcelium).

Failure-case → what-it-proves mapping: `../docs/failure_cases.md`.
