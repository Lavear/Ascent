// =============================================================================
// ASCENT — cim_row.sv (FPGA OPTIMIZED FOR PYNQ-Z2)
// Changes: DSP48E1 packing attributes for Accumulator
// =============================================================================

module cim_row #(
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

    logic signed [DWIDTH-1:0] weight_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            weight_reg <= '0;
        else if (w_load_en)
            weight_reg <= $signed(w_load_data);
    end

    logic signed [2*DWIDTH-1:0] product;

    loa_mult #(
        .N (DWIDTH),
        .K (4)
    ) u_mult (
        .a (x_in),
        .b (weight_reg),
        .p (product)
    );

    // =========================================================================
    // DSP48E1 MAPPING (Saves ~10k LUTs across the array)
    // =========================================================================
    (* use_dsp = "yes" *) logic signed [ACC_WIDTH-1:0]  acc;
    (* use_dsp = "yes" *) logic signed [ACC_WIDTH-1:0]  acc_next;
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
