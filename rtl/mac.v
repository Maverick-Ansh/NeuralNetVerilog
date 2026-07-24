//============================================================================
// mac.v  --  Signed multiply-accumulate primitive (time-multiplexed)
//----------------------------------------------------------------------------
// One instance of this MAC is reused NIN*NOUT times by the linear layer core.
// Registered accumulator. Signed arithmetic throughout.
//
//   clr & en : acc <= a*b            (start a fresh dot product, load first term)
//   en       : acc <= acc + a*b      (accumulate a term)
//   clr      : acc <= 0              (clear only, no accumulate)
//   idle     : acc <= acc            (hold)
//
// Product width  = 2*DW bits (signed*signed).
// Accumulator    = ACCW bits, sign-extended from the product before adding.
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module mac #(
    parameter integer DW   = 8,     // operand width (signed)
    parameter integer ACCW = 32     // accumulator width (signed)
) (
    input  wire                 clk,
    input  wire                 rst_n,   // async active-low reset
    input  wire                 clr,     // clear accumulator
    input  wire                 en,      // enable accumulate
    input  wire signed [DW-1:0] a,       // operand a (e.g. weight)
    input  wire signed [DW-1:0] b,       // operand b (e.g. input)
    output reg  signed [ACCW-1:0] acc    // running accumulator
);

    // Full-precision signed product, sign-extended to accumulator width.
    wire signed [2*DW-1:0] prod = a * b;
    wire signed [ACCW-1:0] prod_ext = {{(ACCW-2*DW){prod[2*DW-1]}}, prod};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            acc <= {ACCW{1'b0}};
        else if (clr && en)
            acc <= prod_ext;           // first term of a new dot product
        else if (en)
            acc <= acc + prod_ext;     // accumulate
        else if (clr)
            acc <= {ACCW{1'b0}};       // clear only
        // else hold
    end

endmodule

`default_nettype wire
