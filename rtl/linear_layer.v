//============================================================================
// linear_layer.v  --  Quantized linear-layer core
//----------------------------------------------------------------------------
// Hardware form of:   y = activation( requantize( W*x + b ) )
//
//   W : NOUT x NIN  signed DW-bit weight matrix
//   x : NIN         signed DW-bit input vector
//   b : NOUT        signed ACCW-bit bias vector
//
// For each output neuron j:
//     acc[j] = sum_{i=0..NIN-1} W[j][i]*x[i]        (wide accumulator)
//     s[j]   = acc[j] + b[j]
//     r[j]   = clamp( round( s[j] >>> SHIFT ), -2^(DW-1) .. 2^(DW-1)-1 )
//     y[j]   = EN_RELU ? max(0, r[j]) : r[j]
//
// Datapath: a SINGLE time-multiplexed MAC (mac.v) is run NIN*NOUT times.
//   - inner loop over i (inputs)  -> accumulate one dot product
//   - outer loop over j (neurons) -> requantize + activate, store output
//
// Requantize rounding: round-half-up via add of (1<<(SHIFT-1)) before the
// arithmetic shift-right. SHIFT=0 => no rounding term (pass-through shift).
//
// Load interface (unified): one write port selects which memory to write.
//   ld_sel = 0 -> weight  memory  (addr 0..NOUT*NIN-1, data low DW bits)
//   ld_sel = 1 -> input   memory  (addr 0..NIN-1,      data low DW bits)
//   ld_sel = 2 -> bias    memory  (addr 0..NOUT-1,     data ACCW bits)
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module linear_layer #(
    parameter integer NIN     = 4,    // number of inputs
    parameter integer NOUT    = 4,    // number of neurons / outputs
    parameter integer DW      = 8,    // operand width (signed, INT8 default)
    parameter integer ACCW    = 32,   // accumulator / bias width (signed)
    parameter integer SHIFT   = 8,    // requantize arithmetic right-shift
    parameter integer EN_RELU = 1     // 1 = ReLU activation, 0 = identity
) (
    input  wire                    clk,
    input  wire                    rst_n,     // async active-low reset

    // Unified load port
    input  wire                    ld_en,
    input  wire [1:0]              ld_sel,    // 0=W, 1=X, 2=B
    input  wire [WADDR-1:0]        ld_addr,   // wide enough for W (biggest)
    input  wire signed [ACCW-1:0]  ld_data,

    // Control / status
    input  wire                    start,     // pulse to begin a compute pass
    output reg                     busy,
    output reg                     done,      // 1-cycle pulse when finished

    // Output vector, flattened: y_flat[(j+1)*DW-1 : j*DW] = neuron j
    output wire [NOUT*DW-1:0]      y_flat
);

    //------------------------------------------------------------------
    // Local parameters / helpers
    //------------------------------------------------------------------
    localparam integer NW    = NOUT*NIN;             // weight count
    localparam integer WADDR = clog2(NW);            // weight address width
    localparam integer IADDR = clog2(NIN);           // input  index width
    localparam integer JADDR = clog2(NOUT);          // neuron index width

    // Signed clamp bounds for DW-bit output
    localparam signed [ACCW-1:0] MAXV =  (1 <<< (DW-1)) - 1;   //  2^(DW-1)-1
    localparam signed [ACCW-1:0] MINV = -(1 <<< (DW-1));       // -2^(DW-1)

    function integer clog2;
        input integer value;
        integer v;
        begin
            v = value - 1;
            for (clog2 = 0; v > 0; clog2 = clog2 + 1) v = v >> 1;
            if (clog2 == 0) clog2 = 1;   // at least 1 bit
        end
    endfunction

    //------------------------------------------------------------------
    // Storage
    //------------------------------------------------------------------
    reg signed [DW-1:0]   w_mem [0:NW-1];    // weights
    reg signed [DW-1:0]   x_mem [0:NIN-1];   // inputs
    reg signed [ACCW-1:0] b_mem [0:NOUT-1];  // biases
    reg signed [DW-1:0]   y_mem [0:NOUT-1];  // outputs

    // Load writes
    always @(posedge clk) begin
        if (ld_en) begin
            case (ld_sel)
                2'd0: w_mem[ld_addr]        <= ld_data[DW-1:0];
                2'd1: x_mem[ld_addr[IADDR-1:0]] <= ld_data[DW-1:0];
                2'd2: b_mem[ld_addr[JADDR-1:0]] <= ld_data;
                default: ;
            endcase
        end
    end

    //------------------------------------------------------------------
    // FSM + counters
    //------------------------------------------------------------------
    localparam [1:0] S_IDLE    = 2'd0,
                     S_COMPUTE = 2'd1,   // inner loop over inputs i
                     S_REQUANT = 2'd2;   // finish neuron j, store output

    reg [1:0]        state;
    reg [IADDR-1:0]  i_cnt;    // input index
    reg [JADDR-1:0]  j_cnt;    // neuron index

    wire i_last = (i_cnt == NIN[IADDR-1:0]-1'b1);
    wire j_last = (j_cnt == NOUT[JADDR-1:0]-1'b1);

    // MAC drive signals
    reg                 mac_clr;
    reg                 mac_en;
    wire signed [DW-1:0] mac_a = w_mem[j_cnt*NIN + i_cnt];  // weight W[j][i]
    wire signed [DW-1:0] mac_b = x_mem[i_cnt];              // input  x[i]
    wire signed [ACCW-1:0] mac_acc;

    mac #(.DW(DW), .ACCW(ACCW)) u_mac (
        .clk   (clk),
        .rst_n (rst_n),
        .clr   (mac_clr),
        .en    (mac_en),
        .a     (mac_a),
        .b     (mac_b),
        .acc   (mac_acc)
    );

    //------------------------------------------------------------------
    // Requantize + activation (combinational), fed by mac_acc + bias
    //------------------------------------------------------------------
    localparam integer RQW = ACCW + 2;                 // room for bias-add + round
    wire signed [RQW-1:0] biased = $signed(mac_acc) + $signed(b_mem[j_cnt]);
    wire signed [RQW-1:0] rnd    = (SHIFT == 0) ? {RQW{1'b0}}
                                                : (1 <<< (SHIFT-1));
    wire signed [RQW-1:0] shifted = (biased + rnd) >>> SHIFT;

    reg signed [DW-1:0] q;       // clamped
    always @(*) begin
        if (shifted > MAXV)      q = MAXV[DW-1:0];
        else if (shifted < MINV) q = MINV[DW-1:0];
        else                     q = shifted[DW-1:0];
    end
    wire signed [DW-1:0] act = (EN_RELU != 0 && q < 0) ? {DW{1'b0}} : q;

    //------------------------------------------------------------------
    // FSM sequential
    //------------------------------------------------------------------
    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            i_cnt <= {IADDR{1'b0}};
            j_cnt <= {JADDR{1'b0}};
            busy  <= 1'b0;
            done  <= 1'b0;
            for (k = 0; k < NOUT; k = k + 1) y_mem[k] <= {DW{1'b0}};
        end else begin
            done <= 1'b0;   // default: done is a 1-cycle pulse
            case (state)
                //--------------------------------------------------
                S_IDLE: begin
                    busy  <= 1'b0;
                    if (start) begin
                        busy  <= 1'b1;
                        i_cnt <= {IADDR{1'b0}};
                        j_cnt <= {JADDR{1'b0}};
                        state <= S_COMPUTE;
                    end
                end
                //--------------------------------------------------
                // Inner loop: accumulate dot product for neuron j.
                // The edge that leaves S_COMPUTE performs the final MAC add,
                // so mac_acc is valid on entry to S_REQUANT.
                S_COMPUTE: begin
                    if (i_last) begin
                        state <= S_REQUANT;
                    end else begin
                        i_cnt <= i_cnt + 1'b1;
                    end
                end
                //--------------------------------------------------
                S_REQUANT: begin
                    y_mem[j_cnt] <= act;         // store activated output
                    if (j_last) begin
                        done  <= 1'b1;
                        busy  <= 1'b0;
                        state <= S_IDLE;
                    end else begin
                        j_cnt <= j_cnt + 1'b1;
                        i_cnt <= {IADDR{1'b0}};
                        state <= S_COMPUTE;
                    end
                end
                //--------------------------------------------------
                default: state <= S_IDLE;
            endcase
        end
    end

    //------------------------------------------------------------------
    // MAC control (combinational): clear on first input of each neuron.
    //------------------------------------------------------------------
    always @(*) begin
        mac_en  = 1'b0;
        mac_clr = 1'b0;
        if (state == S_COMPUTE) begin
            mac_en  = 1'b1;
            mac_clr = (i_cnt == {IADDR{1'b0}});  // load first product
        end
    end

    //------------------------------------------------------------------
    // Flatten output vector
    //------------------------------------------------------------------
    genvar g;
    generate
        for (g = 0; g < NOUT; g = g + 1) begin : GEN_YFLAT
            assign y_flat[(g+1)*DW-1 : g*DW] = y_mem[g];
        end
    endgenerate

endmodule

`default_nettype wire
