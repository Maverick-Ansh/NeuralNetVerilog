# rtl/ — synthesizable design

| File | Module | Role |
|------|--------|------|
| `mac.v` | `mac` | Signed multiply-accumulate primitive. Registered accumulator, `clr`/`en` control, `ACCW`-bit signed. The one compute unit the layer reuses. |
| `linear_layer.v` | `linear_layer` | Layer core. Weight/input/bias register storage, unified load port, FSM (`IDLE→COMPUTE→REQUANT`) with `i`/`j` counters and address generation, one MAC instance, requantize (shift + round-half-up + clamp), ReLU. |

Both are plain Verilog-2001, parameterized (`NIN`, `NOUT`, `DW`, `ACCW`,
`SHIFT`, `EN_RELU`), signed throughout, with saturating overflow.

See the top-level `README.md` for the datapath diagram and parameter table.
