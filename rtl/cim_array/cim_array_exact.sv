// =============================================================================
// ASCENT — cim_array_exact.sv
// ABLATION RUN A: Exact multiplier variant of cim_array.sv
//
// ONLY CHANGE from cim_array.sv:
//   Instantiates cim_row_exact instead of cim_row
//   Module name changed to cim_array_exact so both can coexist
//
// Everything else — parameters, y_valid counter, weight decoder — is identical.
// =============================================================================

module cim_array_exact #(
    parameter int DWIDTH        = 8,
    parameter int ROWS          = 128,
    parameter int ACC_WIDTH     = 24,
    parameter int REQUANT_SHIFT = 11,
    parameter int NUM_INPUTS    = 784,
    parameter bit USE_RELU      = 1
)(
    input  logic                              clk,
    input  logic                              rst_n,

    input  logic                              w_load_en,
    input  logic [$clog2(ROWS)-1:0]           w_load_addr,
    input  logic [DWIDTH-1:0]                 w_load_data,

    input  logic                              compute_en,
    input  logic                              acc_clear,
    input  logic signed [DWIDTH-1:0]          x_in,
    input  logic [ROWS-1:0]                   row_en_mask,

    output logic [ROWS-1:0][DWIDTH-1:0]       y_out_int8,
    output logic                              y_valid
);

    // =========================================================================
    // 1. One-hot weight-load decoder — identical to cim_array.sv
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
    // 2. ROWS instances of cim_row_exact — THE ONLY CHANGE FROM cim_array.sv
    //    cim_array.sv instantiates:       cim_row
    //    cim_array_exact.sv instantiates: cim_row_exact
    // =========================================================================
    logic signed [ACC_WIDTH-1:0] acc_out_arr [0:ROWS-1];

    generate
        for (gi = 0; gi < ROWS; gi++) begin : gen_rows
            cim_row_exact #(
                .DWIDTH        (DWIDTH),
                .ACC_WIDTH     (ACC_WIDTH),
                .REQUANT_SHIFT (REQUANT_SHIFT),
                .USE_RELU      (USE_RELU)
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
    // 3. y_valid counter — identical to cim_array.sv
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

    assign y_valid = (input_cnt == CNT_WIDTH'(NUM_INPUTS));

endmodule
