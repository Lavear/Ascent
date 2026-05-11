// =============================================================================
// ASCENT — cim_array.sv
// Phase 3: Full CIM Array — ROWS instances of cim_row.
//
// Default configuration is Layer 1: 128 output neurons, 784 inputs.
// Parameterised so the same module works for Layer 2 (64 rows, 128 inputs)
// and Layer 3 (10 rows, 64 inputs).
//
// Operating sequence (driven by Phase 4 sparse controller):
//
//   PHASE A — Weight Load (ROWS cycles):
//     For j = 0 to ROWS-1:
//       w_load_addr = j,  w_load_data = weight[j],  w_load_en = 1
//       (one cycle per row)
//
//   PHASE B — Compute (NUM_INPUTS cycles):
//     For i = 0 to NUM_INPUTS-1:
//       x_in = input[i],  compute_en = 1,  row_en_mask = sparse_mask
//       (one cycle per input value)
//     After NUM_INPUTS pulses, y_valid goes high and y_out_int8 is valid.
//
//   PHASE C — Clear (1 cycle):
//     acc_clear = 1  →  all accumulators reset to zero
//     (call this before the next inference or before loading next layer)
// =============================================================================

module cim_array #(
    parameter int DWIDTH        = 8,
    parameter int ROWS          = 128,
    parameter int ACC_WIDTH     = 24,
    parameter int REQUANT_SHIFT = 11,
    parameter int NUM_INPUTS    = 784
)(
    input  logic                              clk,
    input  logic                              rst_n,

    // Weight load interface
    input  logic                              w_load_en,
    input  logic [$clog2(ROWS)-1:0]           w_load_addr,
    input  logic [DWIDTH-1:0]                 w_load_data,

    // Compute interface
    input  logic                              compute_en,
    input  logic                              acc_clear,
    input  logic signed [DWIDTH-1:0]          x_in,
    input  logic [ROWS-1:0]                   row_en_mask,

    // Output
    output logic [ROWS-1:0][DWIDTH-1:0]       y_out_int8,
    output logic                              y_valid
);

    // =========================================================================
    // 1. One-hot row weight-load enable
    //
    // Only the row matching w_load_addr gets w_load_en asserted.
    // Implemented as ROWS parallel equality checks — purely combinational,
    // the synthesiser reduces these to a decoder.
    // =========================================================================
    logic [ROWS-1:0] row_w_load_en;

    genvar gi;
    generate
        for (gi = 0; gi < ROWS; gi++) begin : gen_load_decode
            assign row_w_load_en[gi] = w_load_en &
                                       (w_load_addr == ($clog2(ROWS))'(gi));
        end
    endgenerate

    // =========================================================================
    // 2. Generate ROWS instances of cim_row
    //
    // All rows share:   x_in, compute_en, acc_clear, clk, rst_n
    // Per-row unique:   row_w_load_en[gi], row_en_mask[gi]
    //
    // acc_out_arr is wired out for waveform debugging in testbench.
    // =========================================================================
    logic signed [ACC_WIDTH-1:0] acc_out_arr [0:ROWS-1];

    generate
        for (gi = 0; gi < ROWS; gi++) begin : gen_rows
            cim_row #(
                .DWIDTH        (DWIDTH),
                .ACC_WIDTH     (ACC_WIDTH),
                .REQUANT_SHIFT (REQUANT_SHIFT)
            ) u_row (
                .clk         (clk),
                .rst_n       (rst_n),
                .w_load_en   (row_w_load_en[gi]),
                .w_load_data (w_load_data),
                .compute_en  (compute_en),
                .row_en      (row_en_mask[gi]),
                .acc_clear   (acc_clear),
                .x_in        (x_in),
                .acc_out     (acc_out_arr[gi]),
                .y_out_int8  (y_out_int8[gi])
            );
        end
    endgenerate

    // =========================================================================
    // 3. y_valid: completion signal
    //
    // Counts compute_en pulses. Pulses y_valid=1 when count == NUM_INPUTS.
    // Resets on acc_clear (start of new inference).
    //
    // Counter width: needs to count 0 → NUM_INPUTS inclusive.
    // $clog2(NUM_INPUTS+1) gives the minimum number of bits needed.
    //   For NUM_INPUTS=784:  clog2(785) = 10 bits  (counts 0..1023)
    //   For NUM_INPUTS=128:  clog2(129) =  8 bits
    //   For NUM_INPUTS=64:   clog2(65)  =  7 bits
    // =========================================================================
    localparam int CNT_WIDTH = $clog2(NUM_INPUTS + 1);

    logic [CNT_WIDTH-1:0] input_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            input_cnt <= '0;
        else if (acc_clear)
            input_cnt <= '0;
        else if (compute_en && (input_cnt < CNT_WIDTH'(NUM_INPUTS)))
            input_cnt <= input_cnt + 1'b1;
    end

    // y_valid pulses high for exactly one cycle when all inputs have been consumed
    assign y_valid = (input_cnt == CNT_WIDTH'(NUM_INPUTS));

endmodule
