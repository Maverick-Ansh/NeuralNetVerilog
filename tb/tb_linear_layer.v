//============================================================================
// tb_linear_layer.v  --  Self-checking testbench for the quantized linear layer
//----------------------------------------------------------------------------
// Verification strategy
//   * Pure-Verilog GOLDEN MODEL: a nested-loop reference with a wide (64-bit)
//     accumulator and plain math, computed independently of the DUT.
//   * TWO DUT instances share identical stimulus:
//       - u_relu : EN_RELU=1  (production activation)
//       - u_lin  : EN_RELU=0  (identity -> lets us OBSERVE clamp-low = -128,
//                              which ReLU would otherwise mask as 0)
//   * Every output is compared BIT-FOR-BIT against the golden model.
//   * Failure buckets covered: reset mid-op, requant rounding boundary,
//     saturation high & low, ReLU on negatives, overflow-forcing values,
//     all-zero input, max-magnitude weights, back-to-back ops, weight-load
//     timing, and a randomized regression sweep ($random).
//   * BUG INJECTION: compile with +define+INJECT_BUG to corrupt one DUT
//     weight (not the golden copy) and prove the checker catches it.
//   * VCD dumped for SimVision.
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_linear_layer;

    //------------------------------------------------------------------
    // DUT parameters (match linear_layer defaults)
    //------------------------------------------------------------------
    localparam integer NIN   = 4;
    localparam integer NOUT  = 4;
    localparam integer DW    = 8;
    localparam integer ACCW  = 32;
    localparam integer SHIFT = 8;

    localparam integer NW = NOUT*NIN;

    function integer clog2;
        input integer value;
        integer v;
        begin
            v = value - 1;
            for (clog2 = 0; v > 0; clog2 = clog2 + 1) v = v >> 1;
            if (clog2 == 0) clog2 = 1;
        end
    endfunction
    localparam integer WADDR = clog2(NW);

    // Signed clamp bounds (golden model)
    localparam signed [63:0] MAXV =  (64'sd1 <<< (DW-1)) - 1;   //  127
    localparam signed [63:0] MINV = -(64'sd1 <<< (DW-1));       // -128

    //------------------------------------------------------------------
    // Clock / reset
    //------------------------------------------------------------------
    reg clk = 1'b0;
    always #5 clk = ~clk;      // 100 MHz
    reg rst_n;

    //------------------------------------------------------------------
    // Shared DUT drive signals
    //------------------------------------------------------------------
    reg                    ld_en;
    reg  [1:0]             ld_sel;
    reg  [WADDR-1:0]       ld_addr;
    reg  signed [ACCW-1:0] ld_data;
    reg                    start;

    wire                   busy_relu, done_relu;
    wire                   busy_lin,  done_lin;
    wire [NOUT*DW-1:0]     y_relu, y_lin;

    //------------------------------------------------------------------
    // Reference storage the GOLDEN MODEL reads (never touched by the DUT)
    //------------------------------------------------------------------
    reg signed [DW-1:0]   W [0:NW-1];
    reg signed [DW-1:0]   X [0:NIN-1];
    reg signed [ACCW-1:0] B [0:NOUT-1];

    reg signed [DW-1:0]   exp_relu [0:NOUT-1];
    reg signed [DW-1:0]   exp_lin  [0:NOUT-1];

    integer fails = 0;
    integer checks = 0;

    //------------------------------------------------------------------
    // DUT instances
    //------------------------------------------------------------------
    linear_layer #(.NIN(NIN), .NOUT(NOUT), .DW(DW), .ACCW(ACCW),
                   .SHIFT(SHIFT), .EN_RELU(1)) u_relu (
        .clk(clk), .rst_n(rst_n),
        .ld_en(ld_en), .ld_sel(ld_sel), .ld_addr(ld_addr), .ld_data(ld_data),
        .start(start), .busy(busy_relu), .done(done_relu), .y_flat(y_relu)
    );

    linear_layer #(.NIN(NIN), .NOUT(NOUT), .DW(DW), .ACCW(ACCW),
                   .SHIFT(SHIFT), .EN_RELU(0)) u_lin (
        .clk(clk), .rst_n(rst_n),
        .ld_en(ld_en), .ld_sel(ld_sel), .ld_addr(ld_addr), .ld_data(ld_data),
        .start(start), .busy(busy_lin), .done(done_lin), .y_flat(y_lin)
    );

    //==================================================================
    // GOLDEN MODEL  --  independent nested-loop reference
    //==================================================================
    task compute_golden;
        integer j, i;
        reg signed [63:0] acc, s, sh, r;
        begin
            for (j = 0; j < NOUT; j = j + 1) begin
                acc = 64'sd0;
                for (i = 0; i < NIN; i = i + 1)
                    acc = acc + $signed(W[j*NIN+i]) * $signed(X[i]);
                s = acc + $signed(B[j]);
                // requantize: round-half-up then arithmetic shift-right
                if (SHIFT == 0) sh = s;
                else            sh = (s + (64'sd1 <<< (SHIFT-1))) >>> SHIFT;
                // clamp to signed DW range
                if      (sh > MAXV) r = MAXV;
                else if (sh < MINV) r = MINV;
                else                r = sh;
                exp_lin[j]  = r[DW-1:0];
                exp_relu[j] = (r < 0) ? {DW{1'b0}} : r[DW-1:0];
            end
        end
    endtask

    //==================================================================
    // Low-level driver tasks
    //==================================================================
    task do_reset;
        begin
            rst_n = 1'b0; ld_en = 1'b0; start = 1'b0;
            ld_sel = 2'd0; ld_addr = {WADDR{1'b0}}; ld_data = {ACCW{1'b0}};
            repeat (2) @(posedge clk);
            rst_n = 1'b1;
            @(posedge clk);
        end
    endtask

    // Drive one write into the DUT load port.
    // INJECT_BUG corrupts DUT weight[0] ONLY (golden copy stays correct).
    task do_load;
        input [1:0]            sel;
        input integer          addr;
        input signed [ACCW-1:0] data;
        reg signed [ACCW-1:0]  d;
        begin
            d = data;
`ifdef INJECT_BUG
            if (sel == 2'd0 && addr == 0) d = data + 1;   // sabotage
`endif
            @(negedge clk);
            ld_en   = 1'b1;
            ld_sel  = sel;
            ld_addr = addr[WADDR-1:0];
            ld_data = d;
            @(posedge clk);
            @(negedge clk);
            ld_en   = 1'b0;
        end
    endtask

    // Push the current W/X/B reference arrays into both DUTs.
    task load_all;
        integer i;
        begin
            for (i = 0; i < NW;   i = i + 1) do_load(2'd0, i, {{(ACCW-DW){W[i][DW-1]}}, W[i]});
            for (i = 0; i < NIN;  i = i + 1) do_load(2'd1, i, {{(ACCW-DW){X[i][DW-1]}}, X[i]});
            for (i = 0; i < NOUT; i = i + 1) do_load(2'd2, i, B[i]);
        end
    endtask

    task pulse_start;
        begin
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    task wait_done;
        begin
            @(posedge done_relu);   // both DUTs finish on the same cycle
        end
    endtask

    //==================================================================
    // Check the DUT outputs against the golden model (bit-for-bit)
    //==================================================================
    task check_outputs;
        input [8*40-1:0] name;
        integer j;
        reg signed [DW-1:0] got_r, got_l;
        begin
            compute_golden;
            for (j = 0; j < NOUT; j = j + 1) begin
                got_r = y_relu[j*DW +: DW];
                got_l = y_lin [j*DW +: DW];
                checks = checks + 2;
                if (got_r !== exp_relu[j]) begin
                    fails = fails + 1;
                    $display("  FAIL [%0s] relu neuron %0d: got %0d expected %0d",
                             name, j, got_r, exp_relu[j]);
                end
                if (got_l !== exp_lin[j]) begin
                    fails = fails + 1;
                    $display("  FAIL [%0s] lin  neuron %0d: got %0d expected %0d",
                             name, j, got_l, exp_lin[j]);
                end
            end
            $display("  [%0s] relu={%0d %0d %0d %0d} lin={%0d %0d %0d %0d}",
                     name,
                     $signed(y_relu[0*DW +: DW]), $signed(y_relu[1*DW +: DW]),
                     $signed(y_relu[2*DW +: DW]), $signed(y_relu[3*DW +: DW]),
                     $signed(y_lin[0*DW +: DW]),  $signed(y_lin[1*DW +: DW]),
                     $signed(y_lin[2*DW +: DW]),  $signed(y_lin[3*DW +: DW]));
        end
    endtask

    // Full pass: load + start + wait + check
    task run_case;
        input [8*40-1:0] name;
        begin
            load_all;
            pulse_start;
            wait_done;
            @(negedge clk);        // let y_flat settle after done edge
            check_outputs(name);
        end
    endtask

    //==================================================================
    // Stimulus helpers
    //==================================================================
    task set_all_w;  input signed [DW-1:0] v; integer i; begin
        for (i=0;i<NW;i=i+1)  W[i]=v; end endtask
    task set_all_x;  input signed [DW-1:0] v; integer i; begin
        for (i=0;i<NIN;i=i+1) X[i]=v; end endtask
    task set_all_b;  input signed [ACCW-1:0] v; integer i; begin
        for (i=0;i<NOUT;i=i+1) B[i]=v; end endtask

    // Full-range random: exercises saturation/clamp heavily.
    task rand_stim; integer i; begin
        for (i=0;i<NW;i=i+1)   W[i] = $random;
        for (i=0;i<NIN;i=i+1)  X[i] = $random;
        for (i=0;i<NOUT;i=i+1) B[i] = $random;   // full-width signed bias
    end endtask

    // Bounded random: operands/bias sized so results usually land IN range,
    // exercising the mid-range requant, rounding, and occasional-clamp paths.
    //
    // NOTE: `$random % N` is NOT in [0,N-1] -- Verilog's % takes the sign of the
    // dividend, so it spans [-(N-1),N-1] and the resulting range is skewed
    // negative. `{$random}` forces an unsigned value so the modulo is in
    // [0,N-1]; the subtraction is then done on a signed integer temp so the
    // final range is symmetric as intended.
    task rand_small; integer i; integer r; begin
        for (i=0;i<NW;i=i+1)   begin r = {$random} % 81;   W[i] = r - 40;   end // [-40,40]
        for (i=0;i<NIN;i=i+1)  begin r = {$random} % 81;   X[i] = r - 40;   end // [-40,40]
        for (i=0;i<NOUT;i=i+1) begin r = {$random} % 8193; B[i] = r - 4096; end // [-4096,4096]
    end endtask

    //==================================================================
    // Test sequence
    //==================================================================
    integer t;
    initial begin
        $dumpfile("sim/linear_layer.vcd");
        $dumpvars(0, tb_linear_layer);

        $display("========================================================");
        $display(" Quantized linear-layer self-checking testbench");
        $display("  NIN=%0d NOUT=%0d DW=%0d ACCW=%0d SHIFT=%0d",
                 NIN, NOUT, DW, ACCW, SHIFT);
`ifdef INJECT_BUG
        $display("  *** INJECT_BUG active: DUT weight[0] corrupted ***");
`endif
        $display("========================================================");

        do_reset;

        // ---- T1: basic small values --------------------------------
        W[0]=1; W[1]=2; W[2]=3; W[3]=-4;
        W[4]=5; W[5]=-6; W[6]=7; W[7]=8;
        W[8]=-1; W[9]=-2; W[10]=-3; W[11]=-4;
        W[12]=10; W[13]=20; W[14]=-30; W[15]=40;
        X[0]=100; X[1]=-50; X[2]=25; X[3]=-10;
        set_all_b(0);
        run_case("T1-basic");

        // ---- T2: all-zero input ------------------------------------
        set_all_x(0); set_all_b(0);
        run_case("T2-zero-input");

        // ---- T3: max-magnitude weights, overflow-forcing -----------
        set_all_w(-128); set_all_x(127); set_all_b(0);   // large negative sums
        run_case("T3-maxmag-neg");                         // lin -> -128, relu -> 0

        set_all_w(127); set_all_x(127); set_all_b(0);      // large positive sums
        run_case("T4-maxmag-pos");                         // clamp high -> 127

        // ---- T5: saturation high via bias --------------------------
        set_all_w(0); set_all_x(0);
        set_all_b(32'sd1000000);                           // huge positive bias
        run_case("T5-sat-high");                           // -> 127

        // ---- T6: saturation low via bias (clamp-low + ReLU) --------
        set_all_b(-32'sd1000000);
        run_case("T6-sat-low");                            // lin -> -128, relu -> 0

        // ---- T7: mild negatives -> ReLU on negatives ---------------
        set_all_w(0); set_all_x(0);
        set_all_b(-32'sd300);                              // /256 ~ -1 -> lin -1, relu 0
        run_case("T7-relu-neg");

        // ---- T8: requantize rounding boundary ----------------------
        // Craft s = W[j0]*X0 + B so (s+128)>>>8 sits on rounding edges.
        set_all_w(0); set_all_x(0);
        X[0] = 1;
        W[0]  = 127;  B[0] = 32'sd1;    // s=128  -> (128+128)>>>8 = 1  (rounds up)
        W[4]  = 127;  B[1] = 32'sd0;    // s=127  -> (127+128)>>>8 = 0  (rounds down)
        W[8]  = 100;  B[2] = 32'sd28;   // s=128  -> 1
        W[12] = 100;  B[3] = 32'sd27;   // s=127  -> 0
        run_case("T8-round-edge");

        // ---- T9: back-to-back operations (no reset between) --------
        rand_stim;  run_case("T9a-b2b");
        rand_stim;  run_case("T9b-b2b");   // second op immediately follows

        // ---- T10: weight-load timing -------------------------------
        // Run, then change ONLY some weights and re-run; result must change,
        // proving fresh weights are used (no stale data / load-timing bug).
        set_all_w(1); set_all_x(10); set_all_b(0);
        run_case("T10a-preload");
        W[0]=50; W[5]=-40; W[10]=30; W[15]=-20;   // mutate a few weights
        run_case("T10b-reload");

        // ---- T11: reset mid-operation ------------------------------
        rand_stim;
        load_all;
        pulse_start;
        repeat (3) @(posedge clk);        // interrupt partway through
        rst_n = 1'b0;
        repeat (2) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        if (busy_relu !== 1'b0 || busy_lin !== 1'b0) begin
            fails = fails + 1;
            $display("  FAIL [T11-reset] DUT still busy after reset");
        end else begin
            $display("  [T11-reset] DUT returned to idle after mid-op reset");
        end
        // recovery: a clean op must still be correct
        rand_stim; run_case("T11-post-reset");

        // ---- T12: randomized regression sweep ----------------------
        // Mix bounded (mid-range) and full-range (saturation) random vectors.
        // Skipped under +define+QUICK so the waveform run contains ONLY the
        // directed cases T1..T11 -- those are the ones in the functional table,
        // and the shorter run is readable in SimVision (~7 us vs ~150 us).
`ifdef QUICK
        $display("  [QUICK] random regression sweep skipped (directed tests only)");
`else
        for (t = 0; t < 200; t = t + 1) begin
            if (t[0]) rand_small; else rand_stim;
            load_all;
            pulse_start;
            wait_done;
            @(negedge clk);
            check_outputs(t[0] ? "T12-rand-small" : "T12-rand-full");
        end
`endif

        //-------------------------------------------------------------
        $display("========================================================");
        $display(" RESULT: %0d checks, %0d failures", checks, fails);
        if (fails == 0)
            $display(" *** ALL TESTS PASSED ***");
        else
            $display(" *** %0d FAILURE(S) DETECTED ***", fails);
        $display("========================================================");
        $finish;
    end

    // Safety timeout
    initial begin
        #2000000;
        $display("TIMEOUT: simulation did not finish");
        $finish;
    end

endmodule

`default_nettype wire
