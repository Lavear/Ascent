// =============================================================================
// ASCENT — cim_row_exact.sv
// ABLATION RUN A: Exact multiplier variant of cim_row.sv
//
// ONLY CHANGE from cim_row.sv:
//   loa_mult instance replaced with direct signed multiply (assign p = a * b)
//   This gives the baseline power for exact computing before LOA approximation.
//
// Everything else — accumulator, ReLU, requant, USE_RELU — is identical.
// =============================================================================

module cim_row_exact #(
    parameter int DWIDTH        = 8,
    parameter int ACC_WIDTH     = 24,
    parameter int REQUANT_SHIFT = 11,
    parameter bit USE_RELU      = 1
)(
    input  logic                           clk,
    input  logic                           rst_n,

    input  logic                           w_load_en,
    input  logic        [DWIDTH-1:0]       w_load_data,

    input  logic                           compute_en,
    input  logic                           row_en,
    input  logic                           acc_clear,
    input  logic signed [DWIDTH-1:0]       x_in,

    output logic signed [ACC_WIDTH-1:0]    acc_out,
    output logic        [DWIDTH-1:0]       y_out_int8
);

    // =========================================================================
    // 1. Weight register — identical to cim_row.sv
    // =========================================================================
    logic signed [DWIDTH-1:0] weight_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            weight_reg <= '0;
        else if (w_load_en)
            weight_reg <= $signed(w_load_data);
    end

    // =========================================================================
    // 2. EXACT Multiplier — THE ONLY CHANGE FROM cim_row.sv
    //
    //    cim_row.sv uses:   loa_mult #(.N(8),.K(4)) u_mult (.a,.b,.p)
    //    This file uses:    assign product = $signed(x_in) * $signed(weight_reg)
    //
    //    Cadence Genus will synthesise this using its internal Booth-encoded
    //    Wallace tree — the most power-hungry but mathematically exact option.
    //    This is our baseline to measure LOA savings against.
    // =========================================================================
    logic signed [2*DWIDTH-1:0] product;

    assign product = $signed(x_in) * $signed(weight_reg);

    // =========================================================================
    // 3. Saturating accumulator — identical to cim_row.sv
    // =========================================================================
    logic signed [ACC_WIDTH-1:0]  acc;
    logic signed [ACC_WIDTH-1:0]  acc_next;
    logic signed [ACC_WIDTH:0]    acc_sum_wide;

    localparam logic signed [ACC_WIDTH-1:0] ACC_MAX =
        (ACC_WIDTH)'($signed({1'b0, {(ACC_WIDTH-1){1'b1}}}));
    localparam logic signed [ACC_WIDTH-1:0] ACC_MIN =
        (ACC_WIDTH)'($signed({1'b1, {(ACC_WIDTH-1){1'b0}}}));

    always_comb begin
        acc_sum_wide = '0;
        acc_next     = acc;

        if (acc_clear) begin
            acc_next = '0;
        end else if (compute_en && row_en) begin
            acc_sum_wide = {{(ACC_WIDTH - 2*DWIDTH + 1){product[2*DWIDTH-1]}},
                            product} + {{1{acc[ACC_WIDTH-1]}}, acc};

            if (acc_sum_wide[ACC_WIDTH] && !acc_sum_wide[ACC_WIDTH-1])
                acc_next = ACC_MIN;
            else if (!acc_sum_wide[ACC_WIDTH] && acc_sum_wide[ACC_WIDTH-1])
                acc_next = ACC_MAX;
            else
                acc_next = acc_sum_wide[ACC_WIDTH-1:0];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) acc <= '0;
        else        acc <= acc_next;
    end

    assign acc_out = acc;

    // =========================================================================
    // 4. ReLU + Requantisation — identical to cim_row.sv
    // =========================================================================
    logic signed [ACC_WIDTH-1:0] relu_val;
    logic signed [ACC_WIDTH-1:0] shifted_val;

    localparam logic signed [ACC_WIDTH-1:0] MAX_INT8 = ACC_WIDTH'(127);
    localparam logic signed [ACC_WIDTH-1:0] MIN_INT8 = ACC_WIDTH'(-128);

    always_comb begin
        if (USE_RELU)
            relu_val = acc[ACC_WIDTH-1] ? '0 : acc;
        else
            relu_val = acc;

        shifted_val = relu_val >>> REQUANT_SHIFT;

        if (shifted_val > MAX_INT8)
            y_out_int8 = 8'd127;
        else if (!USE_RELU && shifted_val < MIN_INT8)
            y_out_int8 = 8'h80;
        else
            y_out_int8 = shifted_val[DWIDTH-1:0];
    end

endmodule
