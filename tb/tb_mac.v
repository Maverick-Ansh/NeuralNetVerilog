//============================================================================
// tb_mac.v  --  Self-checking unit testbench for the signed MAC primitive
//----------------------------------------------------------------------------
// Verifies mac.v in isolation before it is trusted inside the layer core.
//   * Golden reference: a plain 64-bit signed accumulator in the TB.
//   * Checks every control combination: clr+en (load), en (accumulate),
//     clr only, hold, and async reset.
//   * Signed extremes: max positive * max positive, min * min, mixed signs.
//   * Randomized accumulate streams compared bit-for-bit each cycle.
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_mac;

    localparam integer DW   = 8;
    localparam integer ACCW = 32;

    reg                    clk = 1'b0;
    always #5 clk = ~clk;

    reg                    rst_n, clr, en;
    reg  signed [DW-1:0]   a, b;
    wire signed [ACCW-1:0] acc;

    reg  signed [63:0]     gold;    // golden accumulator
    integer                fails = 0, checks = 0;

    mac #(.DW(DW), .ACCW(ACCW)) dut (
        .clk(clk), .rst_n(rst_n), .clr(clr), .en(en), .a(a), .b(b), .acc(acc)
    );

    // Apply one cycle of stimulus, update golden the same way the RTL does,
    // then check the DUT accumulator after the clock edge.
    task step;
        input                _clr;
        input                _en;
        input signed [DW-1:0] _a;
        input signed [DW-1:0] _b;
        begin
            @(negedge clk);
            clr = _clr; en = _en; a = _a; b = _b;
            // mirror RTL priority: (clr&en)->load, en->acc, clr->0, else hold
            if      (_clr && _en) gold = $signed(_a) * $signed(_b);
            else if (_en)         gold = gold + $signed(_a) * $signed(_b);
            else if (_clr)        gold = 64'sd0;
            @(posedge clk);
            #1;
            checks = checks + 1;
            if (acc !== gold[ACCW-1:0]) begin
                fails = fails + 1;
                $display("  FAIL: clr=%b en=%b a=%0d b=%0d  acc=%0d expected=%0d",
                         _clr, _en, _a, _b, acc, gold[ACCW-1:0]);
            end
        end
    endtask

    task do_reset; begin
        rst_n=0; clr=0; en=0; a=0; b=0; gold=0;
        repeat(2) @(posedge clk); #1;
        rst_n=1; @(negedge clk);
    end endtask

    integer i;
    reg signed [DW-1:0] ra, rb;
    initial begin
        $dumpfile("sim/mac.vcd");
        $dumpvars(0, tb_mac);
        $display("==== MAC unit testbench ====");
        do_reset;

        // Directed: load then accumulate a stream
        step(1,1, 10,  3);     // load 30
        step(0,1,  5, -4);     // +(-20) = 10
        step(0,1, -8,  8);     // +(-64) = -54
        step(0,0,  0,  0);     // hold
        if (acc !== -54) begin fails=fails+1; $display("  FAIL: hold changed acc"); end

        // clr-only zeroes it
        step(1,0, 99, 99);     // clr -> 0
        if (acc !== 0) begin fails=fails+1; $display("  FAIL: clr-only nonzero"); end

        // Signed extremes
        step(1,1, -128, -128); // 16384
        step(0,1,  127,  127); // +16129
        step(0,1, -128,  127); // -16256
        step(0,1,  127, -128); // -16256

        // Async reset clears immediately
        @(negedge clk); rst_n=0; @(posedge clk); #1;
        if (acc !== 0) begin fails=fails+1; $display("  FAIL: async reset"); end
        rst_n=1; gold=0;

        // Randomized accumulate streams
        for (i=0; i<500; i=i+1) begin
            ra = $random; rb = $random;
            if (i % 17 == 0) step(1,1, ra, rb);   // periodic reload
            else             step(0,1, ra, rb);
        end

        $display("  %0d checks, %0d failures", checks, fails);
        if (fails==0) $display("  *** MAC TESTS PASSED ***");
        else          $display("  *** MAC: %0d FAILURE(S) ***", fails);
        $display("============================");
        $finish;
    end

endmodule

`default_nettype wire
